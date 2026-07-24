import Foundation

@main
struct AppConfigTests {
    static func main() throws {
        let decoder = JSONDecoder()

        let legacy = try decoder.decode(AppConfig.self, from: Data("{}".utf8))
        guard legacy.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("missing recovery toggle must default to enabled")
        }

        let disabledJSON = """
        {"automaticallyRecoverOBSAfterWakeAndDisplayChanges":false}
        """
        let disabled = try decoder.decode(
            AppConfig.self,
            from: Data(disabledJSON.utf8)
        )
        guard !disabled.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("explicitly disabled recovery toggle was not decoded")
        }

        let encoded = try JSONEncoder().encode(disabled)
        let roundTrip = try decoder.decode(AppConfig.self, from: encoded)
        guard !roundTrip.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("disabled recovery toggle did not persist")
        }

        print("AppConfig tests passed (3 tests)")
    }
}
