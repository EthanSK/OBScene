import Foundation
import AppKit
import ApplicationServices

// MARK: - SafeModeDialogDismisser
//
// Auto-dismisses the OBS Studio "Safe Mode" dialog that appears after an
// unclean shutdown (OBS thinks it crashed last run and asks the user to pick
// between Launch Normally / Launch in Safe Mode / Cancel). When OBScene
// auto-launches OBS on a trigger (e.g. when the user plugs in their displays),
// blocking on this modal would stall the trigger indefinitely — so we watch
// for it and click "Launch Normally" on the user's behalf.
//
// Implementation notes:
//
//   * OBS 32.x ships no CLI flag to suppress this dialog. `--safe-mode`
//     FORCES safe mode (opposite of what we want). `--help` confirmed no
//     `--disable-safe-mode` / `--normal-mode` / `--skip-safe-mode-dialog`
//     exists. AX-scripting the dialog is the only path.
//
//   * We can't rely on the dialog having a specific title — OBS uses a
//     generic `QMessageBox` whose window title is typically "OBS Studio"
//     (or empty) and whose SAFE-MODE-ness lives in the static-text body.
//     So we search by the TEXT CONTENT of the window's AX subtree and the
//     TEXT OF THE BUTTONS instead.
//
//   * Tests can inject a fake `DialogProbe` to avoid needing a real OBS
//     process or the macOS accessibility runtime in CI.
//
// Accessibility permission:
//
//   The first time this runs on a given Mac, the user MUST approve OBScene
//   in System Settings → Privacy & Security → Accessibility. We check
//   `AXIsProcessTrustedWithOptions` up front and post a UserNotifier if
//   we're not trusted; the watcher then silently no-ops so we don't spam
//   the activity log on every launch.

// MARK: - Abstracted AX model (testable)

/// A snapshot of one AXUIElement relevant to our decision. Kept minimal so
/// tests can construct mock trees with a handful of fields.
struct AXElementSnapshot {
    /// Role identifier (e.g. `AXButton`, `AXWindow`, `AXCheckBox`, `AXStaticText`).
    let role: String
    /// Human-readable role description, e.g. "button", "window".
    let roleDescription: String?
    /// `AXTitle` attribute — button label, window title, etc.
    let title: String?
    /// `AXDescription` attribute — used by some QMessageBox buttons.
    let description: String?
    /// `AXValue` attribute — for checkboxes, 1 = checked.
    let value: String?
    /// Children to recurse into.
    let children: [AXElementSnapshot]
}

/// Abstraction over "list the top-level windows of a running app and return
/// their AX trees". Real impl uses `AXUIElementCreateApplication`; test impl
/// returns a hard-coded tree.
protocol DialogProbe {
    /// Return every current top-level window of the target process as an
    /// `AXElementSnapshot`. Empty array means "no windows yet" (e.g. OBS
    /// still launching).
    func currentWindows() -> [AXElementSnapshot]

    /// Perform the AX press action on the element identified by `path` —
    /// a list of child indices from the window root down to the element.
    /// Real impl re-resolves the element via the same path and calls
    /// `AXUIElementPerformAction(el, kAXPressAction)`. Returns true on
    /// success.
    @discardableResult
    func press(path: [Int], in windowIndex: Int) -> Bool
}

// MARK: - Decision logic (pure, no AX framework)

/// What the dismisser should do given a snapshot of OBS's windows.
enum DialogDecision: Equatable {
    /// No safe-mode dialog visible — keep watching.
    case keepWatching
    /// Safe-mode dialog found at `windowIndex`. Press these element paths in
    /// order: first the "don't ask again" checkbox (if any), then the
    /// "Launch Normally" button.
    case dismiss(windowIndex: Int, paths: [[Int]])
    /// A window that matches "Safe Mode" text was found but we couldn't
    /// identify the launch-normally button. Log the AX tree so we can
    /// tune it later.
    case dumpUnknownTree(windowIndex: Int)
}

enum SafeModeDismissalLogic {
    /// Case-insensitive substring match on any `AXStaticText` / title /
    /// description in the subtree. Returns true if "safe mode" appears
    /// anywhere — that's how we recognise the dialog.
    static func containsSafeModeText(_ element: AXElementSnapshot) -> Bool {
        let haystack = [element.title, element.description, element.value]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("safe mode") { return true }
        for child in element.children {
            if containsSafeModeText(child) { return true }
        }
        return false
    }

