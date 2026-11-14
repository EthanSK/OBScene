import AppKit

enum OBSApplicationResolver {
    /// OBS++ is preferred for cold launches, while the official bundle remains a rollback option. A restart always reopens the app that is already running so installing OBS++ cannot silently switch a live official OBS session. (Codex task: 01a01b14-9ef1-7082-99e7-1885d5d90235)
    static let bundleIdentifiers = ["com.ethansk.obs-plus-plus", "com.obsproject.obs-studio"]

    static func isOBSBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }

    static func runningApplications() -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications.filter {
            isOBSBundleIdentifier($0.bundleIdentifier)
        }
    }

    static func runningApplication() -> NSRunningApplication? {
        let applications = runningApplications()
        for bundleIdentifier in bundleIdentifiers {
            if let application = applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                return application
            }
        }
        return nil
    }

    static func applicationURL() -> URL? {
        if let runningBundleURL = runningApplication()?.bundleURL {
            return runningBundleURL
        }
        for bundleIdentifier in bundleIdentifiers {
            if let installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return installedURL
            }
        }
        return nil
    }
}
