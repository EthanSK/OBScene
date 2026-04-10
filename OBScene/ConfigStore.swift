import Foundation
import Combine
import UserNotifications

struct ActivityEvent: Identifiable, Equatable {
    enum Kind {
        case displayConnected
        case displayDisconnected
        case triggerScheduled
        case triggerFired
        case recordingStarted
        case streamingStarted
        case virtualCamStarted
        case replayBufferStarted
        case info

        var symbol: String {
            switch self {
            case .displayConnected: return "display.2"
            case .displayDisconnected: return "display.trianglebadge.exclamationmark"
            case .triggerScheduled: return "clock"
            case .triggerFired: return "bolt.fill"
            case .recordingStarted: return "record.circle"
            case .streamingStarted: return "dot.radiowaves.left.and.right"
            case .virtualCamStarted: return "web.camera"
            case .replayBufferStarted: return "memorychip"
            case .info: return "info.circle"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let message: String
    let timestamp: Date

    static func == (lhs: ActivityEvent, rhs: ActivityEvent) -> Bool {
        lhs.id == rhs.id
    }
}

class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    @Published private(set) var events: [ActivityEvent] = []
    private let maxEvents = 20

    private init() {}

    func log(_ kind: ActivityEvent.Kind, _ message: String) {
        let event = ActivityEvent(kind: kind, message: message, timestamp: Date())
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.events.insert(event, at: 0)
            if self.events.count > self.maxEvents {
                self.events.removeLast(self.events.count - self.maxEvents)
            }
        }
    }
}

enum UserNotifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[OBScene] Notification permission error: \(error)")
            } else {
                print("[OBScene] Notification permission granted: \(granted)")
            }
        }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[OBScene] Failed to post notification: \(error)")
            }
        }
    }
}

struct AppConfig: Codable, Equatable {
    var obsHost: String = "localhost"
    var obsPort: Int = 4455
    var obsPassword: String = ""
    var selectedSceneCollection: String = ""
    var selectedProfile: String = ""
    var selectedScene: String = ""
    var startRecording: Bool = false
    var startStreaming: Bool = false
    var startVirtualCam: Bool = false
    var startReplayBuffer: Bool = false
    var stopRecordingOnUnplug: Bool = false
    var stopStreamingOnUnplug: Bool = false
    var stopVirtualCamOnUnplug: Bool = false
    var stopReplayBufferOnUnplug: Bool = false
    var triggerDelay: Int = 5
    var requiredExternalDisplays: Int = 1
    var hasBeenConfigured: Bool = false

    init() {}

    // Custom decoder so that adding new fields to `AppConfig` doesn't wipe out
    // an existing user's saved configuration. Any key missing from the stored
    // JSON falls back to the property's default value above.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        obsHost = try container.decodeIfPresent(String.self, forKey: .obsHost) ?? obsHost
        obsPort = try container.decodeIfPresent(Int.self, forKey: .obsPort) ?? obsPort
        obsPassword = try container.decodeIfPresent(String.self, forKey: .obsPassword) ?? obsPassword
        selectedSceneCollection = try container.decodeIfPresent(String.self, forKey: .selectedSceneCollection) ?? selectedSceneCollection
        selectedProfile = try container.decodeIfPresent(String.self, forKey: .selectedProfile) ?? selectedProfile
        selectedScene = try container.decodeIfPresent(String.self, forKey: .selectedScene) ?? selectedScene
        startRecording = try container.decodeIfPresent(Bool.self, forKey: .startRecording) ?? startRecording
        startStreaming = try container.decodeIfPresent(Bool.self, forKey: .startStreaming) ?? startStreaming
        startVirtualCam = try container.decodeIfPresent(Bool.self, forKey: .startVirtualCam) ?? startVirtualCam
        startReplayBuffer = try container.decodeIfPresent(Bool.self, forKey: .startReplayBuffer) ?? startReplayBuffer
        stopRecordingOnUnplug = try container.decodeIfPresent(Bool.self, forKey: .stopRecordingOnUnplug) ?? stopRecordingOnUnplug
        stopStreamingOnUnplug = try container.decodeIfPresent(Bool.self, forKey: .stopStreamingOnUnplug) ?? stopStreamingOnUnplug
        stopVirtualCamOnUnplug = try container.decodeIfPresent(Bool.self, forKey: .stopVirtualCamOnUnplug) ?? stopVirtualCamOnUnplug
        stopReplayBufferOnUnplug = try container.decodeIfPresent(Bool.self, forKey: .stopReplayBufferOnUnplug) ?? stopReplayBufferOnUnplug
        triggerDelay = try container.decodeIfPresent(Int.self, forKey: .triggerDelay) ?? triggerDelay
        requiredExternalDisplays = try container.decodeIfPresent(Int.self, forKey: .requiredExternalDisplays) ?? requiredExternalDisplays
        hasBeenConfigured = try container.decodeIfPresent(Bool.self, forKey: .hasBeenConfigured) ?? hasBeenConfigured
    }
}

class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet {
            save()
        }
    }

    private let key = "OBSceneConfig"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = AppConfig()
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}
