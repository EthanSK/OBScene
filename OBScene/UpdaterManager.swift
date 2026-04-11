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
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    /// Backing Sparkle controller. Created on first access in `start()`.
    /// `startingUpdater: true` means Sparkle will begin checking according to
    /// the Info.plist schedule as soon as it's constructed.
    private var updaterController: SPUStandardUpdaterController?

    /// Has `start()` been called at least once? Used to guard against
    /// double-initialisation.
    private var hasStarted = false

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

    /// Boot the Sparkle updater. Safe to call multiple times — subsequent
    /// calls are no-ops. Should be called from
    /// `applicationDidFinishLaunching` on the main thread.
    func start() {
        assert(Thread.isMainThread, "UpdaterManager.start() must be called on main")
        guard !hasStarted else { return }
        hasStarted = true

        // `startingUpdater: true` tells Sparkle to kick off its scheduled
        // check loop immediately. `updaterDelegate: nil` uses default
        // behaviour (respect Info.plist, prompt user on first launch for
        // opt-in). `userDriverDelegate: nil` uses the standard UI.
        //
        // Note: we do NOT pass a custom delegate yet — the defaults match
        // producer-player's UX closely enough (check on launch, auto
        // download, prompt to install). If we ever need to customise the
        // prompt text or the "update available" dialog, add a delegate.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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
    /// for an explicit user-initiated check.
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

    /// True if Sparkle is currently allowed to show an update prompt. Used to
    /// enable/disable the menu item — we only disable while Sparkle itself
    /// reports it's already busy.
    var canCheckForUpdates: Bool {
        return updaterController?.updater.canCheckForUpdates ?? true
    }
}
