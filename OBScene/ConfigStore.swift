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
    var triggerDelay: Int = 15
    var requiredExternalDisplays: Int = 2
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
