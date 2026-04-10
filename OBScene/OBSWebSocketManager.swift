import Foundation
import CommonCrypto

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
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Connection

    func connect(host: String, port: Int, password: String) {
        disconnect()
        self.password = password

        let urlString = "ws://\(host):\(port)"
        guard let url = URL(string: urlString) else {
            connectionError = "Invalid URL: \(urlString)"
            return
        }

        let newSession = URLSession(configuration: .default)
        let newTask = newSession.webSocketTask(with: url)
        session = newSession
        webSocket = newTask
        newTask.resume()

        connectionError = nil
        receiveMessage(on: newTask)
    }

    func disconnect() {
        // Tear down the existing task/session and drop our references BEFORE
        // notifying observers. This way any in-flight `receiveMessage` closure
        // will see that `webSocket` no longer matches the task it captured and
        // bail out instead of recursing.
        if let task = webSocket {
            task.cancel(with: .normalClosure, reason: nil)
        }
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil

        // Fail any pending callbacks so callers don't hang forever.
        failAllPendingCallbacks()

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            NotificationCenter.default.post(name: .obsConnectionChanged, object: nil)
        }
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
                // Don't recurse on error — let reconnection logic / the user
                // re-establish the connection. Recursing here would just spin
                // on a dead socket.
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.connectionError = error.localizedDescription
                    NotificationCenter.default.post(name: .obsConnectionChanged, object: nil)
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
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            self?.connectionError = nil
            NotificationCenter.default.post(name: .obsConnectionChanged, object: nil)
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

    func startRecording() {
        sendRequest("StartRecord")
    }

    func stopRecording() {
        sendRequest("StopRecord")
    }

    func startStreaming() {
        sendRequest("StartStream")
    }

    func stopStreaming() {
        sendRequest("StopStream")
    }
}
