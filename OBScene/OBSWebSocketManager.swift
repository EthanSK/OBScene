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

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var password: String = ""
    private var pendingCallbacks: [String: (Any?) -> Void] = [:]
    private var requestCounter = 0

    private init() {}

    // MARK: - Connection

    func connect(host: String, port: Int, password: String) {
        disconnect()
        self.password = password

        let urlString = "ws://\(host):\(port)"
        guard let url = URL(string: urlString) else {
            connectionError = "Invalid URL: \(urlString)"
            return
        }

        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        connectionError = nil
        receiveMessage()
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session = nil

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            NotificationCenter.default.post(name: .obsConnectionChanged, object: nil)
        }
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()

            case .failure(let error):
                print("[OBScene] WebSocket error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.connectionError = error.localizedDescription
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

        if let callback = pendingCallbacks.removeValue(forKey: requestId) {
            let data = responseData["responseData"]
            callback(data)
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
        requestCounter += 1
        let requestId = "req_\(requestCounter)"

        if let completion = completion {
            pendingCallbacks[requestId] = completion
        }

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
