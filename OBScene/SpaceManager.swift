//
// SpaceManager.swift — restore the macOS Space (Mission Control workspace)
// the OBS window was on before a restart.
//
// macOS has NO public API for reading / moving Spaces. yabai, Hammerspoon,
// Rectangle, and a long line of window managers all bind against the same
// undocumented SkyLight (formerly CoreGraphics Services) symbols. The
// signatures used here have been stable for ~10 OS versions (Mavericks
// onwards) but Apple could in principle break them on any major release,
// which is why every entry point on `SpaceManager` returns optionals /
// throwing variants and the caller is expected to log + skip silently
// when the SPI returns junk.
//
// We deliberately resolve the symbols dynamically at first use via dlsym
// against /System/Library/PrivateFrameworks/SkyLight.framework rather than
// linking against SkyLight at build time:
//   - keeps the Xcode/swiftc build invocation portable (no extra
//     `-framework SkyLight` argument required to compile);
//   - avoids a hard launch-time abort on a future macOS that ships a
//     SkyLight without one of these symbols — the dlsym() lookup will
//     simply return nil and the feature degrades to a no-op;
//   - matches the pattern Hammerspoon and yabai both use, which makes
//     drift-fixes reproducible on this codebase if a symbol disappears.
//
// All public methods return `nil` / throw rather than crashing if the SPI
// is unavailable. The caller (OBSAppController.restartOBS) is expected to
// log the error and continue — the rest of the restart flow is independent
// of the Space restore.
//
// See `OBSAppController` for the integration: pre-terminate we capture the
// active space ID + the OBS main window ID; post-relaunch (after the
// WebSocket reports ready) we poll for OBS's new windows and call
// `moveWindow(_:toSpace:)` so the user lands back on the Space they were
// on before the restart kicked them around.
//
// **macOS 14.5+ regression (2024) and the CompatID workaround.**
// Apple changed Mission Control internals in macOS Sonoma 14.5 such that
// the historical window-to-space SPI no longer reliably moves windows. On
// macOS 14.5+ we use the same workaround as yabai and Hammerspoon:
//   1. tag the target Space with a temporary compat workspace ID,
//   2. assign the window list to that workspace,
//   3. clear the temporary compat ID from the Space.
// On older macOS releases we keep the legacy `CGSMoveWindowsToManagedSpace`
// path.

import Foundation
import AppKit
import CoreGraphics

/// Wrapper around the private SkyLight Space-management SPI. All methods are
/// safe to call when SkyLight isn't available (the feature degrades to a
/// no-op and emits an ActivityLog warning the first time a symbol fails to
/// resolve). Designed for one-shot use from the OBS restart path; nothing
/// is cached between restarts so a private-API breakage that arrives via a
/// macOS update won't pin us to a stale state for the rest of the session.
enum SpaceManager {

    // MARK: - Symbol resolution

    /// Path on disk where SkyLight's Mach-O lives on every macOS version we
    /// care about (13+). Older OSes (10.10–10.12) used `CoreGraphicsServices`
    /// / `WindowServer` paths but we don't support those.
    private static let skyLightPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"

    /// Lazily-opened SkyLight handle. `nil` if dlopen fails (e.g. SIP
    /// removed the framework, or some future macOS reorganises the bundle
    /// path). All symbol lookups gate on this; if it never opens, every
    /// public method on `SpaceManager` is a no-op.
    private static let skyLightHandle: UnsafeMutableRawPointer? = {
        let handle = dlopen(skyLightPath, RTLD_LAZY)
        if handle == nil {
            // Don't ActivityLog from a static initialiser — log on first use
            // instead so the unavailable case is observable in the activity
            // tab when the user actually exercises the feature.
        }
        return handle
    }()

    /// Single-shot warning latch. When `true`, we've already logged the
    /// "SkyLight unavailable, skipping space restore" message for this
    /// session and don't repeat it on every restart.
    private static var hasLoggedUnavailable = false

