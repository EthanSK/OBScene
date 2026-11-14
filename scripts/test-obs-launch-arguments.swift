import Foundation

var failures: [String] = []

func expectEqual(_ actual: [String], _ expected: [String], _ name: String) {
    if actual != expected {
        failures.append("\(name): expected \(expected), got \(actual)")
    }
}

@main
struct TestRunner {
    static func main() {
        expectEqual(
            OBSLaunchArguments.make(
                selectedProfile: "",
                selectedSceneCollection: "",
                selectedScene: ""
            ),
            [],
            "empty selections"
        )

        expectEqual(
            OBSLaunchArguments.make(
                selectedProfile: "3000AD Music",
                selectedSceneCollection: "3000ad v3 new",
                selectedScene: "Scene"
            ),
            ["--profile", "3000AD Music", "--collection", "3000ad v3 new", "--scene", "Scene"],
            "all selections"
        )

        expectEqual(
            OBSLaunchArguments.make(
                selectedProfile: "coffee shop coding",
                selectedSceneCollection: "",
                selectedScene: ""
            ),
            ["--profile", "coffee shop coding"],
            "profile only"
        )

        if failures.isEmpty {
            print("All 3 OBS launch-argument tests passed.")
            exit(0)
        }

        for failure in failures {
            print("FAIL: \(failure)")
        }
        exit(1)
    }
}
