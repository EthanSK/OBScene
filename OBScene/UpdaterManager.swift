import Cocoa
import Sparkle

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
final class UpdaterManager: NSObject {
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
