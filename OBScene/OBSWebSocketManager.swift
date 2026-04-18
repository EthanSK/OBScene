import Foundation
import CommonCrypto
import AppKit

// MARK: - OBS WebSocket v5 Protocol Messages

struct OBSMessage: Codable {
    let op: Int
    let d: AnyCodable
}

struct OBSHello: Codable {
    let obsWebSocketVersion: String
    let rpcVersion: Int
    let authentication: OBSAuthChallenge?
}

struct OBSAuthChallenge: Codable {
    let challenge: String
    let salt: String
}

struct OBSIdentify: Codable {
    let rpcVersion: Int
    let authentication: String?
    let eventSubscriptions: Int?
}

struct OBSRequest: Codable {
    let requestType: String
    let requestId: String
    let requestData: AnyCodable?
}

struct OBSRequestResponse: Codable {
    let requestType: String
    let requestId: String
    let requestStatus: OBSRequestStatus
    let responseData: AnyCodable?
}

struct OBSRequestStatus: Codable {
    let result: Bool
    let code: Int
    let comment: String?
}

// MARK: - AnyCodable helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if value is NSNull {
            try container.encodeNil()
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

// MARK: - OBS WebSocket Manager

/// High-level connection state consumed by the UI. The manager keeps a live
/// auto-reconnect loop running whenever we're not connected, so the UI needs
/// to be able to tell "actively retrying" apart from "idle, no connection
/// ever attempted" apart from "connected".
enum OBSConnectionState: Equatable {
    /// Nothing has been configured yet / connect has never been called.
    case idle
    /// Identify handshake complete, we're talking to OBS.
    case connected
    /// Not connected, waiting for a scheduled reconnect attempt.
    /// `nextAttemptAt` is the wall-clock date the next connect will fire;
    /// `delay` is the full interval we're waiting so the UI can compute
    /// a "Retrying in Ns…" countdown.
    case retrying(nextAttemptAt: Date, delay: TimeInterval)
    /// Not connected and not currently scheduled to retry. This is a
    /// transient state — once `disconnected` is entered we immediately
    /// schedule a retry and transition to `.retrying`. The UI should render
    /// this as a generic "disconnected" badge.
    case disconnected(message: String?)

    /// Helper: treats both `.retrying` and `.disconnected` as "not connected"
    /// for call sites that don't care about the sub-state.
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

class OBSWebSocketManager: ObservableObject {
    static let shared = OBSWebSocketManager()

    @Published var isConnected = false
    @Published var sceneCollections: [String] = []
    @Published var profiles: [String] = []
    @Published var scenes: [String] = []
    @Published var currentSceneCollection: String = ""
    @Published var currentProfile: String = ""
    @Published var currentScene: String = ""
    @Published var connectionError: String?

    /// Structured connection state for the UI (status pill). Kept in sync
    /// with the legacy `isConnected` / `connectionError` fields — any change
    /// to this property posts `.obsConnectionChanged` on the main queue.
    @Published var connectionState: OBSConnectionState = .idle

    // MARK: Auto-reconnect

    /// Exponential-backoff schedule for auto-reconnect, in seconds. After the
    /// last entry we stay at that cap forever (until a successful connect
    /// resets the index).
    private let reconnectBackoffSchedule: [TimeInterval] = [2, 5, 15, 30, 60]

    /// Index into `reconnectBackoffSchedule` for the next retry. Reset to 0
    /// on every successful Identify and on every manual `reconnectNow()`.
    private var reconnectAttemptIndex: Int = 0

    /// Most-recent host/port/password used to connect. The auto-reconnect
    /// loop dials these; `nil` means nothing is configured yet (idle state).
    private var lastConnectParams: (host: String, port: Int, password: String)?

    /// Pending DispatchWorkItem for the next scheduled reconnect. We keep it
    /// so `reconnectNow()` and `disconnect()` can cancel it.
    private var pendingReconnectWorkItem: DispatchWorkItem?

    /// If true, the user has explicitly called `disconnect()` (e.g. app
    /// terminating) and we should NOT schedule further reconnect attempts.
    /// Reset on the next explicit `connect(...)` call.
    private var autoReconnectSuppressed: Bool = false

