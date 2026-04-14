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

// MARK: - Trigger Action

/// The set of things OBScene can do when a trigger event fires. Some of these
/// have a meaningful start/stop distinction (recording, streaming, virtual
/// camera, replay buffer); others are one-shots (refreshing browsers).
enum TriggerActionKind: String, Codable, CaseIterable, Hashable {
    case recording = "recording"
    case streaming = "streaming"
    case virtualCam = "virtual_cam"
    case replayBuffer = "replay_buffer"
    case refreshBrowsers = "refresh_browsers"
    case refreshOBSBrowserSources = "refresh_obs_browser_sources"

    /// Human-readable label for Settings UI.
    var label: String {
        switch self {
        case .recording: return "Recording"
        case .streaming: return "Streaming"
        case .virtualCam: return "Virtual Camera"
        case .replayBuffer: return "Replay Buffer"
        case .refreshBrowsers: return "Refresh all browsers"
        case .refreshOBSBrowserSources: return "Refresh OBS browser sources"
        }
    }

    /// SF Symbol for Settings UI.
    var symbol: String {
        switch self {
        case .recording: return "record.circle"
        case .streaming: return "dot.radiowaves.left.and.right"
        case .virtualCam: return "web.camera"
        case .replayBuffer: return "memorychip"
        case .refreshBrowsers: return "arrow.clockwise"
        case .refreshOBSBrowserSources: return "arrow.clockwise.circle"
        }
    }

    /// Whether this action has a separate "stop" counterpart. Refresh actions
    /// are one-shots — start-mode is the only valid mode for them.
    var supportsStop: Bool {
        switch self {
        case .recording, .streaming, .virtualCam, .replayBuffer: return true
        case .refreshBrowsers, .refreshOBSBrowserSources: return false
        }
    }

    /// Stable display order for the action rows.
    static let displayOrder: [TriggerActionKind] = [
        .recording, .streaming, .virtualCam, .replayBuffer,
        .refreshBrowsers, .refreshOBSBrowserSources
    ]
}

/// Direction of a trigger action: either kicking something off or tearing it
/// down. Refresh-type actions always use `.start` as a no-op "fire the action"
/// marker; their UI hides the mode picker.
enum TriggerActionMode: String, Codable, CaseIterable, Hashable {
    case start = "start"
    case stop = "stop"

    var label: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        }
    }
}

/// A concrete action configuration within a profile's action set. The
/// `(kind, mode)` pair uniquely identifies the behaviour: e.g. "start
/// recording" vs "stop recording". The UI lists all action kinds and lets
/// the user toggle each on/off and choose a mode (where applicable).
struct TriggerActionConfig: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: TriggerActionKind
    var mode: TriggerActionMode

    init(id: UUID = UUID(), kind: TriggerActionKind, mode: TriggerActionMode) {
        self.id = id
        self.kind = kind
        // Refresh actions always force start mode.
        self.mode = kind.supportsStop ? mode : .start
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(TriggerActionKind.self, forKey: .kind)
        let decodedMode = try container.decodeIfPresent(TriggerActionMode.self, forKey: .mode) ?? .start
        mode = kind.supportsStop ? decodedMode : .start
    }
}

// MARK: - Profile Trigger Mode

/// Whether a profile fires on the plug-in edge (display count goes up past
/// threshold / matching USB device appears) or the plug-out edge (display
/// count drops below threshold / matching USB device disappears). Each
/// profile is one-or-the-other; to react to both edges, create two profiles.
enum ProfileTriggerMode: String, Codable, CaseIterable, Hashable {
    case plugIn = "plug_in"
    case plugOut = "plug_out"

    var label: String {
        switch self {
        case .plugIn:  return "Plug in mode"
        case .plugOut: return "Plug out mode"
        }
    }

    var shortLabel: String {
        switch self {
        case .plugIn:  return "plug in"
        case .plugOut: return "plug out"
        }
    }

    var symbol: String {
        switch self {
        case .plugIn:  return "arrow.down.to.line"
        case .plugOut: return "arrow.up.from.line"
        }
    }
}

// MARK: - Trigger Profile