    /// Lookup helper. Resolves `name` against the cached SkyLight handle
    /// and reinterprets the result as `T`. Returns `nil` if `dlopen`
    /// failed earlier or `dlsym` returns NULL.
    private static func lookup<T>(_ name: String, as: T.Type) -> T? {
        guard let handle = skyLightHandle else { return nil }
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static func lookupAny<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let symbol = lookup(name, as: type) {
                return symbol
            }
        }
        return nil
    }

    // MARK: - Resolved SkyLight symbol bundle
    //
    // Resolved once upfront (lazy, on first access) rather than per-call.
    // This lets the public entry points fail fast — `nil` here means the
    // feature is unavailable on this macOS. Common read symbols are required;
    // branch-specific move symbols are optional and checked immediately before
    // use so older macOS releases do not require the newer compat symbols.
    //
    // Signatures sanity-checked against yabai (src/misc/extern.h) and
    // Hammerspoon (extensions/spaces/libspaces.m):
    //   - CGSMainConnectionID()                                -> int
    //   - CGSGetActiveSpace(cid)                               -> uint64_t
    //   - CGSCopySpacesForWindows(cid, mask, wids)             -> CFArrayRef (Copy = retained)
    //   - CGSMoveWindowsToManagedSpace(cid, wids, sid)         -> void
    //   - SLSSpaceSetCompatID(cid, sid, workspace)             -> CGError (Int32)
    //   - SLSSetWindowListWorkspace(cid, uint32_t*, count, ws) -> CGError (Int32)
    private struct ResolvedSymbols {
        let mainConnectionID: @convention(c) () -> Int32
        let getActiveSpace: @convention(c) (Int32) -> UInt64
        // Copy* returns a retained CFArray; we declare the binding as
        // `Unmanaged<CFArray>?` so a NULL return from the private API
        // doesn't crash on the unwrapped cast (which is what the original
        // non-optional `CFArray` declaration risked).
        let copySpacesForWindows: @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        let moveWindowsToManagedSpace: (@convention(c) (Int32, CFArray, UInt64) -> Void)?
        let spaceSetCompatID: (@convention(c) (Int32, UInt64, Int32) -> Int32)?
        let setWindowListWorkspace: (@convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32)?
    }

    /// Single resolution attempt at process start. `nil` means the common
    /// read-side feature is unavailable on this OS (one or more required
    /// symbols missing, or SkyLight itself didn't dlopen). Move-only symbols
    /// are checked in the relevant version branch before any mutation.
    private static let resolvedSymbols: ResolvedSymbols? = {
        guard skyLightHandle != nil else { return nil }
        guard
            let mainConnectionID: @convention(c) () -> Int32 =
                lookupAny(["CGSMainConnectionID", "SLSMainConnectionID"],
                          as: (@convention(c) () -> Int32).self),
            let getActiveSpace: @convention(c) (Int32) -> UInt64 =
                lookupAny(["CGSGetActiveSpace", "SLSGetActiveSpace"],
                          as: (@convention(c) (Int32) -> UInt64).self),
            let copySpacesForWindows: @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>? =
                lookupAny(["CGSCopySpacesForWindows", "SLSCopySpacesForWindows"],
                          as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        else {
            return nil
        }
        let moveWindowsToManagedSpace: (@convention(c) (Int32, CFArray, UInt64) -> Void)? =
            lookupAny(["CGSMoveWindowsToManagedSpace", "SLSMoveWindowsToManagedSpace"],
                      as: (@convention(c) (Int32, CFArray, UInt64) -> Void).self)
        let spaceSetCompatID: (@convention(c) (Int32, UInt64, Int32) -> Int32)? =
            lookup("SLSSpaceSetCompatID",
                   as: (@convention(c) (Int32, UInt64, Int32) -> Int32).self)
        let setWindowListWorkspace:
            (@convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32)? =
            lookup("SLSSetWindowListWorkspace",
                   as: (@convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32).self)
        return ResolvedSymbols(
            mainConnectionID: mainConnectionID,
            getActiveSpace: getActiveSpace,
            copySpacesForWindows: copySpacesForWindows,
            moveWindowsToManagedSpace: moveWindowsToManagedSpace,
            spaceSetCompatID: spaceSetCompatID,
            setWindowListWorkspace: setWindowListWorkspace
        )
    }()

    private static let compatWorkspaceID: Int32 = 0x79616265

    /// True on macOS Sonoma 14.5 and later, where Apple changed Mission
    /// Control internals enough that the legacy move SPI can silently no-op.
    private static let needsCompatIDWorkaround: Bool = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion > 14 { return true }
        if v.majorVersion == 14 && v.minorVersion >= 5 { return true }
        return false
    }()

    // MARK: - Public API

    /// Returns the SkyLight Space ID that's currently active on the main
    /// display, or `nil` if the SPI is unavailable / returns 0. Logs to the
    /// activity tab on first failure so the user can see the feature
    /// degraded.
    static func currentSpaceID() -> UInt64? {
        guard let symbols = resolvedSymbols, let connection = currentConnection() else {
            logUnavailableOnce()
            return nil
        }
        let spaceID = symbols.getActiveSpace(connection)
        // `0` is SkyLight's "no space" sentinel — surface it as nil so the
        // caller doesn't try to move a window onto Space ID 0.
        return spaceID == 0 ? nil : spaceID
    }

    /// Look up the likely main window owned by the process with PID `pid`,
    /// returning its CGWindowID. Returns `nil` if the process has no
    /// matching window.
    ///
    /// Z-order: `CGWindowListCopyWindowInfo` returns windows ordered
    /// front-to-back, but OBS can briefly show splash/plugin/preferences
    /// windows above the main window. We therefore choose the largest normal
    /// layer-0 window owned by OBS instead of blindly taking the frontmost
    /// candidate.
    ///
    /// `includeOffscreen`:
    ///   - `false` (default): only consider on-screen windows. Used
    ///     post-relaunch when we're polling for OBS's freshly-spawned
    ///     window to come up — we want a window the user can see.
    ///   - `true`: include windows on other Spaces. Used pre-terminate
    ///     when OBS is on a Space the user isn't currently viewing —
    ///     `optionOnScreenOnly` would skip it because off-Space windows
    ///     report as not-on-screen, and we'd silently fail to capture
    ///     the OBS window's Space membership in exactly the workflow
    ///     this feature was built for. Uses
    ///     a list without `optionOnScreenOnly` instead.
    static func mainWindowID(forPID pid: pid_t, includeOffscreen: Bool = false) -> CGWindowID? {
        let opts: CGWindowListOption = includeOffscreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: (wid: CGWindowID, area: CGFloat)?
        for entry in info {
            guard
                let ownerPID = int32Value(entry[kCGWindowOwnerPID as String]),
                ownerPID == pid,
                let layerNumber = intValue(entry[kCGWindowLayer as String]),
                layerNumber == 0  // Layer 0 = normal application window.
            else { continue }

            // Filter out tiny chrome/hidden windows that occasionally appear
            // for OBS's IPC / WebSocket internals.
            guard
                let wid = uint32Value(entry[kCGWindowNumber as String]),
                let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                let width = cgFloatValue(bounds["Width"]),
                let height = cgFloatValue(bounds["Height"]),
                width >= 200,
                height >= 120
            else {
                continue
            }

            let area = width * height
            if best == nil || area > best!.area {
                best = (wid, area)
            }
        }
        return best?.wid
    }

    /// Returns the Space ID the OBS main window is currently on, OR
    /// `nil` if the window is assigned to multiple Spaces ("All
    /// Desktops" / sticky in macOS terminology) — in that case the
    /// caller should SKIP the restore step entirely. Collapsing a
    /// multi-Space window onto a single Space would change the user's
    /// intentional pinning and is the wrong default behaviour.
    ///
    /// `nil` is also returned when:
    ///   - SkyLight is unavailable (logged once per session)
    ///   - The OBS process has no resolvable main window
    ///   - The Space membership query came back empty
    ///
    /// This is the function the OBS restart flow should call BEFORE
    /// `runningApp.terminate()`. Once OBS exits, the window is gone and
    /// we can no longer query its Space membership — so the call has to
    /// happen up front.
    static func spaceForOBSWindow(pid: pid_t) -> UInt64? {
        guard let connection = currentConnection() else {
            logUnavailableOnce()
            return nil
        }
        // We deliberately include off-screen windows here: OBS may be on
        // a different Space than the user is currently viewing, in which
        // case CGWindowList reports it as "not on screen". An on-screen-
        // only filter would skip the OBS window in exactly the multi-
        // Space workflow this feature is built for.
        guard let wid = mainWindowID(forPID: pid, includeOffscreen: true) else {
            return nil
        }
        guard let rawMemberships = spacesForWindow(wid, connection: connection) else {
            ActivityLog.shared.log(.info,
                "SkyLight returned no Space membership list for OBS window \(wid) before terminate")
            return nil
        }
        // Filter out the SkyLight "no space" sentinel (0) and de-duplicate
        // before counting; the ActivityLog line reports this normalized list
        // so it is not mistaken for raw SkyLight output.
        let memberships = normalizedSpaces(rawMemberships)
        ActivityLog.shared.log(.info,
            "OBS window \(wid) normalized Space membership before terminate: \(formatSpaceList(memberships))")
        guard memberships.count == 1 else {
            // Either zero Spaces (window is a hidden helper / SPI failure)
            // or sticky/multi-Space — both are non-restorable. The normalized
            // membership list above makes the empty case visible; the
            // multi-space case gets an extra explanation because it can be an
            // intentional "All Desktops" assignment.
            if memberships.count > 1 {
                ActivityLog.shared.log(.info,
                    "OBS window is on \(memberships.count) Spaces (sticky / all-desktops) — Space restore skipped to preserve assignment")
            }
            return nil
        }
        return memberships[0]
    }

    /// Wait up to `timeout` seconds for the process with `pid` to acquire at
    /// least one on-screen window, then call `completion(windowID)` on the
    /// main queue. If no window appears, `completion(nil)` fires after the
    /// timeout. Polls every 250ms.
    ///
    /// Used by the OBS restart flow because OBS's main window doesn't appear
    /// the instant `NSWorkspace.openApplication` returns — there's a gap
    /// between launch and CGWindowList becoming aware of the new window. By
    /// the time the WebSocket reports ready the window IS usually up, but we
    /// still poll to absorb the small jitter.
    static func waitForWindow(pid: pid_t,
                              timeout: TimeInterval,
                              completion: @escaping (CGWindowID?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            // Include off-screen windows: post-relaunch OBS can be assigned
            // by macOS to a Space other than the user's current one (e.g.
            // its prior Space), and an on-screen-only query would never see
            // it — we'd time out without finding the very window we're
            // about to move. The whole point of this feature is to relocate
            // a window that's NOT on the user's current Space.
            if let wid = mainWindowID(forPID: pid, includeOffscreen: true) {
                DispatchQueue.main.async { completion(wid) }
                return
            }
            if Date() >= deadline {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
        }
        tick()
    }

    /// Move `windowID` onto the Space identified by `spaceID`. No-op if the
    /// SPI is unavailable. Throws `SpaceMoveError` on any failure path so the
    /// caller can log the specific reason.
    ///
    /// Implementation note: SkyLight has two usable move paths here. On
    /// macOS 14.5+ we use the SLS compat-ID dance from yabai/Hammerspoon; on
    /// older releases we use the legacy managed-space move. Both paths are
    /// followed by a fresh `CGSCopySpacesForWindows` query so a silent no-op
    /// is reported as failure instead of a misleading success log.
    static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: UInt64) throws {
        guard let symbols = resolvedSymbols else {
            throw SpaceMoveError.skyLightUnavailable
        }
        guard let connection = currentConnection() else {
            throw SpaceMoveError.skyLightUnavailable
        }
        guard spaceID != 0 else {
            throw SpaceMoveError.unexpectedEmptyResponse("target Space ID was 0")
        }

        guard let rawCurrentSpaces = spacesForWindow(windowID, connection: connection) else {
            throw SpaceMoveError.unexpectedEmptyResponse(
                "spacesForWindow(\(windowID)) returned nil before move")
        }
        let currentSpaces = normalizedSpaces(rawCurrentSpaces)
        if currentSpaces.count == 1 && currentSpaces[0] == spaceID {
            return
        }

        if needsCompatIDWorkaround {
            try moveWindowWithCompatID(windowID,
                                       toSpace: spaceID,
                                       connection: connection,
                                       symbols: symbols)
        } else {
            guard let moveWindowsToManagedSpace = symbols.moveWindowsToManagedSpace else {
                throw SpaceMoveError.symbolMissing("CGSMoveWindowsToManagedSpace")
            }
            let windows = [NSNumber(value: UInt32(windowID))] as CFArray
            moveWindowsToManagedSpace(connection, windows, spaceID)
        }

        guard let rawVerifiedSpaces = spacesForWindow(windowID, connection: connection) else {
            throw SpaceMoveError.unexpectedEmptyResponse(
                "spacesForWindow(\(windowID)) returned nil after move")
        }
        let verifiedSpaces = normalizedSpaces(rawVerifiedSpaces)
        guard verifiedSpaces.count == 1 && verifiedSpaces[0] == spaceID else {
            throw SpaceMoveError.moveVerificationFailed(
                "window \(windowID) is on \(formatSpaceList(verifiedSpaces)) after requested move to \(spaceID)")
        }
    }

    /// Convenience: move OBS's main window back to the captured Space. Does
    /// the full flow (resolve current windows for `pid`, wait briefly if not
    /// yet present, then call `moveWindow`). Logs each step + outcome to
    /// ActivityLog so the user can see what happened.
    ///
    /// `windowWaitTimeout` is the cap on how long we'll wait for OBS's
    /// window to show up after relaunch. After that we give up silently.
    ///
    /// `completion` (Fix #4) fires exactly once on the main queue when the
    /// restore terminates — whether it succeeded, failed, or timed out
    /// waiting for the window to show. The OBS restart flow gates its
    /// `restartInFlight` latch on this so a follow-up restart can't fire
    /// while the previous Space move is still pending.
    static func restoreOBSWindow(pid: pid_t,
                                 toSpace spaceID: UInt64,
                                 profileName: String,
                                 windowWaitTimeout: TimeInterval,
                                 completion: (() -> Void)? = nil) {
        ActivityLog.shared.log(.info,
            "Polling for OBS window to restore Space \(spaceID) (\(profileName))")
        waitForWindow(pid: pid, timeout: windowWaitTimeout) { windowID in
            defer {
                if let completion = completion {
                    DispatchQueue.main.async(execute: completion)
                }
            }
            guard let windowID = windowID else {
                ActivityLog.shared.log(.info,
                    "OBS window did not appear within \(Int(windowWaitTimeout))s — skipping Space restore (\(profileName))")
                return
            }
            do {
                try moveWindow(windowID, toSpace: spaceID)
                ActivityLog.shared.log(.info,
                    "Moved OBS window \(windowID) to Space \(spaceID) (\(profileName))")
            } catch {
                ActivityLog.shared.log(.info,
                    "Space restore failed (\(error)) — leaving OBS on the current Space (\(profileName))")
            }
        }
    }

    // MARK: - Errors

    enum SpaceMoveError: Error, CustomStringConvertible {
        /// dlopen of SkyLight returned NULL or the connection symbol is missing.
        case skyLightUnavailable
        /// A specific symbol couldn't be resolved (carries the symbol name).
        case symbolMissing(String)
        /// SkyLight returned an empty result for an operation that should
        /// always have produced one (e.g. spacesForWindow on a valid wid).
        case unexpectedEmptyResponse(String)
        /// WindowServer (via SkyLight) rejected a compat-ID call with a
        /// nonzero CGError. Carries the operation name + raw error code so
        /// the failure shows up in ActivityLog with enough context to
        /// debug.
        case windowServerError(op: String, code: Int32)
        /// A move call returned, but a fresh space-membership query did not
        /// show the window assigned exactly to the requested Space.
        case moveVerificationFailed(String)

        var description: String {
            switch self {
            case .skyLightUnavailable:
                return "SkyLight private framework unavailable"
            case .symbolMissing(let name):
                return "SkyLight symbol missing: \(name)"
            case .unexpectedEmptyResponse(let detail):
                return "SkyLight returned empty: \(detail)"
            case .windowServerError(let op, let code):
                return "SkyLight \(op) failed with CGError=\(code)"
            case .moveVerificationFailed(let detail):
                return "SkyLight move verification failed: \(detail)"
            }
        }
    }

    // MARK: - Private helpers

    /// Look up the running app's SkyLight connection ID. Cached lazily — the
    /// connection persists for the lifetime of the process so we never need
    /// to re-resolve it. Returns `nil` if the main-connection symbol is
    /// missing from this macOS's SkyLight (extremely unlikely but possible
    /// on a broken system).
    private static func currentConnection() -> Int32? {
        guard let symbols = resolvedSymbols else { return nil }
        let cid = symbols.mainConnectionID()
        // 0 is SkyLight's "no connection" sentinel — same as currentSpaceID().
        return cid == 0 ? nil : cid
    }

    /// Return the array of Space IDs the given window is currently a member
    /// of. SkyLight masks: `0x7` = "all spaces this window is on across all
    /// users / displays" (the value yabai/Hammerspoon both use).
    ///
    /// Fix #3: `CGSCopySpacesForWindows` is declared returning
    /// `Unmanaged<CFArray>?` so a NULL return from the private API doesn't
    /// crash an unwrapped non-optional `CFArray` cast. We explicitly
    /// `takeRetainedValue()` to consume the +1 retain count from the Copy*
    /// API (Cocoa's "Create Rule"), then validate the bridged Swift type
    /// before mapping.
    private static func spacesForWindow(_ wid: CGWindowID, connection: Int32) -> [UInt64]? {
        guard let symbols = resolvedSymbols else { return nil }
        let widsArray = [NSNumber(value: UInt32(wid))] as CFArray
        // 0x7 = all spaces (any of: visible, current user, any display)
        guard let unmanaged = symbols.copySpacesForWindows(connection, 0x7, widsArray) else {
            return nil
        }
        let result = unmanaged.takeRetainedValue()
        let array = result as NSArray
        var spaces: [UInt64] = []
        for value in array {
            guard let number = value as? NSNumber else { return nil }
            spaces.append(number.uint64Value)
        }
        return spaces
    }

    private static func moveWindowWithCompatID(_ windowID: CGWindowID,
                                               toSpace spaceID: UInt64,
                                               connection: Int32,
                                               symbols: ResolvedSymbols) throws {
        guard let spaceSetCompatID = symbols.spaceSetCompatID else {
            throw SpaceMoveError.symbolMissing("SLSSpaceSetCompatID")
        }
        guard let setWindowListWorkspace = symbols.setWindowListWorkspace else {
            throw SpaceMoveError.symbolMissing("SLSSetWindowListWorkspace")
        }

        let setCompatErr = spaceSetCompatID(connection, spaceID, compatWorkspaceID)
        guard setCompatErr == 0 else {
            throw SpaceMoveError.windowServerError(op: "SLSSpaceSetCompatID(set)", code: setCompatErr)
        }

        var mutableWindowID = UInt32(windowID)
        let workspaceErr = withUnsafeMutablePointer(to: &mutableWindowID) { pointer in
            setWindowListWorkspace(connection, pointer, 1, compatWorkspaceID)
        }
        let clearCompatErr = spaceSetCompatID(connection, spaceID, 0)

        guard workspaceErr == 0 else {
            throw SpaceMoveError.windowServerError(op: "SLSSetWindowListWorkspace", code: workspaceErr)
        }
        guard clearCompatErr == 0 else {
            throw SpaceMoveError.windowServerError(op: "SLSSpaceSetCompatID(clear)", code: clearCompatErr)
        }
    }

    private static func normalizedSpaces(_ spaces: [UInt64]) -> [UInt64] {
        var seen = Set<UInt64>()
        var result: [UInt64] = []
        for space in spaces where space != 0 && !seen.contains(space) {
            seen.insert(space)
            result.append(space)
        }
        return result
    }

    private static func formatSpaceList(_ spaces: [UInt64]) -> String {
        guard !spaces.isEmpty else { return "[]" }
        return "[" + spaces.map(String.init).joined(separator: ", ") + "]"
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let number = value as? NSNumber { return number.uint32Value }
        if let int = value as? Int { return UInt32(exactly: int) }
        if let int32 = value as? Int32 { return UInt32(exactly: int32) }
        return nil
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        if let value = value as? Int32 { return value }
        if let number = value as? NSNumber { return number.int32Value }
        if let int = value as? Int { return Int32(exactly: int) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func cgFloatValue(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let number = value as? NSNumber { return CGFloat(truncating: number) }
        if let double = value as? Double { return CGFloat(double) }
        if let int = value as? Int { return CGFloat(int) }
        return nil
    }

    /// Emit a single activity-log line if SkyLight resolution failed, then
    /// flip the latch so we don't spam the log on every restart.
    private static func logUnavailableOnce() {
        guard !hasLoggedUnavailable else { return }
        hasLoggedUnavailable = true
        ActivityLog.shared.log(.info,
            "SkyLight private API unavailable — Space restore on OBS restart will be skipped")
    }
}