    // Pending request callbacks, with the timestamp at which they were
    // registered so we can time them out and avoid leaking forever if OBS
    // never replies (crash, network drop, etc.).
    private struct PendingCallback {
        let callback: (Any?) -> Void
        let registeredAt: Date
    }

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var password: String = ""
    private var pendingCallbacks: [String: PendingCallback] = [:]
    private var requestCounter = 0
    private var callbackCleanupTimer: Timer?

    /// Maximum time we'll wait for a request response before considering it
    /// timed out and evicting its callback.
    private let callbackTimeout: TimeInterval = 30
    /// How often the cleanup timer runs.
    private let callbackCleanupInterval: TimeInterval = 30

    /// Lock protecting `pendingCallbacks` and `requestCounter` from concurrent
    /// access between the URLSession delegate queue and the main/timer queue.
    private let callbackLock = NSLock()

    private init() {
        startCallbackCleanupTimer()
    }

    deinit {
        callbackCleanupTimer?.invalidate()
        callbackCleanupTimer = nil
        pendingReconnectWorkItem?.cancel()
        pendingReconnectWorkItem = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Connection

    /// Kick off a connection attempt. Remembers the params so the
    /// auto-reconnect loop can re-dial after a drop.
    func connect(host: String, port: Int, password: String) {
        lastConnectParams = (host: host, port: port, password: password)
        autoReconnectSuppressed = false
        reconnectAttemptIndex = 0
        cancelPendingReconnect()
        performConnect(host: host, port: port, password: password)
    }

    /// Tear down any current socket and open a fresh one using the supplied
    /// credentials. Does NOT touch `lastConnectParams` / backoff state — that
    /// lets the auto-reconnect loop reuse this method without resetting the
    /// "manual connect" bookkeeping.
    private func performConnect(host: String, port: Int, password: String) {
        tearDownSocket()
        self.password = password

        let urlString = "ws://\(host):\(port)"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionError = "Invalid URL: \(urlString)"
                self?.publishState(.disconnected(message: "Invalid URL: \(urlString)"))
            }
            scheduleReconnect()
            return
        }

        let newSession = URLSession(configuration: .default)
        let newTask = newSession.webSocketTask(with: url)
        session = newSession
        webSocket = newTask
        newTask.resume()

        DispatchQueue.main.async { [weak self] in
            self?.connectionError = nil
        }
        receiveMessage(on: newTask)
    }