/// A single trigger profile. Each profile has its own trigger type (display or
/// USB device), a mode (plug-in / plug-out), OBS configuration (scene
/// collection, profile, scene), and trigger actions. Multiple profiles can be
/// active simultaneously.
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

    /// Whether this profile fires on plug-in or plug-out. Defaults to plug-in
    /// for newly-created profiles.
    var mode: ProfileTriggerMode = .plugIn

    // Display trigger settings
    var requiredExternalDisplays: Int = 1

    // USB trigger settings
    var usbDeviceName: String = ""

    // OBS configuration
    var selectedSceneCollection: String = ""
    var selectedProfile: String = ""
    var selectedScene: String = ""

    /// Actions that fire when this profile's trigger edge is crossed. Each
    /// entry pairs an action kind with a mode (start or stop). Users can
    /// freely combine e.g. "start recording" and "stop streaming" in a single
    /// plug-in profile.
    var actions: [TriggerActionConfig] = []

    // MARK: Legacy fields (kept for migration only)
    //
    // Pre-mode schema stored per-action booleans on the profile directly, and
    // an intermediate dev build briefly split them into `onConnect` /
    // `onDisconnect` arrays. Both of those shapes are decoded into the new
    // `actions` list (plus a derived sibling profile where appropriate) by
    // `AppConfig.expandLegacyProfilesIfNeeded()`.
    var legacyOnConnect: [TriggerActionConfig] = []
    var legacyOnDisconnect: [TriggerActionConfig] = []
    var startRecording: Bool = false
    var startStreaming: Bool = false
    var startVirtualCam: Bool = false
    var startReplayBuffer: Bool = false
    var stopRecordingOnUnplug: Bool = false
    var stopStreamingOnUnplug: Bool = false
    var stopVirtualCamOnUnplug: Bool = false
    var stopReplayBufferOnUnplug: Bool = false
    var refreshBrowsersOnTrigger: Bool = true
    var refreshOBSBrowserSourcesOnTrigger: Bool = false
    /// Marker: true once the AppConfig-level expansion has rewritten this
    /// profile into the new single-list shape. Prevents us from re-migrating
    /// a profile that the user has since intentionally emptied.
    var migratedToModeSchema: Bool = false

    // Trigger delay
    var triggerDelay: Int = 5

    /// Delay (seconds) between successive actions when the profile fires. The
    /// first action fires immediately; each subsequent action is offset by
    /// `index * delayBetweenActions`. Defaults to 0 so existing profiles keep
    /// their original all-at-once behaviour.
    var delayBetweenActions: Double = 0.0

    init() {}

    // Coding keys — we persist the legacy per-action flags under their
    // original JSON names for round-trip compatibility, and map the
    // intermediate `onConnect` / `onDisconnect` JSON keys onto our
    // `legacy*` properties so an existing dev build's data round-trips too.
    enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, triggerType, mode
        case requiredExternalDisplays, usbDeviceName
        case selectedSceneCollection, selectedProfile, selectedScene
        case actions
        case legacyOnConnect = "onConnect"
        case legacyOnDisconnect = "onDisconnect"
        case startRecording, startStreaming, startVirtualCam, startReplayBuffer
        case stopRecordingOnUnplug, stopStreamingOnUnplug
        case stopVirtualCamOnUnplug, stopReplayBufferOnUnplug
        case refreshBrowsersOnTrigger, refreshOBSBrowserSourcesOnTrigger
        case migratedToModeSchema
        case triggerDelay
        case delayBetweenActions
    }

    // Custom decoder for forward compatibility — new fields fall back to
    // defaults and legacy fields round-trip until the AppConfig-level
    // expansion rewrites them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? name
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        triggerType = try container.decodeIfPresent(TriggerType.self, forKey: .triggerType) ?? triggerType
        mode = try container.decodeIfPresent(ProfileTriggerMode.self, forKey: .mode) ?? mode
        requiredExternalDisplays = try container.decodeIfPresent(Int.self, forKey: .requiredExternalDisplays) ?? requiredExternalDisplays
        usbDeviceName = try container.decodeIfPresent(String.self, forKey: .usbDeviceName) ?? usbDeviceName
        selectedSceneCollection = try container.decodeIfPresent(String.self, forKey: .selectedSceneCollection) ?? selectedSceneCollection
        selectedProfile = try container.decodeIfPresent(String.self, forKey: .selectedProfile) ?? selectedProfile
        selectedScene = try container.decodeIfPresent(String.self, forKey: .selectedScene) ?? selectedScene
        actions = try container.decodeIfPresent([TriggerActionConfig].self, forKey: .actions) ?? actions
        legacyOnConnect = try container.decodeIfPresent([TriggerActionConfig].self, forKey: .legacyOnConnect) ?? legacyOnConnect
        legacyOnDisconnect = try container.decodeIfPresent([TriggerActionConfig].self, forKey: .legacyOnDisconnect) ?? legacyOnDisconnect
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
        migratedToModeSchema = try container.decodeIfPresent(Bool.self, forKey: .migratedToModeSchema) ?? migratedToModeSchema
        triggerDelay = try container.decodeIfPresent(Int.self, forKey: .triggerDelay) ?? triggerDelay
        delayBetweenActions = try container.decodeIfPresent(Double.self, forKey: .delayBetweenActions) ?? delayBetweenActions
    }

    /// Convenience: returns the config for a given action kind in this
    /// profile's action list, if present.
    func action(for kind: TriggerActionKind) -> TriggerActionConfig? {
        return actions.first { $0.kind == kind }
    }

    /// True if the profile has any configured action.
    var hasAnyAction: Bool {
        return !actions.isEmpty
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
    /// mode (plug-in / plug-out), OBS configuration, and actions. Multiple
    /// can be active simultaneously.
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
            // Fresh install — seed a default "Displays" plug-in profile with
            // the historical default of "Refresh all browsers" enabled.
            var defaultProfile = TriggerProfile()
            defaultProfile.name = "Displays"
            defaultProfile.triggerType = .display
            defaultProfile.mode = .plugIn
            defaultProfile.actions = [
                TriggerActionConfig(kind: .refreshBrowsers, mode: .start)
            ]
            defaultProfile.migratedToModeSchema = true
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

    /// Expand any profiles that are still in a legacy shape into the new
    /// mode-based single-list schema. If a legacy profile has both "start"
    /// actions and "stop-on-unplug" actions, it gets cloned into two profiles:
    /// one plug-in (with the start actions) and one plug-out (with the stop
    /// actions). Must be called AFTER `migrateToProfilesIfNeeded()`.
    ///
    /// Migration rules (mirroring the spec):
    /// - An old profile with only start actions (no stop-on-unplug) →
    ///   1 new profile: `{ mode: .plugIn, actions: original start actions }`.
    /// - An old profile with stop-on-unplug flags set → 2 new profiles:
    ///     - `{ mode: .plugIn,  actions: original start actions, name suffix "(plug in)" }`
    ///     - `{ mode: .plugOut, actions: the stop actions,       name suffix "(plug out)" }`
    /// - Enabled-state rule: the plug-in clone inherits the original's
    ///   `isEnabled`. The plug-out clone is enabled iff the original was
    ///   enabled AND at least one stop-on-unplug flag was set.
    mutating func expandLegacyProfilesIfNeeded() {
        var expanded: [TriggerProfile] = []
        expanded.reserveCapacity(profiles.count)

        for profile in profiles {
            if profile.migratedToModeSchema {
                expanded.append(profile)
                continue
            }

            // If the profile already has a non-empty `actions` list but the
            // migration flag wasn't set, assume it's in the new shape and
            // just stamp the flag. No sibling synthesis.
            if !profile.actions.isEmpty {
                var stamped = profile
                stamped.migratedToModeSchema = true
                expanded.append(stamped)
                continue
            }

            // Gather the split — either from the intermediate onConnect/
            // onDisconnect arrays, or from the oldest per-action bool flags.
            let plugInActions: [TriggerActionConfig]
            let plugOutActions: [TriggerActionConfig]

            if !profile.legacyOnConnect.isEmpty || !profile.legacyOnDisconnect.isEmpty {
                plugInActions = profile.legacyOnConnect
                plugOutActions = profile.legacyOnDisconnect
            } else {
                var start: [TriggerActionConfig] = []
                if profile.startRecording    { start.append(.init(kind: .recording,    mode: .start)) }
                if profile.startStreaming    { start.append(.init(kind: .streaming,    mode: .start)) }
                if profile.startVirtualCam   { start.append(.init(kind: .virtualCam,   mode: .start)) }
                if profile.startReplayBuffer { start.append(.init(kind: .replayBuffer, mode: .start)) }
                if profile.refreshBrowsersOnTrigger {
                    start.append(.init(kind: .refreshBrowsers, mode: .start))
                }
                if profile.refreshOBSBrowserSourcesOnTrigger {
                    start.append(.init(kind: .refreshOBSBrowserSources, mode: .start))
                }

                var stop: [TriggerActionConfig] = []
                if profile.stopRecordingOnUnplug    { stop.append(.init(kind: .recording,    mode: .stop)) }
                if profile.stopStreamingOnUnplug    { stop.append(.init(kind: .streaming,    mode: .stop)) }
                if profile.stopVirtualCamOnUnplug   { stop.append(.init(kind: .virtualCam,   mode: .stop)) }
                if profile.stopReplayBufferOnUnplug { stop.append(.init(kind: .replayBuffer, mode: .stop)) }

                plugInActions = start
                plugOutActions = stop
            }

            let hasPlugOut = !plugOutActions.isEmpty
            let baseName = profile.name

            // Plug-in clone — always produced so the user still has an
            // editable profile after migration even if everything was empty.
            var plugIn = profile
            plugIn.id = UUID()
            plugIn.mode = .plugIn
            plugIn.actions = plugInActions
            plugIn.name = hasPlugOut ? "\(baseName) (plug in)" : baseName
            plugIn.isEnabled = profile.isEnabled
            plugIn.migratedToModeSchema = true
            AppConfig.clearLegacy(on: &plugIn)
            expanded.append(plugIn)

            if hasPlugOut {
                var plugOut = profile
                plugOut.id = UUID()
                plugOut.mode = .plugOut
                plugOut.actions = plugOutActions
                plugOut.name = "\(baseName) (plug out)"
                plugOut.isEnabled = profile.isEnabled && hasPlugOut
                plugOut.migratedToModeSchema = true
                AppConfig.clearLegacy(on: &plugOut)
                expanded.append(plugOut)
            }
        }

        profiles = expanded

        // Keep the selected tab pointing somewhere sane after expansion.
        if profiles.isEmpty {
            selectedProfileIndex = 0
        } else if selectedProfileIndex >= profiles.count {
            selectedProfileIndex = profiles.count - 1
        }
    }

    /// Wipes every legacy field on a profile after migration so the encoded
    /// JSON stops carrying the old per-action toggles around.
    private static func clearLegacy(on profile: inout TriggerProfile) {
        profile.legacyOnConnect = []
        profile.legacyOnDisconnect = []
        profile.startRecording = false
        profile.startStreaming = false
        profile.startVirtualCam = false
        profile.startReplayBuffer = false
        profile.stopRecordingOnUnplug = false
        profile.stopStreamingOnUnplug = false
        profile.stopVirtualCamOnUnplug = false
        profile.stopReplayBufferOnUnplug = false
        // Refresh toggles live in the actions list now; drop the bools so
        // we don't double up on re-save.
        profile.refreshBrowsersOnTrigger = false
        profile.refreshOBSBrowserSourcesOnTrigger = false
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
        config.expandLegacyProfilesIfNeeded()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    // MARK: - Profile helpers

    /// Returns all enabled profiles of the given trigger type (any mode).
    func enabledProfiles(ofType type: TriggerProfile.TriggerType) -> [TriggerProfile] {
        return config.profiles.filter { $0.isEnabled && $0.triggerType == type }
    }

    /// Returns all enabled profiles with a specific trigger type AND mode
    /// (plug-in / plug-out).
    func enabledProfiles(ofType type: TriggerProfile.TriggerType,
                         mode: ProfileTriggerMode) -> [TriggerProfile] {
        return config.profiles.filter {
            $0.isEnabled && $0.triggerType == type && $0.mode == mode
        }
    }

    /// Returns all enabled display-trigger profiles of the given mode whose
    /// threshold is met by the given external display count.
    func displayProfilesReadyToFire(externalDisplayCount: Int,
                                    mode: ProfileTriggerMode) -> [TriggerProfile] {
        return enabledProfiles(ofType: .display, mode: mode).filter {
            externalDisplayCount >= $0.requiredExternalDisplays
        }
    }

    /// Returns all enabled USB-trigger profiles of the given mode whose
    /// device name matches.
    func usbProfilesMatching(deviceName: String,
                             mode: ProfileTriggerMode) -> [TriggerProfile] {
        return enabledProfiles(ofType: .usbDevice, mode: mode).filter {
            !$0.usbDeviceName.isEmpty &&
            deviceName.localizedCaseInsensitiveContains($0.usbDeviceName)
        }
    }
}
