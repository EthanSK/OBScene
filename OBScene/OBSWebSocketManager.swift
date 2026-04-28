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

    /// Refresh ALL browser sources in OBS by pressing the "Refresh cache of
    /// current page" button on each one via `PressInputPropertiesButton`.
    ///
    /// Each source is refreshed independently: a failure on one source does
    /// not abort the others. Each attempt is logged individually so users can
    /// see in the Activity tab exactly which sources refreshed and which
    /// failed. We also defensively filter the inputs to browser sources
    /// client-side — some OBS builds have been observed to ignore the
    /// `inputKind` query parameter and return every input, which would cause
    /// us to try to press a non-existent "refresh" button on non-browser
    /// inputs. Bug fix 2026-04-21.
    func refreshAllBrowserSources() {
        sendRequest("GetInputList", data: ["inputKind": "browser_source"]) { [weak self] response in
            guard let self = self else { return }
            guard let data = response as? [String: Any],
                  let allInputs = data["inputs"] as? [[String: Any]] else {
                print("[OBScene] Failed to get browser source list from OBS")
                DispatchQueue.main.async {
                    ActivityLog.shared.log(.info, "Failed to list OBS browser sources")
                }
                return
            }

            // Defensive client-side filter in case OBS ignored `inputKind`.
            let browserInputs = allInputs.filter { input in
                // When `inputKind` filtering worked server-side, `inputKind`
                // may be absent from the response — accept those too.
                guard let kind = input["inputKind"] as? String else { return true }
                return kind == "browser_source"
            }

            if browserInputs.isEmpty {
                print("[OBScene] No browser sources found in OBS")
                DispatchQueue.main.async {
                    ActivityLog.shared.log(.info, "No OBS browser sources to refresh")
                }
                return
            }

            let total = browserInputs.count
            let names = browserInputs.compactMap { $0["inputName"] as? String }
            print("[OBScene] Refreshing \(total) OBS browser source(s): \(names.joined(separator: ", "))")
            DispatchQueue.main.async {
                ActivityLog.shared.log(.info, "Refreshing \(total) OBS browser source(s)")
            }

            // Fire a refresh for each source independently. The OBS WebSocket
            // handles these in parallel; each reply goes through its own
            // request-id callback so one failing source cannot abort the rest.
            // We don't have visibility into per-request success/failure here
            // (`PressInputPropertiesButton` returns void and OBScene's request
            // callback surface only exposes `responseData`, which is nil on
            // both success and timeout). The best we can do is log that the
            // refresh was dispatched for each named source — that's still a
            // meaningful improvement over the previous code, which only logged
            // a single aggregate line and silently did nothing if the counter
            // never hit `total`.
            for input in browserInputs {
                guard let inputName = input["inputName"] as? String else { continue }

                // OBS 32.1.1's browser-source plugin exposes the manual
                // refresh button under the internal property name
                // `refreshnocache`, not `refresh`. Using `refresh` causes OBS
                // WebSocket to reject the request with code 600
                // ("Unable to find a property by that name.") and nothing is
                // actually reloaded.
                self.sendRequest("PressInputPropertiesButton", data: [
                    "inputName": inputName,
                    "propertyName": "refreshnocache"
                ])

                DispatchQueue.main.async {
                    ActivityLog.shared.log(.info, "Refreshed browser source '\(inputName)'")
                    print("[OBScene] Refreshed browser source '\(inputName)'")
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
                // OBS accepted our WebSocket handshake, which means it's
                // past the Safe Mode dialog gate (the dialog blocks OBS's
                // UI thread before the WebSocket server starts accepting
                // connections). Cancel the watcher launchOBS() may have
                // started so a subsequent quit/restart inside the watcher's
                // 15s window doesn't emit a misleading "process exited /
                // dialog never appeared" log.
                SafeModeDialogDismisser.shared.cancelWatcher()
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

    // MARK: - Live-session status (used by restart-OBS pre-flight)

    /// Fetch the current OBS streaming state. The completion is invoked with
    /// `true` if OBS reports an active stream, `false` if not, and `nil` if
    /// the request failed / timed out (caller should treat nil as "unknown,
    /// don't kill OBS just in case").
    func getStreamingActive(completion: @escaping (Bool?) -> Void) {
        sendRequest("GetStreamStatus") { response in
            guard let data = response as? [String: Any] else {
                completion(nil); return
            }
            // OBS WebSocket v5 returns `outputActive: Bool` for GetStreamStatus.
            if let active = data["outputActive"] as? Bool {
                completion(active)
            } else {
                completion(nil)
            }
        }
    }

    /// Fetch the current OBS recording state. See `getStreamingActive` for
    /// the nil-vs-false semantics.
    func getRecordingActive(completion: @escaping (Bool?) -> Void) {
        sendRequest("GetRecordStatus") { response in
            guard let data = response as? [String: Any] else {
                completion(nil); return
            }
            if let active = data["outputActive"] as? Bool {
                completion(active)
            } else {
                completion(nil)
            }
        }
    }

    /// Issue a `GetVersion` ping. Used after a restart to verify the OBS
    /// WebSocket has come back online and is answering. Completion fires with
    /// `true` on a successful response, `false` if the request returned no
    /// data (treated as not-yet-ready by callers).
    func getVersion(completion: @escaping (Bool) -> Void) {
        sendRequest("GetVersion") { response in
            completion(response as? [String: Any] != nil)
        }
    }

    /// Persist the current OBS scene-collection state to disk via
    /// `SaveSceneCollection`. Best-effort — if OBS doesn't recognise the
    /// request (older builds), the call simply has no effect and the
    /// completion still fires.
    func saveSceneCollection(completion: @escaping () -> Void) {
        sendRequest("SaveSceneCollection") { _ in
            completion()
        }
    }
}

// MARK: - Permission denial notification
//
// Surfaced to SettingsView so the user gets an actionable alert with a
// deep-link to the relevant System Settings pane when an OBS-restart fails
// because macOS blocked the Apple Event used by `terminate()`.
//
// `NSRunningApplication.terminate()` on a different app's process sends a
// "quit" Apple Event. macOS gates that with the **Automation** TCC
// permission (System Settings -> Privacy & Security -> Automation -> OBScene
// -> OBS). The first call shows the standard "OBScene wants to control OBS"
// prompt; if denied (or revoked), subsequent calls return `true` but the
// event is silently dropped — OBS keeps running. We detect that by polling
// the PID for an early sign of exit and posting this notification when no
// progress is made within `permissionDenialDetectionSeconds`.
extension Notification.Name {
    /// Posted when OBScene believes a privileged operation was blocked by a
    /// missing TCC permission. `userInfo` carries:
    ///   - `obscenePermissionKind`: a `OBScenePermissionKind` raw value
    ///     ("automation" | "accessibility").
    ///   - `obscenePermissionTarget`: a human-readable name of the target
    ///     app, e.g. "OBS Studio".
    ///   - `obscenePermissionContext`: a one-line user-facing description of
    ///     what was being attempted (e.g. "restart OBS before running script").
    static let obscenePermissionDenied = Notification.Name("obscenePermissionDenied")
}

/// Categories of macOS TCC permissions OBScene cares about. Maps to the
/// deep-link URL used to open the right System Settings pane.
enum OBScenePermissionKind: String {
    case automation
    case accessibility

    /// Deep-link to System Settings -> Privacy & Security -> <kind>.
    /// Verified working on macOS 13+ (System Settings) and macOS 12
    /// (System Preferences) — the same URL scheme is honoured by both.
    var systemSettingsURL: URL {
        switch self {
        case .automation:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    /// Section name shown in the alert, kept consistent with the System
    /// Settings pane title so users can locate the row visually.
    var displayName: String {
        switch self {
        case .automation: return "Automation"
        case .accessibility: return "Accessibility"
        }
    }
}

// MARK: - OBSAppController
//
// Quit-and-relaunch pipeline used by the per-profile "Restart OBS before
// running" toggle. This is a workaround for the Custom Browser Dock refresh
// limitation in OBS — there is no programmatic refresh API for docks, so a
// full app restart is the only reliable way to make a dock pick up an updated
// URL / cookie / channel after we change something externally.
//
// Sequence:
//   1. Pre-flight: ask OBS for GetStreamStatus + GetRecordStatus. If either
//      is active, fire StopStream / StopRecord via obs-websocket and poll
//      until both report inactive (capped at ~20s — recording finalisation
//      via obs-ffmpeg-mux can take a few seconds for large files). We do
//      NOT auto-resume after restart — the user has to re-arm streaming /
//      recording manually. If the stop never lands within the cap we abort
//      the restart (we never kill a live capture session under us).
//   2. Best-effort SaveSceneCollection so the relaunched OBS sees latest state.
//   3. Graceful terminate() of the running OBS application (NOT SIGKILL —
//      OBS needs to write its own config files cleanly so the next launch
//      doesn't show the "OBS Studio did not shut down properly" / safe-mode
//      dialog).
//   4. Poll until NSRunningApplication for that PID is gone, with a 30s cap
//      (was 15s — bumped because OBS's clean-shutdown flag is only written
//      AFTER it finishes flushing config + stopping outputs, and we'd
//      occasionally time out before that completed). Checkpoint logs every
//      5s so a future stuck-shutdown investigation can see where in the
//      window we are. If it doesn't exit cleanly, abort and DO NOT run the
//      script.
//   5. Relaunch via NSWorkspace.shared.openApplication. macOS restores window
//      position automatically because OBS persisted it on the graceful quit.
//   6. Poll the OBS WebSocket with GetVersion until it answers, capped at 30s.
//      If it never answers, abort and DO NOT run the script.
//   7. Wait an extra ~1.5s for browser docks to fetch their URLs (they load
//      async after OBS starts).
//   8. Hand control back to the caller via `beforeRun()`.
//
// Throttling: if a restart was started or completed within the last 30s, the
// next call short-circuits and runs `beforeRun()` immediately. This prevents
// USB plug events that bounce 3x in 2s from queuing up multiple restarts.
//
// All steps log to ActivityLog with `.info` so they show up in the in-app
// Activity tab and in the existing OBScene log file pipeline.

enum OBSAppController {

    /// Throttle window — successive restart requests inside this many seconds
    /// of the most recent in-progress / completed restart run the script
    /// immediately instead of restarting again.
    private static let throttleWindow: TimeInterval = 30.0

    /// Maximum time we'll wait for OBS to exit after sending terminate(),
    /// in seconds. After this we abort the restart (we do NOT escalate to
    /// SIGKILL — that would risk corrupting OBS config files). Bumped from
    /// 15s to 30s on 2026-04-27 because OBS only sets its "clean shutdown"
    /// flag AFTER finishing config-file writes + output cleanup; the old
    /// 15s window occasionally clipped that, leaving the next launch with
    /// the "OBS Studio did not shut down properly" / safe-mode dialog.
    private static let terminateTimeoutSeconds: TimeInterval = 30.0

    /// Maximum time we'll wait for active StopStream / StopRecord calls to
    /// land (i.e. for `getStreamingActive` / `getRecordingActive` to flip
    /// back to false). The recording-stop path involves obs-ffmpeg-mux
    /// finalising the on-disk file, which can take several seconds for
    /// large recordings; 20s is conservative without making the user wait
    /// forever on a broken OBS.
    private static let stopOutputsTimeoutSeconds: TimeInterval = 20.0

    /// Maximum time we'll wait for the OBS WebSocket to come back up after
    /// we relaunch the app, in seconds.
    private static let websocketReadyTimeoutSeconds: TimeInterval = 30.0

    /// Extra settle delay after the WebSocket reports ready, to give browser
    /// docks time to fetch their URLs (they load async post-launch).
    private static let postReadySettleSeconds: TimeInterval = 1.5

    /// Per-request cap for best-effort probes inside the restart flow. OBS
    /// request callbacks have a broader generic cleanup path, but restart
    /// orchestration needs its own shorter caps so the documented restart
    /// deadlines remain meaningful if OBS exits mid-request.
    private static let restartRequestTimeoutSeconds: TimeInterval = 2.0

    /// If `terminate()` returned true but the OBS PID is still healthy
    /// (`NSRunningApplication.isTerminated == false`) after this many seconds,
    /// we treat it as a *silently-blocked Apple Event* — i.e. macOS dropped
    /// the quit event because the Automation TCC permission for OBScene ->
    /// OBS Studio is denied. We post `obscenePermissionDenied` so the UI
    /// can surface a deep-link to System Settings. Tuned conservatively:
    /// OBS normally begins exiting within a few hundred ms of receiving
    /// the quit AE, so 3s gives ample headroom for a slow machine without
    /// being so long that the user thinks the app is hung.
    private static let permissionDenialDetectionSeconds: TimeInterval = 3.0

    /// Mutated only on the main thread (every entry point dispatches to .main
    /// before touching this). Stores the timestamp at which the most recent
    /// restart was kicked off so subsequent fires within `throttleWindow`
    /// can short-circuit.
    private static var lastRestartAt: Date?

    /// True when a restart is currently in progress. Concurrent calls during
    /// the in-flight window short-circuit straight to `beforeRun()` so a
    /// burst of plug events doesn't queue up multiple restarts.
    private static var restartInFlight: Bool = false

    /// Public entry point. Called from DisplayMonitor's profile-fire handler
    /// when `profile.restartOBSBeforeRun == true`. `profileName` is logged for
    /// auditability. `beforeRun` is the closure that actually invokes the
    /// user's script (via ScriptRunner) — we call it after the restart
    /// settles, OR immediately when we skip / throttle.
    ///
    /// `isSimulated` is true when the trigger came from the Settings
    /// "Simulate Trigger" button. In that case we ALWAYS invoke `beforeRun()`
    /// even on the abort paths inside `performRestart` (terminate timeout,
    /// relaunch error, websocket-ready timeout) — the user clicked Simulate
    /// expecting the activate-script to fire, and silently dropping it
    /// because OBS misbehaved makes the dry-run useless. For real
    /// (USB / display) triggers we keep the original abort-on-failure
    /// semantics so a flaky restart doesn't kick off a script when the
    /// surrounding OBS pipeline is going to fail anyway.
    static func restartOBS(profileName: String,
                           isSimulated: Bool = false,
                           beforeRun: @escaping () -> Void) {
        DispatchQueue.main.async {
            // Throttle: a recent or in-flight restart short-circuits.
            if Self.restartInFlight {
                ActivityLog.shared.log(.info,
                    "OBS restart already in progress (\(profileName)) — skipping restart, running script")
                beforeRun()
                return
            }
            if let last = Self.lastRestartAt,
               Date().timeIntervalSince(last) < Self.throttleWindow {
                ActivityLog.shared.log(.info,
                    "OBS restart throttled (last was <\(Int(Self.throttleWindow))s ago, \(profileName)) — running script")
                beforeRun()
                return
            }

            ActivityLog.shared.log(.info, "OBS restart requested for profile \(profileName)")

            let obs = OBSWebSocketManager.shared

            // If OBS isn't running at all, there's nothing to restart — just
            // run the script. Auto-launch (if configured) is handled by the
            // existing trigger pipeline downstream.
            guard obs.isOBSRunning() else {
                ActivityLog.shared.log(.info,
                    "OBS not running — skipping restart, running script (\(profileName))")
                beforeRun()
                return
            }

            // If OBScene isn't currently connected to the WebSocket, we have
            // no way to query streaming/recording state — bail safely (don't
            // kill OBS blind). Run the script anyway so the user-visible side
            // effect still happens.
            guard obs.isConnected else {
                ActivityLog.shared.log(.info,
                    "OBS not connected to WebSocket — skipping restart for safety, running script (\(profileName))")
                beforeRun()
                return
            }

            // Reserve the restart slot before the async pre-flight so two
            // concurrent profile fires cannot both pass the throttle and
            // initiate separate restarts.
            Self.restartInFlight = true

            // Pre-flight: check streaming + recording state in parallel. If
            // either is active we issue StopStream / StopRecord and wait for
            // them to land before proceeding. The user is NOT auto-resumed
            // after restart — that's a deliberate design choice (simple >
            // smart for now).
            Self.checkLiveSession(obs: obs) { state in
                let proceed: () -> Void = {
                    // Cleared for restart. Record timestamp for post-restart throttle.
                    Self.lastRestartAt = Date()

                    // Best-effort save of scene-collection state before quitting.
                    Self.saveSceneCollectionBestEffort(obs: obs) {
                        DispatchQueue.main.async {
                            Self.performRestart(
                                profileName: profileName,
                                isSimulated: isSimulated,
                                beforeRun: beforeRun
                            )
                        }
                    }
                }

                switch state {
                case .inactive:
                    proceed()

                case .unknown:
                    // We couldn't determine state (request failed or timed
                    // out). Safer to abort than to terminate OBS while it
                    // might be live — log + run the script and bail.
                    ActivityLog.shared.log(.info,
                        "OBS streaming/recording state unknown — aborting restart for safety, running script (\(profileName))")
                    Self.restartInFlight = false
                    beforeRun()

                case .active(let streaming, let recording):
                    let activeKinds = [
                        streaming ? "streaming" : nil,
                        recording ? "recording" : nil,
                    ].compactMap { $0 }.joined(separator: " + ")
                    ActivityLog.shared.log(.info,
                        "OBS \(activeKinds) active — stopping before restart (\(profileName))")
                    Self.stopOutputs(
                        obs: obs,
                        streaming: streaming,
                        recording: recording,
                        profileName: profileName
                    ) { stopped in
                        DispatchQueue.main.async {
                            if !stopped {
                                ActivityLog.shared.log(.info,
                                    "OBS stop-outputs did not complete within \(Int(Self.stopOutputsTimeoutSeconds))s — aborting restart, running script (\(profileName))")
                                Self.restartInFlight = false
                                beforeRun()
                                return
                            }
                            ActivityLog.shared.log(.info,
                                "OBS stop-outputs complete, proceeding with restart (\(profileName))")
                            proceed()
                        }
                    }
                }
            }
        }
    }

    /// Pre-flight outcome used by `restartOBS` to decide between proceeding,
    /// aborting on unknown state, or stopping active outputs first.
    private enum LiveState {
        /// Neither streaming nor recording is active.
        case inactive
        /// We could not determine the state (request failed or timed out).
        case unknown
        /// At least one of streaming / recording is active. The associated
        /// values are the individual flags so we know which Stop* requests
        /// to issue.
        case active(streaming: Bool, recording: Bool)
    }

    /// Issue StopStream / StopRecord for whichever output(s) the caller flagged
    /// as active, then poll `getStreamingActive` / `getRecordingActive` until
    /// both report false (or the timeout expires). `completion(true)` means
    /// both reported inactive within the window; `completion(false)` means we
    /// timed out (caller should abort the restart). All decision points log
    /// to ActivityLog so a future stuck-stop investigation can see what
    /// happened and when.
    private static func stopOutputs(obs: OBSWebSocketManager,
                                    streaming: Bool,
                                    recording: Bool,
                                    profileName: String,
                                    completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            if streaming {
                ActivityLog.shared.log(.info,
                    "OBS StopStream invoked (\(profileName))")
                obs.stopStreaming()
            }
            if recording {
                ActivityLog.shared.log(.info,
                    "OBS StopRecord invoked (\(profileName))")
                obs.stopRecording()
            }

            let startedAt = Date()
            let deadline = startedAt.addingTimeInterval(Self.stopOutputsTimeoutSeconds)
            var lastLoggedStream: Bool? = nil
            var lastLoggedRecord: Bool? = nil
            var completed = false

            func complete(_ stopped: Bool) {
                guard !completed else { return }
                completed = true
                completion(stopped)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopOutputsTimeoutSeconds) {
                complete(false)
            }

            func tick() {
                guard !completed else { return }
                if Date() >= deadline {
                    complete(false)
                    return
                }

                // Re-query state. We deliberately fire both probes regardless
                // of which one was originally active — `getStreamingActive`
                // and `getRecordingActive` are cheap and we want to make sure
                // we don't accidentally proceed while one of them flipped on.
                let requestTimeout = min(
                    Self.restartRequestTimeoutSeconds,
                    max(0.1, deadline.timeIntervalSinceNow)
                )
                Self.getOutputActivityWithTimeout(obs: obs, timeoutSeconds: requestTimeout) { streamingActive, recordingActive in
                    DispatchQueue.main.async {
                        guard !completed else { return }
                        if Date() >= deadline {
                            complete(false)
                            return
                        }

                        // Treat nil as "still active / unknown" so we
                        // keep polling until the deadline rather than
                        // racing past a transient request failure.
                        let streamLive = streamingActive ?? true
                        let recordLive = recordingActive ?? true

                        // Log only on transition to keep the activity
                        // log readable on slow muxer finalisations.
                        if streamLive != lastLoggedStream {
                            ActivityLog.shared.log(.info,
                                "OBS streaming active = \(streamLive) (\(profileName))")
                            lastLoggedStream = streamLive
                        }
                        if recordLive != lastLoggedRecord {
                            ActivityLog.shared.log(.info,
                                "OBS recording active = \(recordLive) (\(profileName))")
                            lastLoggedRecord = recordLive
                        }

                        if !streamLive && !recordLive {
                            let elapsed = Date().timeIntervalSince(startedAt)
                            ActivityLog.shared.log(.info,
                                "OBS outputs stopped after \(String(format: "%.1f", elapsed))s (\(profileName))")
                            complete(true)
                            return
                        }

                        // Still busy — schedule the next poll. 500ms
                        // strikes a balance between responsiveness and
                        // not hammering the WebSocket while obs-ffmpeg
                        // is finalising a recording.
                        let delay = min(0.5, max(0.0, deadline.timeIntervalSinceNow))
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            tick()
                        }
                    }
                }
            }

            tick()
        }
    }

    private static func getOutputActivityWithTimeout(
        obs: OBSWebSocketManager,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Bool?, Bool?) -> Void
    ) {
        DispatchQueue.main.async {
            var streamActive: Bool?
            var streamDone = false
            var recordActive: Bool?
            var recordDone = false
            var completed = false

            func complete() {
                guard !completed else { return }
                completed = true
                completion(streamDone ? streamActive : nil,
                           recordDone ? recordActive : nil)
            }

            func finishIfReady() {
                guard streamDone, recordDone else { return }
                complete()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                complete()
            }

            obs.getStreamingActive { active in
                DispatchQueue.main.async {
                    guard !completed else { return }
                    streamActive = active
                    streamDone = true
                    finishIfReady()
                }
            }
            obs.getRecordingActive { active in
                DispatchQueue.main.async {
                    guard !completed else { return }
                    recordActive = active
                    recordDone = true
                    finishIfReady()
                }
            }
        }
    }

    private static func saveSceneCollectionBestEffort(obs: OBSWebSocketManager,
                                                      completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            var completed = false

            func complete() {
                guard !completed else { return }
                completed = true
                completion()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartRequestTimeoutSeconds) {
                complete()
            }

            obs.saveSceneCollection {
                DispatchQueue.main.async {
                    complete()
                }
            }
        }
    }

    /// Dispatch streaming + recording status checks in parallel and resolve
    /// to a `LiveState` describing what the caller should do:
    ///   - `.inactive`   — both probes returned `false`. Safe to restart.
    ///   - `.active`     — at least one probe returned `true`. Caller should
    ///                     stop the relevant outputs first.
    ///   - `.unknown`    — at least one probe returned `nil` (request failed
    ///                     or the 5s pre-flight cap fired). Caller should
    ///                     abort the restart for safety.
    ///
    /// We deliberately distinguish unknown from active so the restart flow
    /// can react differently: an active session is a clear "stop first" path,
    /// while an unknown state means we have no signal about what's running
    /// inside OBS and shouldn't gamble on terminating it.
    private static func checkLiveSession(obs: OBSWebSocketManager,
                                         completion: @escaping (LiveState) -> Void) {
        DispatchQueue.main.async {
            var streamActive: Bool?
            var streamDone = false
            var recordActive: Bool?
            var recordDone = false
            var completed = false

            func complete(_ state: LiveState) {
                guard !completed else { return }
                completed = true
                completion(state)
            }

            func finishIfReady() {
                guard streamDone, recordDone else { return }
                // `nil` from either probe means we couldn't determine state.
                // Surface that as `.unknown` so the caller aborts.
                guard let streaming = streamActive, let recording = recordActive else {
                    complete(.unknown)
                    return
                }
                if streaming || recording {
                    complete(.active(streaming: streaming, recording: recording))
                } else {
                    complete(.inactive)
                }
            }

            // Hard cap on the pre-flight: if OBS doesn't reply within 5s,
            // treat that as `.unknown` so the caller aborts the restart.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                complete(.unknown)
            }

            obs.getStreamingActive { active in
                DispatchQueue.main.async {
                    guard !completed else { return }
                    streamActive = active
                    streamDone = true
                    finishIfReady()
                }
            }
            obs.getRecordingActive { active in
                DispatchQueue.main.async {
                    guard !completed else { return }
                    recordActive = active
                    recordDone = true
                    finishIfReady()
                }
            }
        }
    }

    /// Step 3 onwards: terminate, wait, relaunch, wait for websocket, settle,
    /// then call `beforeRun()`. When `isSimulated` is true we also call
    /// `beforeRun()` from every abort path so the user's activate script
    /// always runs from a Simulate Trigger click — see `restartOBS` doc for
    /// the rationale.
    private static func performRestart(profileName: String,
                                       isSimulated: Bool,
                                       beforeRun: @escaping () -> Void) {
        let obs = OBSWebSocketManager.shared

        // Re-resolve the running OBS instance (it may have exited between the
        // pre-flight and now — unlikely but possible).
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == OBSWebSocketManager.obsBundleIdentifier
        }) else {
            ActivityLog.shared.log(.info,
                "OBS no longer running at restart step — running script (\(profileName))")
            Self.restartInFlight = false
            beforeRun()
            return
        }
        let pid = runningApp.processIdentifier
        guard let obsAppURL = obs.obsApplicationURL() else {
            ActivityLog.shared.log(.info,
                "OBS app bundle not resolvable — aborting restart (\(profileName))")
            Self.restartInFlight = false
            // We never quit OBS here — we just couldn't resolve the bundle URL
            // for the relaunch step. Run the script anyway (for real and
            // simulated triggers) since the OBS app is still in whatever
            // state it was before this attempt.
            beforeRun()
            return
        }

        // Disconnect our own WebSocket up-front so the auto-reconnect loop
        // doesn't fight the quit + relaunch. We re-issue an explicit connect
        // after OBS is back up.
        let host = ConfigStore.shared.config.obsHost
        let port = ConfigStore.shared.config.obsPort
        let password = ConfigStore.shared.config.obsPassword
        obs.disconnect()

        func restoreWebSocketAfterAbort() {
            obs.connect(host: host, port: port, password: password)
        }

        // Graceful quit. NSRunningApplication.terminate() is the AppleScript-
        // equivalent ("tell application … to quit") — OBS gets a chance to
        // write its config and shut down cleanly.
        let quitStartedAt = Date()
        let didTerminate = runningApp.terminate()
        if !didTerminate {
            ActivityLog.shared.log(.info,
                "OBS terminate() returned false — aborting restart (\(profileName))")
            // terminate() returning false generally means the AE round-trip
            // failed outright (target gone or refused). We can't tell from
            // the Cocoa API whether that was TCC vs. some other reason, so
            // surface the most likely actionable explanation.
            Self.postPermissionDenied(
                kind: .automation,
                targetName: "OBS Studio",
                context: "restart OBS before running profile \"\(profileName)\""
            )
            Self.restartInFlight = false
            restoreWebSocketAfterAbort()
            // terminate() returned false BEFORE we did anything destructive —
            // OBS is still up in its original state. Run the script (matches
            // pre-isSimulated behaviour for real triggers; the dry-run path
            // also wants the script regardless).
            beforeRun()
            return
        }
        ActivityLog.shared.log(.info, "OBS terminate() sent (\(profileName))")

        // Early permission-denial probe: if the PID is still healthy after
        // `permissionDenialDetectionSeconds` we *suspect* TCC silently
        // dropped the quit AE, so we surface a one-shot notification. We
        // keep polling for the full `terminateTimeoutSeconds` window in
        // case OBS is just slow to start exiting — the notification is
        // advisory, not terminal. Captures `runningApp` so we can read
        // `isTerminated` without re-resolving by PID (which can race when
        // a new process recycles the same PID).
        let probeRunningApp = runningApp
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.permissionDenialDetectionSeconds
        ) {
            // Still in flight AND target hasn't started exiting? Most likely
            // explanation on a healthy machine is TCC blocked the AE. We
            // post the notification once and let `pollForExit` continue —
            // if OBS exits later, we just relaunch and the user got an
            // unnecessary alert (acceptable false-positive trade-off).
            guard Self.restartInFlight, !probeRunningApp.isTerminated else { return }
            ActivityLog.shared.log(.info,
                "OBS still running \(Int(Self.permissionDenialDetectionSeconds))s after terminate() — suspecting Automation permission denied (\(profileName))")
            Self.postPermissionDenied(
                kind: .automation,
                targetName: "OBS Studio",
                context: "restart OBS before running profile \"\(profileName)\""
            )
        }

        // Step 4: poll until the PID is no longer reachable.
        Self.pollForExit(pid: pid,
                         profileName: profileName,
                         deadline: Date().addingTimeInterval(Self.terminateTimeoutSeconds)) { exited in
            DispatchQueue.main.async {
                guard exited else {
                    let elapsed = Date().timeIntervalSince(quitStartedAt)
                    ActivityLog.shared.log(.info,
                        "OBS did not exit within \(Int(Self.terminateTimeoutSeconds))s (elapsed \(String(format: "%.1f", elapsed))s) — aborting restart (\(profileName))")
                    Self.restartInFlight = false
                    restoreWebSocketAfterAbort()
                    // Real triggers abort the whole flow on a failed restart
                    // (matching the original design); Simulate Trigger still
                    // runs the activate script so the user's dry-run shows
                    // every side effect they configured. See `restartOBS`.
                    if isSimulated { beforeRun() }
                    return
                }
                let elapsed = Date().timeIntervalSince(quitStartedAt)
                ActivityLog.shared.log(.info,
                    "OBS terminated after \(String(format: "%.1f", elapsed))s — relaunching (\(profileName))")

                // Step 5: relaunch.
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.addsToRecentItems = false
                config.hides = false
                NSWorkspace.shared.openApplication(at: obsAppURL, configuration: config) { runningApp, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            ActivityLog.shared.log(.info,
                                "OBS relaunch failed: \(error.localizedDescription) (\(profileName))")
                            Self.restartInFlight = false
                            restoreWebSocketAfterAbort()
                            // Simulate Trigger still runs the script even
                            // when relaunch fails — see `restartOBS` doc.
                            if isSimulated { beforeRun() }
                            return
                        }
                        if let app = runningApp {
                            // Same Safe Mode dialog watcher we use for the
                            // initial auto-launch path.
                            SafeModeDialogDismisser.shared.watchForDialog(runningApp: app)
                        }
                        ActivityLog.shared.log(.info,
                            "OBS relaunched, waiting for websocket... (\(profileName))")

                        // Re-issue our WebSocket connect attempt — this loops
                        // internally until it succeeds or we time out below.
                        obs.connect(host: host, port: port, password: password)

                        // Step 6: poll GetVersion.
                        Self.pollForWebSocketReady(
                            obs: obs,
                            host: host,
                            port: port,
                            password: password,
                            deadline: Date().addingTimeInterval(Self.websocketReadyTimeoutSeconds)
                        ) { ready in
                            DispatchQueue.main.async {
                                guard ready else {
                                    ActivityLog.shared.log(.info,
                                        "OBS websocket did not come up within \(Int(Self.websocketReadyTimeoutSeconds))s — aborting (\(profileName))")
                                    Self.restartInFlight = false
                                    // Simulate Trigger still runs the script
                                    // even when the websocket never came back
                                    // — see `restartOBS` doc.
                                    if isSimulated { beforeRun() }
                                    return
                                }
                                ActivityLog.shared.log(.info,
                                    "OBS ready, running script (\(profileName))")
                                // The Safe Mode dialog (if it was going to
                                // appear) blocks OBS's UI thread BEFORE the
                                // WebSocket server starts accepting
                                // connections. A successful WebSocket handshake
                                // means OBS is past that gate, so the watcher
                                // is now guaranteed to never fire. Cancel it
                                // to avoid a misleading "process exited
                                // before dialog appeared" log if OBS is later
                                // quit or restarted again.
                                SafeModeDialogDismisser.shared.cancelWatcher()
                                // Step 7: settle delay so docks finish loading.
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + Self.postReadySettleSeconds
                                ) {
                                    Self.restartInFlight = false
                                    beforeRun()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Poll until `NSRunningApplication(processIdentifier:)` returns nil, or
    /// until `deadline`. Calls `completion(true)` if it exited in time,
    /// `completion(false)` on timeout. Polls on a background queue at 250ms.
    /// Logs a checkpoint to ActivityLog every `checkpointInterval` so a
    /// future stuck-shutdown investigation can see where in the wait window
    /// we got stuck — useful when a clean OBS shutdown hangs on writing
    /// config / finalising files.
    private static func pollForExit(pid: pid_t,
                                    profileName: String,
                                    deadline: Date,
                                    completion: @escaping (Bool) -> Void) {
        let startedAt = Date()
        let checkpointInterval: TimeInterval = 5.0
        DispatchQueue.global().async {
            var nextCheckpoint = startedAt.addingTimeInterval(checkpointInterval)
            while Date() < deadline {
                if NSRunningApplication(processIdentifier: pid) == nil {
                    completion(true)
                    return
                }
                let now = Date()
                if now >= nextCheckpoint {
                    let waited = now.timeIntervalSince(startedAt)
                    ActivityLog.shared.log(.info,
                        "OBS still running \(String(format: "%.0f", waited))s after terminate() — continuing to wait (\(profileName))")
                    nextCheckpoint = now.addingTimeInterval(checkpointInterval)
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            // One final check after the loop in case the last sleep edged us
            // past the deadline.
            completion(NSRunningApplication(processIdentifier: pid) == nil)
        }
    }

    /// Poll the OBS WebSocket by issuing GetVersion every 1s (after waiting
    /// 500ms for the first attempt) until it succeeds or `deadline` passes.
    /// We also re-issue `connect()` every 4s in case the first connect attempt
    /// fired before OBS had finished binding the WebSocket port.
    private static func pollForWebSocketReady(
        obs: OBSWebSocketManager,
        host: String,
        port: Int,
        password: String,
        deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        // First check happens after a small delay so OBS has time to start
        // up and bind the port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.checkVersionLoop(
                obs: obs,
                host: host,
                port: port,
                password: password,
                deadline: deadline,
                lastReconnectAt: Date(),
                completion: completion
            )
        }
    }

    private static func checkVersionLoop(
        obs: OBSWebSocketManager,
        host: String,
        port: Int,
        password: String,
        deadline: Date,
        lastReconnectAt: Date,
        completion: @escaping (Bool) -> Void
    ) {
        if Date() >= deadline {
            completion(false)
            return
        }

        // We can only meaningfully ping GetVersion if we have a connection.
        // If not, re-issue connect() and try again on the next tick.
        if !obs.isConnected {
            var nextLastReconnect = lastReconnectAt
            if Date().timeIntervalSince(lastReconnectAt) >= 4.0 {
                obs.connect(host: host, port: port, password: password)
                nextLastReconnect = Date()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.checkVersionLoop(
                    obs: obs,
                    host: host,
                    port: port,
                    password: password,
                    deadline: deadline,
                    lastReconnectAt: nextLastReconnect,
                    completion: completion
                )
            }
            return
        }

        let requestTimeout = min(Self.restartRequestTimeoutSeconds, max(0.1, deadline.timeIntervalSinceNow))
        Self.getVersionWithTimeout(obs: obs, timeoutSeconds: requestTimeout) { ok in
            if ok {
                completion(true)
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.checkVersionLoop(
                    obs: obs,
                    host: host,
                    port: port,
                    password: password,
                    deadline: deadline,
                    lastReconnectAt: lastReconnectAt,
                    completion: completion
                )
            }
        }
    }

    /// Post a `obscenePermissionDenied` notification on the main queue so
    /// SettingsView can surface an actionable alert. De-duplicated across a
    /// short window so a burst of failures (e.g. terminate-returns-false +
    /// the 3s detection probe firing immediately after) only produces one
    /// alert per user-perceived event.
    private static var lastPermissionDenialAt: Date?
    private static let permissionDenialDedupeWindow: TimeInterval = 5.0

    private static func postPermissionDenied(kind: OBScenePermissionKind,
                                             targetName: String,
                                             context: String) {
        DispatchQueue.main.async {
            if let last = Self.lastPermissionDenialAt,
               Date().timeIntervalSince(last) < Self.permissionDenialDedupeWindow {
                return
            }
            Self.lastPermissionDenialAt = Date()
            NotificationCenter.default.post(
                name: .obscenePermissionDenied,
                object: nil,
                userInfo: [
                    "obscenePermissionKind": kind.rawValue,
                    "obscenePermissionTarget": targetName,
                    "obscenePermissionContext": context,
                ]
            )
        }
    }

    private static func getVersionWithTimeout(
        obs: OBSWebSocketManager,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            var completed = false

            func complete(_ ok: Bool) {
                guard !completed else { return }
                completed = true
                completion(ok)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                complete(false)
            }

            obs.getVersion { ok in
                DispatchQueue.main.async {
                    complete(ok)
                }
            }
        }
    }
}
