import Foundation
import Combine

struct AppConfig: Codable, Equatable {
    var obsHost: String = "localhost"
    var obsPort: Int = 4455
    var obsPassword: String = ""
    var selectedSceneCollection: String = ""
    var selectedProfile: String = ""
    var selectedScene: String = ""
    var startRecording: Bool = false
    var startStreaming: Bool = false
    var stopRecordingOnUnplug: Bool = false
    var stopStreamingOnUnplug: Bool = false
    var triggerDelay: Int = 15
    var requiredExternalDisplays: Int = 2
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
        stopRecordingOnUnplug = try container.decodeIfPresent(Bool.self, forKey: .stopRecordingOnUnplug) ?? stopRecordingOnUnplug
        stopStreamingOnUnplug = try container.decodeIfPresent(Bool.self, forKey: .stopStreamingOnUnplug) ?? stopStreamingOnUnplug
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
