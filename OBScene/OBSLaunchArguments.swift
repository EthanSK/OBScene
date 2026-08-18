import Foundation

/// Builds the native OBS startup arguments used by both cold launches and controlled restarts.
enum OBSLaunchArguments {
    static func make(
        selectedProfile: String,
        selectedSceneCollection: String,
        selectedScene: String
    ) -> [String] {
        var arguments: [String] = []

        if !selectedProfile.isEmpty {
            arguments.append(contentsOf: ["--profile", selectedProfile])
        }
        if !selectedSceneCollection.isEmpty {
            arguments.append(contentsOf: ["--collection", selectedSceneCollection])
        }
        if !selectedScene.isEmpty {
            arguments.append(contentsOf: ["--scene", selectedScene])
        }

        return arguments
    }
}
