import Foundation
import Combine
import UserNotifications

struct ActivityEvent: Identifiable, Equatable {
    enum Kind {
        case displayConnected
        case displayDisconnected
        case usbDeviceConnected
        case usbDeviceDisconnected
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
            case .usbDeviceConnected: return "cable.connector"
            case .usbDeviceDisconnected: return "cable.connector.slash"
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

// MARK: - Trigger Profile

/// A single trigger profile. Each profile has its own trigger type (display or
/// USB device), OBS configuration (scene collection, profile, scene), and
/// trigger actions. Multiple profiles can be active simultaneously.
struct TriggerProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "New Profile"
    var isEnabled: Bool = true

    /// The type of trigger for this profile.
    enum TriggerType: String, Codable, CaseIterable {
        case display = "display"
        case usbDevice = "usb_device"

        var label: String {
            switch self {
            case .display: return "External Display"
            case .usbDevice: return "USB Device"
            }
        }

        var symbol: String {
            switch self {
            case .display: return "display.2"
            case .usbDevice: return "cable.connector"
            }
        }
    }

    var triggerType: TriggerType = .display

    // Display trigger settings
    var requiredExternalDisplays: Int = 1

    // USB trigger settings
    var usbDeviceName: String = ""

    // OBS configuration
    var selectedSceneCollection: String = ""
    var selectedProfile: String = ""
    var selectedScene: String = ""

    // Trigger actions
    var startRecording: Bool = false
    var startStreaming: Bool = false
    var startVirtualCam: Bool = false
    var startReplayBuffer: Bool = false
    var stopRecordingOnUnplug: Bool = false
    var stopStreamingOnUnplug: Bool = false
    var stopVirtualCamOnUnplug: Bool = false
    var stopReplayBufferOnUnplug: Bool = false

    // Browser refresh
    var refreshBrowsersOnTrigger: Bool = true
    var refreshOBSBrowserSourcesOnTrigger: Bool = false

    // Trigger delay
    var triggerDelay: Int = 5

    init() {}

    // Custom decoder for forward compatibility — new fields fall back to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? name
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        triggerType = try container.decodeIfPresent(TriggerType.self, forKey: .triggerType) ?? triggerType
        requiredExternalDisplays = try container.decodeIfPresent(Int.self, forKey: .requiredExternalDisplays) ?? requiredExternalDisplays
        usbDeviceName = try container.decodeIfPresent(String.self, forKey: .usbDeviceName) ?? usbDeviceName
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
        refreshBrowsersOnTrigger = try container.decodeIfPresent(Bool.self, forKey: .refreshBrowsersOnTrigger) ?? refreshBrowsersOnTrigger
        refreshOBSBrowserSourcesOnTrigger = try container.decodeIfPresent(Bool.self, forKey: .refreshOBSBrowserSourcesOnTrigger) ?? refreshOBSBrowserSourcesOnTrigger
        triggerDelay = try container.decodeIfPresent(Int.self, forKey: .triggerDelay) ?? triggerDelay
    }
}

// MARK: - App Config

struct AppConfig: Codable, Equatable {
    var obsHost: String = "localhost"
    var obsPort: Int = 4455
    var obsPassword: String = ""
    var hasBeenConfigured: Bool = false
    var autoLaunchOBS: Bool = true
    var obsLaunchTimeoutSeconds: Int = 30

    /// Ordered list of trigger profiles. Each profile has its own trigger type,
    /// OBS configuration, and actions. Multiple can be active simultaneously.
    var profiles: [TriggerProfile] = []

    /// Index of the currently selected profile tab in the Settings UI.
    /// Not used for trigger logic — purely a UI hint so the selected tab
    /// persists across settings window open/close.
    var selectedProfileIndex: Int = 0

    // Legacy fields kept for migration from pre-profiles config.
    // After migration these are ignored; the canonical data lives in `profiles`.
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
    var refreshBrowsersOnTrigger: Bool = true
    var refreshOBSBrowserSourcesOnTrigger: Bool = false

    init() {}