    /// User-initiated disconnect — suppresses auto-reconnect until the next
    /// explicit `connect()`. Called from `applicationWillTerminate`.
    func disconnect() {
        autoReconnectSuppressed = true
        cancelPendingReconnect()
        tearDownSocket()
        failAllPendingCallbacks()

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.publishState(.idle)
        }
    }

    /// Manually trigger an immediate reconnect attempt and reset the backoff
    /// schedule. Called from the "Reconnect now" pill button and the menu
    /// bar's "Reconnect to OBS" item.
    func reconnectNow() {
        guard let params = lastConnectParams else { return }
        autoReconnectSuppressed = false
        reconnectAttemptIndex = 0
        cancelPendingReconnect()
        performConnect(host: params.host, port: params.port, password: params.password)
    }

    /// Tear down the current webSocket/session pair without touching state
    /// that callers may still need (auto-reconnect bookkeeping, published
    /// state). Shared by `disconnect()` and `performConnect()`.
    private func tearDownSocket() {
        // Drop refs BEFORE cancelling so any in-flight `receiveMessage`
        // closure sees `webSocket !== task` and bails out instead of
        // recursing against the dead socket.
        let oldTask = webSocket
        let oldSession = session
        webSocket = nil
        session = nil
        oldTask?.cancel(with: .normalClosure, reason: nil)
        oldSession?.invalidateAndCancel()
    }

    // MARK: - Message Handling

    /// Recursively receive messages from the given task. We capture the task
    /// explicitly (instead of dereferencing `self.webSocket` again) so that if
    /// the manager reconnects mid-flight we won't accidentally keep the old
    /// task's receive loop alive against a new socket.
    private func receiveMessage(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            // If the task we're receiving on has been replaced (reconnect) or
            // cleared (disconnect), stop the loop right here. The new task —
            // if any — has its own receive loop running.
            guard self.webSocket === task else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Re-check task identity before scheduling another receive,
                // in case `handleMessage` triggered a reconnect.
                guard self.webSocket === task else { return }
                self.receiveMessage(on: task)

            case .failure(let error):
                print("[OBScene] WebSocket error: \(error)")
                // Don't recurse on error — let the auto-reconnect loop
                // re-establish the connection. Recursing here would just spin
                // on a dead socket.
                //
                // Guard against double-handling: if `webSocket` has already
                // been replaced (e.g. manual reconnect), the new loop will
                // own the state.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Only react to errors from the *current* task. Older
                    // tasks that were swapped out during a reconnect will
                    // also emit a failure here and we want to ignore those.
                    guard self.webSocket === task || self.webSocket == nil else { return }
                    self.isConnected = false
                    self.connectionError = error.localizedDescription
                    self.scheduleReconnect(errorMessage: error.localizedDescription)
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let op = json?["op"] as? Int,
                  let d = json?["d"] else { return }

            switch op {
            case 0: // Hello
                handleHello(d)
            case 2: // Identified (connected successfully)
                handleIdentified()
            case 7: // RequestResponse
                handleRequestResponse(d)
            default:
                break
            }
        } catch {
            print("[OBScene] Failed to parse message: \(error)")
        }
    }

    private func handleHello(_ d: Any) {
        guard let helloData = d as? [String: Any] else { return }

        var authString: String?

        if let auth = helloData["authentication"] as? [String: Any],
           let challenge = auth["challenge"] as? String,
           let salt = auth["salt"] as? String,
           !password.isEmpty {
            authString = generateAuthResponse(password: password, challenge: challenge, salt: salt)
        }

        let identify: [String: Any] = {
            var dict: [String: Any] = ["rpcVersion": 1]
            if let auth = authString {
                dict["authentication"] = auth
            }
            // Subscribe to all events
            dict["eventSubscriptions"] = 1023
            return dict
        }()

        sendMessage(op: 1, d: identify)
    }

    private func handleIdentified() {
        print("[OBScene] Connected to OBS WebSocket")
        // Successful handshake — reset backoff and cancel any scheduled
        // reconnect so we don't bounce the freshly-established socket.
        reconnectAttemptIndex = 0
        cancelPendingReconnect()

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            self?.connectionError = nil
            self?.publishState(.connected)
        }

        // Fetch initial state
        fetchSceneCollections()
        fetchProfiles()
        fetchScenes()
    }

    private func handleRequestResponse(_ d: Any) {
        guard let responseData = d as? [String: Any],
              let requestId = responseData["requestId"] as? String else { return }

        callbackLock.lock()
        let pending = pendingCallbacks.removeValue(forKey: requestId)
        callbackLock.unlock()

        if let pending = pending {
            let data = responseData["responseData"]
            pending.callback(data)
        }
    }

    // MARK: - Pending callback lifecycle

    private func startCallbackCleanupTimer() {
        // Schedule on the main run loop in common modes so it fires while
        // menus are tracking, etc.
        let timer = Timer(timeInterval: callbackCleanupInterval, repeats: true) { [weak self] _ in
            self?.evictExpiredCallbacks()
        }
        callbackCleanupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func evictExpiredCallbacks() {
        let cutoff = Date().addingTimeInterval(-callbackTimeout)
        var expired: [PendingCallback] = []

        callbackLock.lock()
        let expiredKeys = pendingCallbacks.compactMap { (key, value) -> String? in
            value.registeredAt < cutoff ? key : nil
        }
        for key in expiredKeys {
            if let value = pendingCallbacks.removeValue(forKey: key) {
                expired.append(value)
            }
        }
        callbackLock.unlock()

        if !expired.isEmpty {
            print("[OBScene] Evicted \(expired.count) timed-out OBS request callback(s)")
        }
        // Invoke timed-out callbacks with nil so callers can drop their state.
        for pending in expired {
            pending.callback(nil)
        }
    }

    private func failAllPendingCallbacks() {
        callbackLock.lock()
        let all = pendingCallbacks
        pendingCallbacks.removeAll()
        callbackLock.unlock()

        for (_, pending) in all {
            pending.callback(nil)
        }
    }

    // MARK: - Auto-reconnect

    /// Publish a new connection state on the main queue and broadcast the
    /// legacy `.obsConnectionChanged` notification so pre-existing observers
    /// (menu bar, etc.) pick it up too.
    private func publishState(_ newState: OBSConnectionState) {
        // Must be called on main because `@Published` dispatches to
        // whichever queue writes happen on, and the UI observes from main.
        assert(Thread.isMainThread, "publishState must be called on the main queue")
        connectionState = newState
        NotificationCenter.default.post(name: .obsConnectionChanged, object: nil)
    }

    /// Figure out how long to wait before the next reconnect. Caps at the
    /// last entry of `reconnectBackoffSchedule` forever until a successful
    /// connect resets the index.
    private func currentBackoffDelay() -> TimeInterval {
        let idx = min(reconnectAttemptIndex, reconnectBackoffSchedule.count - 1)
        return reconnectBackoffSchedule[idx]
    }

    /// Cancel any scheduled reconnect DispatchWorkItem. Safe to call when
    /// nothing is pending.
    private func cancelPendingReconnect() {
        pendingReconnectWorkItem?.cancel()
        pendingReconnectWorkItem = nil
    }

    /// Schedule the next reconnect attempt using the current backoff delay,
    /// then advance the backoff index for the one after. Does nothing if the
    /// user has explicitly disconnected or if we never had connect params.
    private func scheduleReconnect(errorMessage: String? = nil) {
        guard !autoReconnectSuppressed else { return }
        guard lastConnectParams != nil else {
            DispatchQueue.main.async { [weak self] in
                self?.publishState(.disconnected(message: errorMessage))
            }
            return
        }

        let delay = currentBackoffDelay()
        reconnectAttemptIndex += 1

        let nextAt = Date().addingTimeInterval(delay)
        DispatchQueue.main.async { [weak self] in
            self?.publishState(.retrying(nextAttemptAt: nextAt, delay: delay))
        }

        // Clear any prior pending work item before installing a new one so
        // we don't end up with two racing reconnects (e.g. if both the
        // receive-loop error handler and a URLSession delegate callback
        // call this within the same tick).
        cancelPendingReconnect()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // If someone called disconnect() / reconnectNow() in the meantime,
            // the cancelled flag will be set. Bail out cleanly.
            if self.pendingReconnectWorkItem?.isCancelled ?? true {
                return
            }
            guard !self.autoReconnectSuppressed else { return }
            guard let latest = self.lastConnectParams else { return }
            print("[OBScene] Auto-reconnect attempt (backoff index \(self.reconnectAttemptIndex))")
            self.performConnect(host: latest.host, port: latest.port, password: latest.password)
        }
        pendingReconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Authentication

    private func generateAuthResponse(password: String, challenge: String, salt: String) -> String {
        // Step 1: Concatenate password + salt, then SHA256 + base64
        let secret = sha256Base64(password + salt)
        // Step 2: Concatenate secret + challenge, then SHA256 + base64
        let authResponse = sha256Base64(secret + challenge)
        return authResponse
    }

    private func sha256Base64(_ input: String) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }

    // MARK: - Sending Messages

    private func sendMessage(op: Int, d: Any) {
        let message: [String: Any] = ["op": op, "d": d]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(text)) { error in
            if let error = error {
                print("[OBScene] Send error: \(error)")
            }
        }
    }

    private func sendRequest(_ requestType: String, data: [String: Any]? = nil, completion: ((Any?) -> Void)? = nil) {
        callbackLock.lock()
        requestCounter += 1
        let requestId = "req_\(requestCounter)"
        if let completion = completion {
            pendingCallbacks[requestId] = PendingCallback(callback: completion, registeredAt: Date())
        }
        callbackLock.unlock()

        var request: [String: Any] = [
            "requestType": requestType,
            "requestId": requestId
        ]
        if let data = data {
            request["requestData"] = data
        }

        sendMessage(op: 6, d: request)
    }

    // MARK: - OBS Commands

    func fetchSceneCollections() {
        sendRequest("GetSceneCollectionList") { [weak self] response in
            guard let data = response as? [String: Any] else { return }
            let collections = data["sceneCollections"] as? [String] ?? []
            let current = data["currentSceneCollectionName"] as? String ?? ""
            DispatchQueue.main.async {
                self?.sceneCollections = collections
                self?.currentSceneCollection = current
            }
        }
    }

    func fetchProfiles() {
        sendRequest("GetProfileList") { [weak self] response in
            guard let data = response as? [String: Any] else { return }
            let profileList = data["profiles"] as? [String] ?? []
            let current = data["currentProfileName"] as? String ?? ""
            DispatchQueue.main.async {
                self?.profiles = profileList
                self?.currentProfile = current
            }
        }
    }

    func fetchScenes() {
        sendRequest("GetSceneList") { [weak self] response in
            guard let data = response as? [String: Any] else { return }
            let sceneList = data["scenes"] as? [[String: Any]] ?? []
            let sceneNames = sceneList.compactMap { $0["sceneName"] as? String }
            let current = data["currentProgramSceneName"] as? String ?? ""
            DispatchQueue.main.async {
                self?.scenes = sceneNames.reversed() // OBS returns them in reverse order
                self?.currentScene = current
            }
        }
    }

    func setSceneCollection(_ name: String) {
        sendRequest("SetCurrentSceneCollection", data: ["sceneCollectionName": name])
    }

    func setProfile(_ name: String) {
        sendRequest("SetCurrentProfile", data: ["profileName": name])
    }

    func setScene(_ name: String) {
        sendRequest("SetCurrentProgramScene", data: ["sceneName": name])
    }

    // MARK: - Verified profile / scene collection switching
    //
    // Fire-and-forget `SetCurrentProfile` / `SetCurrentSceneCollection` are
    // unreliable in practice: when a user plugs in a tracked device we've seen
    // the scene collection change but the profile silently fail to apply,
    // leaving OBS half-switched. The fix has three parts:
    //
    //   1. Order matters — switch the profile FIRST (it lags more than the
    //      scene collection on OBS's side). That ordering is enforced by the
    //      caller in `DisplayMonitor.runTriggerActions`.
    //   2. Verify the change actually landed by polling OBS for the current
    //      value after the set request — don't trust the request succeeded
    //      just because OBS ACKed it.
    //   3. Retry up to 3 times with exponential backoff (1s, 2s, 4s) if the
    //      verification times out, because OBS occasionally drops a profile
    //      switch when it's busy. Bug fix 2026-04-18.
    //
    // The actual state machine lives in `VerifiedSetEngine` so it can be
    // unit-tested in isolation (see `scripts/test-retry-verify.swift`).

    private static let verifiedSetConfig = VerifiedSetConfig()

    /// Dependency bundle that wires the pure engine up to this manager.
    private func verifiedSetDeps(
        requestType: String,
        dataBuilder: @escaping (String) -> [String: Any],
        fetchRequestType: String,
        currentKey: String,
        listKeypath: @escaping () -> [String]
    ) -> VerifiedSetDependencies {
        return VerifiedSetDependencies(
            isConnected: { [weak self] in self?.isConnected ?? false },
            knownList: listKeypath,
            apply: { [weak self] target, done in
                self?.sendRequest(
                    requestType,
                    data: dataBuilder(target)
                ) { _ in done() }
            },
            fetchCurrent: { [weak self] done in
                self?.sendRequest(fetchRequestType) { response in
                    let current = (response as? [String: Any])?[currentKey] as? String
                    done(current)
                }
            },
            log: { message in
                print("[OBScene] \(message)")
                ActivityLog.shared.log(.info, message)
            }
        )
    }

    /// Set the current OBS profile and verify it landed, retrying up to 3x.
    /// Completion runs on the main queue with `.success` once verified, or
    /// `.failure(VerifiedSetError)` after exhausting retries.
    func setProfileAndVerify(
        _ name: String,
        completion: @escaping (Result<Void, VerifiedSetError>) -> Void
    ) {
        // OBS WebSocket v5 has no `GetCurrentProfile` — the current profile
        // name is returned alongside `GetProfileList`.
        let deps = verifiedSetDeps(
            requestType: "SetCurrentProfile",
            dataBuilder: { ["profileName": $0] },
            fetchRequestType: "GetProfileList",
            currentKey: "currentProfileName",
            listKeypath: { [weak self] in self?.profiles ?? [] }
        )
        VerifiedSetEngine.run(
            kind: "profile",
            target: name,
            config: Self.verifiedSetConfig,
            deps: deps
        ) { result in
            if case .failure(let err) = result {
                Self.notifyUserOfVerifiedSetFailure(kind: "profile", error: err)
            }
            completion(result)
        }
    }

    /// Set the current OBS scene collection and verify it landed, retrying
    /// up to 3x. See `setProfileAndVerify` for semantics.
    func setSceneCollectionAndVerify(
        _ name: String,
        completion: @escaping (Result<Void, VerifiedSetError>) -> Void
    ) {
        let deps = verifiedSetDeps(
            requestType: "SetCurrentSceneCollection",
            dataBuilder: { ["sceneCollectionName": $0] },
            fetchRequestType: "GetSceneCollectionList",
            currentKey: "currentSceneCollectionName",
            listKeypath: { [weak self] in self?.sceneCollections ?? [] }
        )
        VerifiedSetEngine.run(
            kind: "scene collection",
            target: name,
            config: Self.verifiedSetConfig,
            deps: deps
        ) { result in
            if case .failure(let err) = result {
                Self.notifyUserOfVerifiedSetFailure(kind: "scene collection", error: err)
            }
            completion(result)
        }
    }

    /// Surface a notification to the user when a verified-set ultimately
    /// fails. Kept separate from the engine so tests don't pop NSUserNotifications.
    private static func notifyUserOfVerifiedSetFailure(kind: String, error: VerifiedSetError) {
        switch error {
        case .notConnected:
            UserNotifier.post(
                title: "OBScene: couldn't switch \(kind)",
                body: "OBS WebSocket disconnected while switching \(kind)."
            )
        case .notFound(let name, _):
            UserNotifier.post(
                title: "OBScene: \(kind) not found",
                body: "'\(name)' is not a known \(kind) in OBS — check your OBScene config."
            )
        case .verificationFailed(let target, let current, let attempts):
            UserNotifier.post(
                title: "OBScene: couldn't switch \(kind)",
                body: "Failed to change \(kind) to '\(target)' after \(attempts) attempts — OBS reports '\(current ?? "unknown")'."
            )
        }
    }

    func startRecording() {
        sendRequest("StartRecord") { _ in
            ActivityLog.shared.log(.recordingStarted, "Recording started")
            UserNotifier.post(title: "OBScene", body: "Recording started")
        }
    }

    func stopRecording() {
        sendRequest("StopRecord")
    }

    func startStreaming() {
        sendRequest("StartStream") { _ in
            ActivityLog.shared.log(.streamingStarted, "Streaming started")
            UserNotifier.post(title: "OBScene", body: "Streaming started")
        }
    }

    func stopStreaming() {
        sendRequest("StopStream")
    }

    func startVirtualCam() {
        sendRequest("StartVirtualCam") { _ in
            ActivityLog.shared.log(.virtualCamStarted, "Virtual camera started")
            UserNotifier.post(title: "OBScene", body: "Virtual camera started")
        }
    }

    func stopVirtualCam() {
        sendRequest("StopVirtualCam")
    }

    func startReplayBuffer() {
        sendRequest("StartReplayBuffer") { _ in
            ActivityLog.shared.log(.replayBufferStarted, "Replay buffer started")
            UserNotifier.post(title: "OBScene", body: "Replay buffer started")
        }
    }

    func stopReplayBuffer() {
        sendRequest("StopReplayBuffer")
    }

    /// Refresh all browser sources in OBS by pressing the "Refresh cache of
    /// current page" button on each one via `PressInputPropertiesButton`.
    func refreshAllBrowserSources() {
        sendRequest("GetInputList", data: ["inputKind": "browser_source"]) { [weak self] response in
            guard let self = self else { return }
            guard let data = response as? [String: Any],
                  let inputs = data["inputs"] as? [[String: Any]] else {
                print("[OBScene] Failed to get browser source list from OBS")
                DispatchQueue.main.async {
                    ActivityLog.shared.log(.info, "Failed to list OBS browser sources")
                }
                return
            }

            if inputs.isEmpty {
                print("[OBScene] No browser sources found in OBS")
                DispatchQueue.main.async {
                    ActivityLog.shared.log(.info, "No OBS browser sources to refresh")
                }
                return
            }

            var refreshedCount = 0
            let total = inputs.count

            for input in inputs {
                guard let inputName = input["inputName"] as? String else { continue }

                self.sendRequest("PressInputPropertiesButton", data: [
                    "inputName": inputName,
                    "propertyName": "refresh"
                ]) { _ in
                    refreshedCount += 1
                    if refreshedCount == total {
                        print("[OBScene] Refreshed \(refreshedCount) OBS browser source(s)")
                        DispatchQueue.main.async {
                            ActivityLog.shared.log(.info, "Refreshed \(refreshedCount) OBS browser source(s)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - OBS process detection + launch

    /// Bundle identifier used by OBS Studio on macOS.
    static let obsBundleIdentifier = "com.obsproject.obs-studio"

    /// Returns true if an OBS Studio process is currently running.
    func isOBSRunning() -> Bool {
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == OBSWebSocketManager.obsBundleIdentifier
        }
    }

    /// Returns the filesystem URL of the installed OBS Studio app, or nil if
    /// OBS is not installed on this machine.
    func obsApplicationURL() -> URL? {
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: OBSWebSocketManager.obsBundleIdentifier
        )
    }

    /// Launch OBS Studio if it's installed. Returns false when OBS isn't
    /// installed on this machine.
    @discardableResult
    func launchOBS() -> Bool {
        guard let url = obsApplicationURL() else { return false }

        // Launch OBS headlessly (no Dock bounce, don't steal focus) so the
        // user isn't yanked out of whatever they were doing when they plugged
        // in a display.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.hides = false

        NSWorkspace.shared.openApplication(at: url, configuration: config) { runningApp, error in
            if let error = error {
                print("[OBScene] Failed to launch OBS: \(error)")
                return
            }
            // Kick off the Safe Mode dialog watcher (no-op if OBS didn't
            // unclean-shutdown last run). OBS has no CLI flag to suppress
            // the Safe Mode modal as of 32.x — we AX-click "Launch Normally"
            // on the user's behalf so trigger actions don't stall behind a
            // blocking dialog.
            if let app = runningApp {
                DispatchQueue.main.async {
                    SafeModeDialogDismisser.shared.watchForDialog(runningApp: app)
                }
            }
        }
        return true
    }

    // MARK: - Ensure-connected flow (for auto-launch)

    /// Result of attempting to make sure the WebSocket is connected before a
    /// trigger fires its OBS commands.
    enum EnsureConnectedResult {
        /// Already connected, or became connected within the timeout.
        case connected
        /// OBS isn't installed (no app bundle with `com.obsproject.obs-studio`).
        case obsNotInstalled
        /// OBS process is running but the WebSocket server never became
        /// available within the timeout — usually because the user hasn't
        /// enabled Tools → WebSocket Server Settings.
        case websocketUnavailable
        /// User has auto-launch disabled and OBS isn't running / connected.
        case autoLaunchDisabled
        /// The attempt was cancelled (e.g. displays disconnected mid-launch).
        case cancelled
    }

    /// A cancellable handle for an in-flight `ensureConnected` attempt.
    final class EnsureConnectedHandle {
        fileprivate var cancelled = false
        func cancel() { cancelled = true }
    }

    /// The single in-flight ensure-connected attempt. Only one of these runs
    /// at a time so we don't spawn two launch attempts if the user unplugs
    /// and replugs during startup.
    private var inflightEnsureHandle: EnsureConnectedHandle?
    private let ensureLock = NSLock()

    /// Make sure the WebSocket is connected before invoking `onReady`.
    ///
    /// If already connected, `onReady` runs immediately. Otherwise:
    ///   - If OBS isn't running and auto-launch is enabled, launch it.
    ///   - Poll (every 500ms) up to `timeoutSeconds` for the WebSocket to
    ///     accept a connection.
    ///   - Call `onReady` with the result on the main queue.
    ///
    /// `host`, `port`, `password` come from the caller so we don't touch
    /// ConfigStore from here (keeps this method testable and side-effect free
    /// apart from the launch + connect calls).
    ///
    /// Returns a handle that can be cancelled if the trigger becomes moot
    /// (e.g. displays disconnected during the wait).
    @discardableResult
    func ensureConnected(
        host: String,
        port: Int,
        password: String,
        autoLaunch: Bool,
        timeoutSeconds: Int,
        onReady: @escaping (EnsureConnectedResult) -> Void
    ) -> EnsureConnectedHandle {
        // Coalesce: if one is already running, cancel it and replace. This
        // prevents double-launches when the user unplugs + replugs during the
        // wait window.
        ensureLock.lock()
        inflightEnsureHandle?.cancelled = true
        let handle = EnsureConnectedHandle()
        inflightEnsureHandle = handle
        ensureLock.unlock()

        // Fast path: already connected.
        if isConnected {
            DispatchQueue.main.async { onReady(.connected) }
            return handle
        }

        let running = isOBSRunning()

        if !running {
            guard autoLaunch else {
                DispatchQueue.main.async { onReady(.autoLaunchDisabled) }
                return handle
            }
            guard obsApplicationURL() != nil else {
                DispatchQueue.main.async { onReady(.obsNotInstalled) }
                return handle
            }
            print("[OBScene] OBS not running — launching…")
            ActivityLog.shared.log(.info, "OBS not running — launching")
            _ = launchOBS()
        } else {
            print("[OBScene] OBS running but not connected — attempting to reconnect")
            ActivityLog.shared.log(.info, "OBS running — reconnecting WebSocket")
        }

        // Kick off (or restart) the connection attempt.
        connect(host: host, port: port, password: password)

        pollForConnection(
            handle: handle,
            host: host,
            port: port,
            password: password,
            deadline: Date().addingTimeInterval(TimeInterval(max(timeoutSeconds, 1))),
            reconnectEvery: 3.0,
            lastReconnectAt: Date(),
            onReady: onReady
        )

        return handle
    }

    /// Poll the `isConnected` flag every 500ms until the deadline. We also
    /// re-issue `connect()` every `reconnectEvery` seconds so that once OBS
    /// finishes starting up and binds the WebSocket port, we'll actually
    /// notice — the first `connect()` call issued while OBS was still booting
    /// may have errored out immediately and left us in a terminal state.
    private func pollForConnection(
        handle: EnsureConnectedHandle,
        host: String,
        port: Int,
        password: String,
        deadline: Date,
        reconnectEvery: TimeInterval,
        lastReconnectAt: Date,
        onReady: @escaping (EnsureConnectedResult) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            if handle.cancelled {
                onReady(.cancelled)
                return
            }

            if self.isConnected {
                onReady(.connected)
                return
            }

            if Date() >= deadline {
                // Distinguish "OBS never came up" from "OBS is up but WS is
                // disabled" — both look the same from our side (no handshake),
                // but if the process is running we can give a more useful
                // error.
                if self.isOBSRunning() {
                    onReady(.websocketUnavailable)
                } else {
                    onReady(.websocketUnavailable)
                }
                return
            }

            // Re-attempt connect periodically so we survive the first few
            // failed sockets while OBS is still booting.
            var nextLastReconnect = lastReconnectAt
            if Date().timeIntervalSince(lastReconnectAt) >= reconnectEvery {
                self.connect(host: host, port: port, password: password)
                nextLastReconnect = Date()
            }

            self.pollForConnection(
                handle: handle,
                host: host,
                port: port,
                password: password,
                deadline: deadline,
                reconnectEvery: reconnectEvery,
                lastReconnectAt: nextLastReconnect,
                onReady: onReady
            )
        }
    }

    /// Cancel any in-flight ensure-connected attempt. Called when the user
    /// unplugs mid-wait so we don't keep polling for a trigger that's been
    /// cancelled.
    func cancelInflightEnsureConnected() {
        ensureLock.lock()
        inflightEnsureHandle?.cancelled = true
        inflightEnsureHandle = nil
        ensureLock.unlock()
    }
}