    /// Walk a window subtree and collect the path (indices) to any element
    /// whose role matches one of `roles` AND (if `labelPredicate` is non-nil)
    /// whose title/description matches.
    static func findElement(
        in element: AXElementSnapshot,
        pathSoFar: [Int] = [],
        role: String,
        where labelPredicate: ((String) -> Bool)? = nil
    ) -> [Int]? {
        if element.role == role {
            if let pred = labelPredicate {
                // QMessageBox buttons sometimes expose the real label via
                // `AXDescription` while `AXTitle` is present-but-empty. Try
                // both AND the concatenation so an empty title doesn't
                // shadow a populated description.
                let title = (element.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let desc = (element.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let candidates: [String] = [title, desc, "\(title) \(desc)"]
                    .map { $0.lowercased() }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if candidates.contains(where: { pred($0) }) {
                    return pathSoFar
                }
            } else {
                return pathSoFar
            }
        }
        for (i, child) in element.children.enumerated() {
            if let hit = findElement(in: child, pathSoFar: pathSoFar + [i], role: role, where: labelPredicate) {
                return hit
            }
        }
        return nil
    }

    /// Predicate: does this button label look like "Launch Normally" in any
    /// of the plausible phrasings OBS might use across versions?
    static func looksLikeLaunchNormallyButton(_ label: String) -> Bool {
        let l = label.lowercased()
        // Order: most specific first. We avoid a bare "launch" match to
        // reduce the risk of pressing "Launch in Safe Mode" by mistake.
        if l.contains("launch normally") { return true }
        if l.contains("run normally") { return true }
        if l.contains("start normally") { return true }
        if l.contains("continue normally") { return true }
        if l == "continue" { return true } // some OBS builds use a plain "Continue" primary button
        return false
    }

    /// Predicate: does this button label look like "Launch in Safe Mode"?
    /// Used to DISQUALIFY windows, not to click — we never want to click
    /// this button.
    static func looksLikeSafeModeButton(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("safe mode") && (l.contains("launch") || l.contains("run") || l.contains("start"))
    }

    /// Predicate: "don't ask again" / "remember my choice" / similar.
    static func looksLikeRememberChoiceCheckbox(_ label: String) -> Bool {
        let l = label.lowercased()
        if l.contains("don't ask") { return true }
        if l.contains("do not ask") { return true }
        if l.contains("remember") && l.contains("choice") { return true }
        if l.contains("don't show") { return true }
        return false
    }

    /// Main decision function. Given the current list of OBS windows, decide
    /// what to do.
    static func decide(windows: [AXElementSnapshot]) -> DialogDecision {
        for (idx, window) in windows.enumerated() {
            guard containsSafeModeText(window) else { continue }

            // Must also contain a safe-mode-specific button OR explicit
            // "safe mode" in the static text — don't match a random OBS
            // window that happens to mention "mode".
            let launchNormallyPath = findElement(
                in: window, role: "AXButton",
                where: { label in
                    looksLikeLaunchNormallyButton(label)
                }
            )

            guard let btnPath = launchNormallyPath else {
                // Window smells right but we can't find the button — log so
                // we can tune the matcher.
                return .dumpUnknownTree(windowIndex: idx)
            }

            // Optional: find a "don't ask again" checkbox.
            let checkboxPath = findElement(
                in: window, role: "AXCheckBox",
                where: { label in looksLikeRememberChoiceCheckbox(label) }
            )

            var paths: [[Int]] = []
            if let cb = checkboxPath { paths.append(cb) }
            paths.append(btnPath)

            return .dismiss(windowIndex: idx, paths: paths)
        }
        return .keepWatching
    }

    /// Render an AX tree as indented lines. Used when we hit
    /// `.dumpUnknownTree` so the next debugging pass has something to go on.
    static func renderTree(_ element: AXElementSnapshot, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let title = element.title.map { " title=\($0.debugDescription)" } ?? ""
        let desc = element.description.map { " desc=\($0.debugDescription)" } ?? ""
        let value = element.value.map { " value=\($0.debugDescription)" } ?? ""
        var out = "\(pad)\(element.role)\(title)\(desc)\(value)\n"
        for child in element.children {
            out += renderTree(child, indent: indent + 1)
        }
        return out
    }
}

// MARK: - Engine (pure; wraps decision + probe together)

/// Single polling tick. Returns whether the watcher should keep polling.
enum SafeModeDismisserEngine {
    enum TickResult: Equatable {
        /// Dialog not visible yet — keep polling.
        case keepPolling
        /// Dismissed successfully.
        case dismissed
        /// Dialog present but selector didn't match any button — the watcher
        /// gives up to avoid pressing the wrong button. Tree was logged.
        case abandoned
    }

    static func tick(probe: DialogProbe, log: (String) -> Void) -> TickResult {
        let windows = probe.currentWindows()
        switch SafeModeDismissalLogic.decide(windows: windows) {
        case .keepWatching:
            return .keepPolling

        case .dumpUnknownTree(let idx):
            let win = windows[idx]
            log("SafeModeDialogDismisser: window matches 'Safe Mode' text but no launch-normally button found; dumping AX tree:")
            log(SafeModeDismissalLogic.renderTree(win))
            return .abandoned

        case .dismiss(let idx, let paths):
            log("SafeModeDialogDismisser: found OBS Safe Mode dialog at window \(idx); pressing \(paths.count) element(s)")
            for path in paths {
                let ok = probe.press(path: path, in: idx)
                log("SafeModeDialogDismisser: press path=\(path) -> \(ok ? "OK" : "FAILED")")
                if !ok {
                    return .abandoned
                }
            }
            return .dismissed
        }
    }
}

// MARK: - Real AX-backed probe

#if canImport(ApplicationServices)
/// Production probe that talks to the real macOS Accessibility API.
final class AXDialogProbe: DialogProbe {
    private let pid: pid_t
    private let appElement: AXUIElement

    /// Cached windows captured at the start of the last `currentWindows()`
    /// call, so `press(path:in:)` can walk the same tree without re-querying.
    private var lastWindows: [AXUIElement] = []

    init(pid: pid_t) {
        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
    }

    func currentWindows() -> [AXElementSnapshot] {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else {
            lastWindows = []
            return []
        }
        lastWindows = windows
        return windows.map { Self.snapshot(of: $0, maxDepth: 8) }
    }

    @discardableResult
    func press(path: [Int], in windowIndex: Int) -> Bool {
        guard windowIndex < lastWindows.count else { return false }
        var element = lastWindows[windowIndex]
        for idx in path {
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            guard err == .success, let children = value as? [AXUIElement], idx < children.count else {
                return false
            }
            element = children[idx]
        }

        // For checkboxes, only press if not already checked — avoids toggling
        // OFF a checkbox the user had manually checked.
        if Self.copyRole(element) == "AXCheckBox" {
            if let v = Self.copyValue(element), v == "1" || v == "true" {
                return true // already checked; nothing to do
            }
        }

        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return result == .success
    }

    // MARK: - Snapshot helpers

    static func snapshot(of element: AXUIElement, maxDepth: Int) -> AXElementSnapshot {
        let role = copyRole(element) ?? ""
        let roleDesc = copyStringAttr(element, kAXRoleDescriptionAttribute)
        let title = copyStringAttr(element, kAXTitleAttribute)
        let description = copyStringAttr(element, kAXDescriptionAttribute)
        let value = copyValue(element)

        var children: [AXElementSnapshot] = []
        if maxDepth > 0 {
            var childrenValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            if err == .success, let kids = childrenValue as? [AXUIElement] {
                children = kids.map { snapshot(of: $0, maxDepth: maxDepth - 1) }
            }
        }

        return AXElementSnapshot(
            role: role,
            roleDescription: roleDesc,
            title: title,
            description: description,
            value: value,
            children: children
        )
    }

    static func copyRole(_ el: AXUIElement) -> String? {
        return copyStringAttr(el, kAXRoleAttribute)
    }

    static func copyStringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    static func copyValue(_ el: AXUIElement) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
#endif

// MARK: - Public watcher

final class SafeModeDialogDismisser {
    static let shared = SafeModeDialogDismisser()

    /// Has UserNotifier already been posted this session for the "grant AX
    /// permission" nudge? We don't want to spam the user on every launch.
    private var accessibilityWarningPosted: Bool = false
    private let lock = NSLock()

    /// Active in-flight watcher token. We allow only one per session — if
    /// OBS is launched twice in quick succession, the second call is a no-op.
    private var activeToken: UUID?

    private init() {}

    /// Convenience: launch the watcher for `runningApp`. No-op if pid is
    /// invalid.
    func watchForDialog(runningApp: NSRunningApplication) {
        watchForDialog(pid: runningApp.processIdentifier)
    }

    /// Start a polling loop that watches OBS's windows for the safe-mode
    /// dialog. Polls every `pollInterval` for up to `timeout` seconds, then
    /// gives up.
    func watchForDialog(
        pid: pid_t,
        pollInterval: TimeInterval = 0.5,
        timeout: TimeInterval = 15.0
    ) {
        guard pid > 0 else { return }

        // Check Accessibility trust up front. AX queries on an untrusted
        // process silently return empty windows, so we'd poll uselessly.
        guard ensureAccessibilityTrusted() else {
            return
        }

        lock.lock()
        if activeToken != nil {
            lock.unlock()
            return // already watching
        }
        let token = UUID()
        activeToken = token
        lock.unlock()

        print("[OBScene] SafeModeDialogDismisser: starting watcher (pid=\(pid), timeout=\(timeout)s)")
        ActivityLog.shared.log(.info, "Watching for OBS Safe Mode dialog")

        let probe = AXDialogProbe(pid: pid)
        let deadline = Date().addingTimeInterval(timeout)
        schedulePoll(
            probe: probe,
            pid: pid,
            token: token,
            pollInterval: pollInterval,
            deadline: deadline
        )
    }

    // MARK: - Polling

    private func schedulePoll(
        probe: DialogProbe,
        pid: pid_t,
        token: UUID,
        pollInterval: TimeInterval,
        deadline: Date
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let stillActive = (self.activeToken == token)
            self.lock.unlock()
            guard stillActive else { return }

            // Stop if the target process died.
            if NSRunningApplication(processIdentifier: pid) == nil {
                self.finish(token: token, message: "OBS process exited before dialog appeared")
                return
            }

            let log: (String) -> Void = { msg in
                print("[OBScene] \(msg)")
                ActivityLog.shared.log(.info, msg)
            }
            let result = SafeModeDismisserEngine.tick(probe: probe, log: log)

            switch result {
            case .keepPolling:
                if Date() >= deadline {
                    self.finish(token: token, message: "Safe Mode dialog did not appear within \(Int(deadline.timeIntervalSinceNow + 15))s — stopping watcher")
                } else {
                    self.schedulePoll(
                        probe: probe, pid: pid, token: token,
                        pollInterval: pollInterval, deadline: deadline
                    )
                }

            case .dismissed:
                self.finish(token: token, message: "OBS Safe Mode dialog dismissed")

            case .abandoned:
                self.finish(token: token, message: "Gave up on Safe Mode dialog — tree logged above")
            }
        }
    }

    private func finish(token: UUID, message: String) {
        lock.lock()
        if activeToken == token { activeToken = nil }
        lock.unlock()
        print("[OBScene] SafeModeDialogDismisser: \(message)")
        ActivityLog.shared.log(.info, message)
    }

    // MARK: - Accessibility trust

    /// Returns true iff OBScene currently holds AX permissions. If not,
    /// posts a one-time user notification pointing to System Settings. We
    /// deliberately DO NOT pass the prompt option (`kAXTrustedCheckOptionPrompt`)
    /// — we want the notification (which the user can click through at their
    /// own pace) rather than a dialog that steals focus.
    private func ensureAccessibilityTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted { return true }

        lock.lock()
        let alreadyPosted = accessibilityWarningPosted
        accessibilityWarningPosted = true
        lock.unlock()

        if !alreadyPosted {
            ActivityLog.shared.log(.info, "Accessibility permission required to auto-dismiss OBS Safe Mode dialog")
            UserNotifier.post(
                title: "Accessibility permission needed",
                body: "OBScene needs Accessibility permission to auto-dismiss OBS's Safe Mode dialog. Enable it in System Settings → Privacy & Security → Accessibility."
            )
        }
        return false
    }
}