    // Custom decoder so that adding new fields to `AppConfig` doesn't wipe out
    // an existing user's saved configuration. Any key missing from the stored
    // JSON falls back to the property's default value above.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        obsHost = try container.decodeIfPresent(String.self, forKey: .obsHost) ?? obsHost
        obsPort = try container.decodeIfPresent(Int.self, forKey: .obsPort) ?? obsPort
        obsPassword = try container.decodeIfPresent(String.self, forKey: .obsPassword) ?? obsPassword
        hasBeenConfigured = try container.decodeIfPresent(Bool.self, forKey: .hasBeenConfigured) ?? hasBeenConfigured
        autoLaunchOBS = try container.decodeIfPresent(Bool.self, forKey: .autoLaunchOBS) ?? autoLaunchOBS
        obsLaunchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .obsLaunchTimeoutSeconds) ?? obsLaunchTimeoutSeconds
        profiles = try container.decodeIfPresent([TriggerProfile].self, forKey: .profiles) ?? profiles
        selectedProfileIndex = try container.decodeIfPresent(Int.self, forKey: .selectedProfileIndex) ?? selectedProfileIndex

        // Legacy fields (for migration)
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
        refreshBrowsersOnTrigger = try container.decodeIfPresent(Bool.self, forKey: .refreshBrowsersOnTrigger) ?? refreshBrowsersOnTrigger
        refreshOBSBrowserSourcesOnTrigger = try container.decodeIfPresent(Bool.self, forKey: .refreshOBSBrowserSourcesOnTrigger) ?? refreshOBSBrowserSourcesOnTrigger
    }

    /// Migrate legacy single-config settings into the profiles array. Called
    /// once on load when `profiles` is empty but legacy fields have data. After
    /// migration the legacy fields remain in the JSON but are ignored — the
    /// canonical source of truth is `profiles`.
    mutating func migrateToProfilesIfNeeded() {
        guard profiles.isEmpty else { return }
        // Only migrate if the user had actually configured something.
        guard hasBeenConfigured else {
            // Fresh install — seed a default "Displays" profile.
            var defaultProfile = TriggerProfile()
            defaultProfile.name = "Displays"
            defaultProfile.triggerType = .display
            profiles = [defaultProfile]
            return
        }
        var profile = TriggerProfile()
        profile.name = "Displays"
        profile.triggerType = .display
        profile.requiredExternalDisplays = requiredExternalDisplays
        profile.selectedSceneCollection = selectedSceneCollection
        profile.selectedProfile = selectedProfile
        profile.selectedScene = selectedScene
        profile.startRecording = startRecording
        profile.startStreaming = startStreaming
        profile.startVirtualCam = startVirtualCam
        profile.startReplayBuffer = startReplayBuffer
        profile.stopRecordingOnUnplug = stopRecordingOnUnplug
        profile.stopStreamingOnUnplug = stopStreamingOnUnplug
        profile.stopVirtualCamOnUnplug = stopVirtualCamOnUnplug
        profile.stopReplayBufferOnUnplug = stopReplayBufferOnUnplug
        profile.refreshBrowsersOnTrigger = refreshBrowsersOnTrigger
        profile.refreshOBSBrowserSourcesOnTrigger = refreshOBSBrowserSourcesOnTrigger
        profile.triggerDelay = triggerDelay
        profiles = [profile]
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
        config.migrateToProfilesIfNeeded()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    // MARK: - Profile helpers

    /// Returns all enabled profiles of the given trigger type.
    func enabledProfiles(ofType type: TriggerProfile.TriggerType) -> [TriggerProfile] {
        return config.profiles.filter { $0.isEnabled && $0.triggerType == type }
    }

    /// Returns all enabled display-trigger profiles whose threshold is met by
    /// the given external display count.
    func displayProfilesReadyToFire(externalDisplayCount: Int) -> [TriggerProfile] {
        return enabledProfiles(ofType: .display).filter {
            externalDisplayCount >= $0.requiredExternalDisplays
        }
    }

    /// Returns all enabled USB-trigger profiles whose device name matches.
    func usbProfilesMatching(deviceName: String) -> [TriggerProfile] {
        return enabledProfiles(ofType: .usbDevice).filter {
            !$0.usbDeviceName.isEmpty &&
            deviceName.localizedCaseInsensitiveContains($0.usbDeviceName)
        }
    }
}
