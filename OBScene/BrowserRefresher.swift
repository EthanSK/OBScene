import Foundation
import AppKit

/// Refreshes all open tabs across common browsers using AppleScript.
///
/// Only targets browsers that are currently running — never launches a browser
/// that isn't already open. Each browser is refreshed independently so a failure
/// in one doesn't block the others.
enum BrowserRefresher {

    /// Delay (in seconds) after the display trigger fires before refreshing
    /// browsers. Gives browsers a moment to detect the new display config so
    /// the refresh fixes the post-plug-in glitch rather than racing it.
    static let postTriggerDelay: TimeInterval = 3.0

    /// Refresh all tabs in every running browser.
    static func refreshAllBrowsers() {
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = Set(running.compactMap { $0.bundleIdentifier })

        let browsers: [(bundleID: String, name: String, script: String)] = [
            (
                "com.google.Chrome",
                "Google Chrome",
                """
                tell application "Google Chrome"
                    repeat with w in windows
                        repeat with t in tabs of w
                            reload t
                        end repeat
                    end repeat
                end tell
                """
            ),
            (
                "com.apple.Safari",
                "Safari",
                """
                tell application "Safari"
                    repeat with d in documents
                        set URL of d to URL of d
                    end repeat
                end tell
                """
            ),
            (
                "company.thebrowser.Browser",
                "Arc",
                """
                tell application "Arc"
                    repeat with w in windows
                        repeat with t in tabs of w
                            reload t
                        end repeat
                    end repeat
                end tell
                """
            ),
            (
                "org.mozilla.firefox",
                "Firefox",
                """
                tell application "Firefox" to activate
                delay 0.3
                tell application "System Events"
                    keystroke "r" using command down
                end tell
                """
            ),
        ]

        for browser in browsers {
            guard runningIDs.contains(browser.bundleID) else { continue }

            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: browser.script)
                var errorInfo: NSDictionary?
                appleScript?.executeAndReturnError(&errorInfo)

                if let error = errorInfo {
                    print("[OBScene] Failed to refresh \(browser.name): \(error)")
                    DispatchQueue.main.async {
                        ActivityLog.shared.log(.info, "Failed to refresh \(browser.name)")
                    }
                } else {
                    print("[OBScene] Refreshed \(browser.name)")
                    DispatchQueue.main.async {
                        ActivityLog.shared.log(.info, "Refreshed \(browser.name) tabs")
                    }
                }
            }
        }
    }
}
