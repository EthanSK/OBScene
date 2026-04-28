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

    // MARK: - Public API

    /// Returns the SkyLight Space ID that's currently active on the main
    /// display, or `nil` if the SPI is unavailable / returns 0. Logs to the
    /// activity tab on first failure so the user can see the feature
    /// degraded.
    static func currentSpaceID() -> UInt64? {
        guard
            let connection = currentConnection(),
            let getActiveSpace: @convention(c) (Int32) -> UInt64 =
                lookup("CGSGetActiveSpace", as: (@convention(c) (Int32) -> UInt64).self)
        else {
            logUnavailableOnce()
            return nil
        }
        let spaceID = getActiveSpace(connection)
        // `0` is SkyLight's "no space" sentinel — surface it as nil so the
        // caller doesn't try to move a window onto Space ID 0.
        return spaceID == 0 ? nil : spaceID
    }

    /// Look up the topmost (front-most) window owned by the process with
    /// PID `pid`, returning its CGWindowID. Returns `nil` if the process
    /// has no matching window.
    ///
    /// Z-order: `CGWindowListCopyWindowInfo` returns windows ordered
    /// front-to-back. The first hit is therefore the user's main OBS
    /// window in the common single-window setup; in multi-window setups
    /// we still pick the front-most because that's the window the user
    /// is most likely to interact with after relaunch.
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
    ///     `kCGWindowListOptionAll` (== 0) instead.
    static func mainWindowID(forPID pid: pid_t, includeOffscreen: Bool = false) -> CGWindowID? {
        let opts: CGWindowListOption = includeOffscreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in info {
            guard
                let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                ownerPID == pid,
                let layerNumber = entry[kCGWindowLayer as String] as? Int,
                layerNumber == 0  // Layer 0 = normal application window.
            else { continue }

            // Filter out tiny chrome/hidden windows that occasionally appear
            // for OBS's IPC / WebSocket internals. The main window is always
            // wider than 200pt; anything smaller is likely an off-axis helper.
            if let bounds = entry[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? CGFloat, width < 200 {
                continue
            }
            if let wid = entry[kCGWindowNumber as String] as? CGWindowID {
                return wid
            }
        }
        return nil
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
        // Filter out the SkyLight "no space" sentinel (0) before counting
        // memberships — a result like [0, 12345] should be treated as
        // single-Space.
        let memberships = (spacesForWindow(wid, connection: connection) ?? [])
            .filter { $0 != 0 }
        guard memberships.count == 1 else {
            // Either zero Spaces (window is a hidden helper / SPI failure)
            // or sticky/multi-Space — both are non-restorable. We log the
            // multi-space case so the user can see why their feature
            // didn't activate; the empty case has already produced a
            // single warning via `logUnavailableOnce`.
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
            if let wid = mainWindowID(forPID: pid) {
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
    /// Implementation note: SkyLight has TWO families of "move window to
    /// space" symbols across macOS history. We call `CGSAddWindowsToSpaces`
    /// followed by `CGSRemoveWindowsFromSpaces` for the OLD space rather
    /// than `CGSMoveWindowsToManagedSpace` because the move variant has a
    /// known race on macOS 14+ where a recently-relaunched window can be
    /// silently rejected if SkyLight hasn't finished registering it. The
    /// add+remove dance is the path Hammerspoon settled on after the same
    /// regression and works reliably under stress.
    static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: UInt64) throws {
        guard let connection = currentConnection() else {
            throw SpaceMoveError.skyLightUnavailable
        }
        guard
            let addWindowsToSpaces: @convention(c) (Int32, CFArray, CFArray) -> Void =
                lookup("CGSAddWindowsToSpaces",
                       as: (@convention(c) (Int32, CFArray, CFArray) -> Void).self)
        else {
            throw SpaceMoveError.symbolMissing("CGSAddWindowsToSpaces")
        }

        // Wrap inputs as CFArray of NSNumber (CGSSpaceID is uint64; the SPI
        // takes a CFArray of NSNumber values).
        let widValue = NSNumber(value: UInt32(windowID))
        let spaceValue = NSNumber(value: spaceID)
        let widsArray = [widValue] as CFArray
        let spacesArray = [spaceValue] as CFArray

        // First: figure out which spaces the window is currently on so we can
        // remove it from those after adding it to the target. If the window
        // is already on `spaceID`, we still issue the add (it's a no-op) and
        // skip the remove.
        let currentSpaces = spacesForWindow(windowID, connection: connection) ?? []

        addWindowsToSpaces(connection, widsArray, spacesArray)

        // Remove from any other spaces it was on so the window doesn't
        // remain "sticky" to multiple Spaces. Only do this if the window
        // had at least one OTHER space (typical case: the Space the user
        // is currently focused on, which is not where they came from).
        let otherSpaces = currentSpaces.filter { $0 != spaceID }
        if !otherSpaces.isEmpty,
           let removeWindowsFromSpaces: @convention(c) (Int32, CFArray, CFArray) -> Void =
                lookup("CGSRemoveWindowsFromSpaces",
                       as: (@convention(c) (Int32, CFArray, CFArray) -> Void).self) {
            let removeArray = otherSpaces.map { NSNumber(value: $0) } as CFArray
            removeWindowsFromSpaces(connection, widsArray, removeArray)
        }
    }

    /// Convenience: move OBS's main window back to the captured Space. Does
    /// the full flow (resolve current windows for `pid`, wait briefly if not
    /// yet present, then call `moveWindow`). Logs each step + outcome to
    /// ActivityLog so the user can see what happened.
    ///
    /// `windowWaitTimeout` is the cap on how long we'll wait for OBS's
    /// window to show up after relaunch. After that we give up silently.
    static func restoreOBSWindow(pid: pid_t,
                                 toSpace spaceID: UInt64,
                                 profileName: String,
                                 windowWaitTimeout: TimeInterval) {
        ActivityLog.shared.log(.info,
            "Polling for OBS window to restore Space \(spaceID) (\(profileName))")
        waitForWindow(pid: pid, timeout: windowWaitTimeout) { windowID in
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

        var description: String {
            switch self {
            case .skyLightUnavailable:
                return "SkyLight private framework unavailable"
            case .symbolMissing(let name):
                return "SkyLight symbol missing: \(name)"
            case .unexpectedEmptyResponse(let detail):
                return "SkyLight returned empty: \(detail)"
            }
        }
    }

    // MARK: - Private helpers

    /// Look up the running app's SkyLight connection ID. Cached lazily — the
    /// connection persists for the lifetime of the process so we never need
    /// to re-resolve it. Returns `nil` if `CGSMainConnectionID` is missing
    /// from this macOS's SkyLight (extremely unlikely but possible on a
    /// broken system).
    private static func currentConnection() -> Int32? {
        guard let mainConnectionID: @convention(c) () -> Int32 =
                lookup("CGSMainConnectionID", as: (@convention(c) () -> Int32).self)
        else {
            return nil
        }
        let cid = mainConnectionID()
        // 0 is SkyLight's "no connection" sentinel — same as currentSpaceID().
        return cid == 0 ? nil : cid
    }

    /// Return the array of Space IDs the given window is currently a member
    /// of. SkyLight masks: `0x7` = "all spaces this window is on across all
    /// users / displays" (the value yabai/Hammerspoon both use).
    private static func spacesForWindow(_ wid: CGWindowID, connection: Int32) -> [UInt64]? {
        guard
            let copySpacesForWindows: @convention(c) (Int32, Int32, CFArray) -> CFArray =
                lookup("CGSCopySpacesForWindows",
                       as: (@convention(c) (Int32, Int32, CFArray) -> CFArray).self)
        else {
            return nil
        }
        let widsArray = [NSNumber(value: UInt32(wid))] as CFArray
        // 0x7 = all spaces (any of: visible, current user, any display)
        let result = copySpacesForWindows(connection, 0x7, widsArray)
        guard let spaces = result as? [NSNumber] else { return nil }
        return spaces.map { $0.uint64Value }
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
