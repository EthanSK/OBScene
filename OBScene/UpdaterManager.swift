import Cocoa
import Sparkle
import Combine

/// Thin wrapper around `SPUStandardUpdaterController` so the rest of the app
/// talks to a single, lazily-initialised auto-updater. Mirrors the
/// producer-player flow: check on launch (after a short delay), check every
/// 24h, auto-download, prompt to install + relaunch.
///
/// Sparkle reads its configuration directly from Info.plist:
///
///   - SUFeedURL              — appcast.xml URL (GitHub Pages)
///   - SUPublicEDKey          — EdDSA public key used to verify downloads
///   - SUEnableAutomaticChecks=YES
///   - SUScheduledCheckInterval=86400
///   - SUAutomaticallyUpdate=YES
///
/// See Frameworks/Sparkle.framework (vendored) and docs/RELEASING.md for the
/// release-side signing + appcast generation flow.
///
/// `ObservableObject` conformance lets the SwiftUI "Updates" panel in
/// `SettingsView` bind to the Sparkle settings directly — toggles read/write
/// `automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates` via this
/// wrapper and the `objectWillChange` publisher keeps the UI in sync.
final class UpdaterManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterManager()

    /// Result of a manual recheck, surfaced inline in the Settings UI.
    enum CheckResult: Equatable {
        case upToDate(currentVersion: String)
        case updateAvailable(currentVersion: String, latestVersion: String, releaseNotesURL: URL?)
        case failed(error: String)
    }

    /// Backing Sparkle controller. Created on first access in `start()`.
    /// `startingUpdater: true` means Sparkle will begin checking according to
    /// the Info.plist schedule as soon as it's constructed.
    private var updaterController: SPUStandardUpdaterController?

    /// Has `start()` been called at least once? Used to guard against
    /// double-initialisation.
    private var hasStarted = false

    // MARK: - Published manual-check state
    //
    // These properties back the split "Recheck" / "Download and Install"
    // buttons in the Settings Updates panel. They're only populated by the
    // user-initiated `recheck()` flow — the background scheduled check loop
    // still runs through Sparkle's standard user driver and doesn't touch
    // this state.

    /// Most recent manual recheck outcome. `nil` until the user presses
    /// "Recheck" for the first time in this session.
    @Published var lastCheckResult: CheckResult?

    /// True while a manual recheck is in-flight. Drives the inline spinner
    /// and disables the Recheck button to avoid double-taps.
    @Published var isChecking: Bool = false

    /// Pending update detected by the most recent manual recheck, if any.
    /// When non-nil, the "Install & Restart" button becomes enabled and
    /// clicking it hands off to Sparkle's standard install flow. Note that
    /// once a pending update is known we immediately trigger Sparkle's
    /// standard download+install flow in `didFindValidUpdate` — the button
    /// is really just a way to re-open Sparkle's dialog if the user
    /// dismissed it.
    @Published var pendingUpdate: SUAppcastItem?

    /// True once the user has initiated a recheck. Used so that we only
    /// auto-trigger the download-and-install handoff for user-initiated
    /// rechecks, not for background scheduled Sparkle checks (which already
    /// have their own download+install UI flow).
    private var recheckIsUserInitiated: Bool = false

    private override init() {
        super.init()
    }

    // MARK: - Observable settings (for SwiftUI bindings)

    /// Whether Sparkle should run its scheduled background check loop.
    /// Bound to the "Automatically check for updates" toggle in Settings.
    /// Reads/writes `SPUUpdater.automaticallyChecksForUpdates` — Sparkle
    /// persists the value in `NSUserDefaults` automatically, so toggling
    /// here survives relaunch without any extra work on our side.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? true }
        set {
            objectWillChange.send()
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Whether Sparkle should download updates in the background and prompt
    /// the user to install + relaunch (YES) vs. only notify and wait for the
    /// user to click "Install Update" (NO). Bound to the "Automatically
    /// download and install" toggle in Settings.
    var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? true }
        set {
            objectWillChange.send()
            updaterController?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Timestamp of the last time Sparkle fetched the appcast, or nil if it
    /// hasn't successfully checked yet in the current install. Displayed as
    /// "Last check: …" in the Settings Updates panel.
    var lastUpdateCheckDate: Date? {
        return updaterController?.updater.lastUpdateCheckDate
    }

    /// Current Sparkle feed URL. Resolves from Info.plist via Sparkle's own
    /// lookup so that if we ever change `SUFeedURL` the UI stays in sync
    /// automatically. Returns nil only in the screenshot-render subprocess
    /// where `start()` hasn't been called.
    var feedURL: URL? {
        return updaterController?.updater.feedURL
    }

    /// Short version string of the running app (matches the value Sparkle
    /// compares against the appcast). Used when constructing `CheckResult`.
    private var currentVersionString: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Boot the Sparkle updater. Safe to call multiple times — subsequent
    /// calls are no-ops. Should be called from
    /// `applicationDidFinishLaunching` on the main thread.
    func start() {
        assert(Thread.isMainThread, "UpdaterManager.start() must be called on main")
        guard !hasStarted else { return }
        hasStarted = true

        // `startingUpdater: true` tells Sparkle to kick off its scheduled
        // check loop immediately. We pass `self` as the `updaterDelegate`
        // so manual recheck events route into our `CheckResult` state
        // machine. The delegate methods are harmless during normal
        // background scheduled checks — Sparkle will still drive the
        // standard user-facing UI through `userDriverDelegate: nil`.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        // Belt-and-braces: force an explicit background check shortly after
        // launch so the user sees "update available" within seconds of
        // opening the app, not whenever Sparkle's internal timer next
        // fires. Matches producer-player's 9-second post-launch check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
            guard let self = self, let updater = self.updaterController?.updater else { return }
            // `checkForUpdatesInBackground()` is the non-interactive variant
            // that silently fetches the appcast and only surfaces UI if
            // there's actually an update. Perfect for a launch-time check.
            updater.checkForUpdatesInBackground()
        }
    }

    /// Manual "Check for Updates…" menu action. Always shows UI — if there's
    /// no update the user sees an "up to date" dialog, which is the right UX
    /// for an explicit user-initiated check from the menu bar dropdown.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller = updaterController else {
            // start() hasn't run yet. Fire it now and then immediately
            // surface the user-facing check. This shouldn't happen in
            // practice (AppDelegate calls start() on launch) but keeps the
            // menu item functional even if bootstrapping order changes.
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updaterController?.checkForUpdates(sender)
            }
            return
        }
        controller.checkForUpdates(sender)
    }

    // MARK: - Split recheck / install flow (Settings panel)

    /// Silently query the appcast and populate `lastCheckResult` /
    /// `pendingUpdate` without starting a download or showing any Sparkle
    /// UI. Used by the "Recheck" button in the Settings Updates panel.
    ///
    /// `checkForUpdateInformation()` is the correct Sparkle API for
    /// "just tell me if there's an update" — `checkForUpdates(_:)` would
    /// start the full interactive flow including automatic download
    /// whenever `SUAutomaticallyUpdate` is YES.
    func recheck() {
        assert(Thread.isMainThread, "UpdaterManager.recheck() must be called on main")
        guard let updater = updaterController?.updater else {
            // Render subprocess or pre-start() call — surface a placeholder
            // so the Settings UI has something sensible to show.
            lastCheckResult = .failed(error: "Updater not initialised")
            return
        }
        guard updater.canCheckForUpdates else {
            // Sparkle's own "already busy" guard. Don't overwrite the
            // previous result — just decline the click.
            return
        }
        isChecking = true
        recheckIsUserInitiated = true
        updater.checkForUpdateInformation()
    }

    /// Re-open Sparkle's install dialog for the pending update. The
    /// download is kicked off automatically in `didFindValidUpdate` as
    /// soon as the recheck finds something, so by the time the user
    /// clicks the "Install & Restart" button the update is either already
    /// downloaded or still downloading — either way, `checkForUpdates(_:)`
    /// reattaches to the existing Sparkle session and surfaces the
    /// install prompt + relaunch dance.
    func installPendingUpdate() {
        assert(Thread.isMainThread, "UpdaterManager.installPendingUpdate() must be called on main")
        guard pendingUpdate != nil, let controller = updaterController else { return }
        controller.checkForUpdates(nil)
    }

    /// True if Sparkle is currently allowed to show an update prompt. Used to
    /// enable/disable the menu item — we only disable while Sparkle itself
    /// reports it's already busy.
    var canCheckForUpdates: Bool {
        return updaterController?.updater.canCheckForUpdates ?? true
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle found a valid update in the appcast. Capture it so the
    /// Settings UI can show "Update available: vX.Y" inline, and — if this
    /// was a user-initiated recheck — immediately hand off to Sparkle's
    /// standard download+install flow so the user doesn't have to click a
    /// second button just to start the download.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isChecking = false
            self.pendingUpdate = item
            self.lastCheckResult = .updateAvailable(
                currentVersion: self.currentVersionString,
                latestVersion: item.displayVersionString,
                releaseNotesURL: item.releaseNotesURL
            )
            self.objectWillChange.send()

            // Auto-start download+install flow on user-initiated recheck.
            // Sparkle's standard user driver will present the "Update
            // available" dialog, download the signed .zip in the
            // background, verify the EdDSA signature, and prompt the user
            // to relaunch. `checkForUpdates(_:)` re-enters the update
            // session — Sparkle sees the same appcast entry we just found
            // and skips straight to the download UI.
            if self.recheckIsUserInitiated {
                self.recheckIsUserInitiated = false
                self.updaterController?.checkForUpdates(nil)
            }
        }
    }

    /// Sparkle finished checking and there was no newer version available.
    /// Clear any stale pendingUpdate from a previous check.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isChecking = false
            self.recheckIsUserInitiated = false
            self.pendingUpdate = nil
            self.lastCheckResult = .upToDate(currentVersion: self.currentVersionString)
            self.objectWillChange.send()
        }
    }

    /// Sparkle tried to download an update and failed (bad signature,
    /// network error, etc). Surface a user-readable error inline.
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isChecking = false
            self.recheckIsUserInitiated = false
            self.lastCheckResult = .failed(error: error.localizedDescription)
            self.objectWillChange.send()
        }
    }

    /// Sparkle aborted the update session (feed unreachable, malformed
    /// appcast, etc). Same treatment as a download failure — show the
    /// error inline so the user knows the recheck actually failed rather
    /// than silently hanging.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only treat this as a failed manual recheck if we were
            // actually mid-check — background scheduled failures shouldn't
            // clobber a perfectly good `.upToDate` or `.updateAvailable`
            // state from a prior manual recheck.
            guard self.isChecking else { return }
            self.isChecking = false
            self.recheckIsUserInitiated = false
            // Sparkle reports "no update found" through this path too
            // (error code SUNoUpdateError) on some configurations — treat
            // that as .upToDate, not a failure.
            let nsError = error as NSError
            // SUNoUpdateError == 1001 in SUErrors.h — hard-coded here to
            // dodge the NS_ENUM ↔ Swift bridging awkwardness.
            if nsError.domain == SUSparkleErrorDomain && nsError.code == 1001 {
                self.pendingUpdate = nil
                self.lastCheckResult = .upToDate(currentVersion: self.currentVersionString)
            } else {
                self.lastCheckResult = .failed(error: error.localizedDescription)
            }
            self.objectWillChange.send()
        }
    }
}
