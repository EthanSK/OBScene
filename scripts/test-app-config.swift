import Foundation

@main
struct AppConfigTests {
    static func main() throws {
        let decoder = JSONDecoder()

        let legacy = try decoder.decode(AppConfig.self, from: Data("{}".utf8))
        guard !legacy.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("missing recovery toggle must default to disabled")
        }
        guard !legacy.restoreMissingCustomBrowserDocksAfterProfileChanges else {
            fatalError("missing dock-restoration toggle must default to disabled")
        }

        let enabledJSON = """
        {"automaticallyRecoverOBSAfterWakeAndDisplayChanges":true}
        """
        let enabled = try decoder.decode(
            AppConfig.self,
            from: Data(enabledJSON.utf8)
        )
        guard enabled.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("explicitly enabled recovery toggle was not decoded")
        }

        let encoded = try JSONEncoder().encode(enabled)
        let roundTrip = try decoder.decode(AppConfig.self, from: encoded)
        guard roundTrip.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("enabled recovery toggle did not persist")
        }

        let dockEnabledJSON = """
        {"restoreMissingCustomBrowserDocksAfterProfileChanges":true}
        """
        let dockEnabled = try decoder.decode(
            AppConfig.self,
            from: Data(dockEnabledJSON.utf8)
        )
        guard dockEnabled.restoreMissingCustomBrowserDocksAfterProfileChanges else {
            fatalError("explicitly enabled dock-restoration toggle was not decoded")
        }

        let dockEncoded = try JSONEncoder().encode(dockEnabled)
        let dockRoundTrip = try decoder.decode(AppConfig.self, from: dockEncoded)
        guard dockRoundTrip.restoreMissingCustomBrowserDocksAfterProfileChanges else {
            fatalError("enabled dock-restoration toggle did not persist")
        }

        print("AppConfig tests passed (6 tests)")
    }
}
