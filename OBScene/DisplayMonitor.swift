import Foundation
import CoreGraphics

extension Notification.Name {
    static let displayTriggerFired = Notification.Name("displayTriggerFired")
    static let displayUnplugTriggerFired = Notification.Name("displayUnplugTriggerFired")
    static let externalDisplayCountChanged = Notification.Name("externalDisplayCountChanged")
    static let obsConnectionChanged = Notification.Name("obsConnectionChanged")
}

// File-scoped C-compatible callback function. Storing it in a `let` of the
// concrete `CGDisplayReconfigurationCallBack` type guarantees we get the SAME
// function pointer every time we register and remove it. (Passing two different
// closure literals to register/remove would yield two different thunks and
// silently leak the registration — which is exactly the bug we're fixing.)
private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
    guard let userInfo = userInfo else { return }
    let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    // Respond to display add/remove events after reconfiguration is complete
    if flags.contains(.addFlag) || flags.contains(.removeFlag) {
        // Only process when the reconfiguration is done (no beginFlag)
        if !flags.contains(.beginConfigurationFlag) {
            DispatchQueue.main.async {
                monitor.handleDisplayChange()
            }
        }
    }
}

class DisplayMonitor {
    static let shared = DisplayMonitor()

    private(set) var externalDisplayCount: Int = 0
    private var isMonitoring = false

    /// Per-profile pending trigger work items, keyed by profile ID.
    private var triggerWorkItems: [UUID: DispatchWorkItem] = [:]

    /// Per-profile in-flight inter-action dispatch work items. When a trigger
    /// fires and `delayBetweenActions > 0`, each action (except the first) is
    /// dispatched as a separate DispatchWorkItem with a staggered deadline.
    /// Cancelling the profile's trigger also cancels any still-pending action
    /// work items from a previous firing.
    private var inFlightActionWorkItems: [UUID: [DispatchWorkItem]] = [:]

    private init() {
        updateDisplayCount()
    }

    deinit {
        stopMonitoring()
        cancelAllPendingTriggers()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Use passUnretained: DisplayMonitor.shared lives for the app lifetime,
        // and we don't want the C registration to keep an extra retain that
        // would only be released by an explicit unregister.
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Pass the SAME function pointer we registered with so the runtime can
        // actually find and remove the registration.
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
    }

    fileprivate func handleDisplayChange() {
        let previousCount = externalDisplayCount
        updateDisplayCount()

        NotificationCenter.default.post(name: .externalDisplayCountChanged, object: nil)

        if externalDisplayCount > previousCount {
            ActivityLog.shared.log(
                .displayConnected,
                "External display connected (\(externalDisplayCount) total)"
            )
        } else if externalDisplayCount < previousCount {
            ActivityLog.shared.log(
                .displayDisconnected,
                "External display disconnected (\(externalDisplayCount) total)"
            )
        }

        // Evaluate each enabled display profile independently. A profile
        // only fires on its own configured edge (plug-in OR plug-out, not
        // both) — users combine two profiles to react to both edges.
        let store = ConfigStore.shared
        let displayProfiles = store.enabledProfiles(ofType: .display)

        for profile in displayProfiles {
            let required = profile.requiredExternalDisplays
            let crossedUp = externalDisplayCount >= required && previousCount < required
            let crossedDown = externalDisplayCount < required && previousCount >= required

            switch profile.mode {
            case .plugIn:
                if crossedUp {
                    scheduleTrigger(for: profile)
                }
                if crossedDown {
                    // A plug-in profile that was armed but hasn't fired yet
                    // should be cancelled when the condition goes away. The
                    // plug-out edge itself is someone else's problem (handled
                    // by plug-out profiles further down this loop).
                    if triggerWorkItems[profile.id] != nil {
                        cancelPendingTrigger(for: profile.id)
                        OBSWebSocketManager.shared.cancelInflightEnsureConnected()
                        ActivityLog.shared.log(.info, "Pending trigger cancelled (\(profile.name))")
                    }
                }
            case .plugOut:
                if crossedDown {
                    scheduleTrigger(for: profile)
                }
                if crossedUp {
                    // Plug-out profile armed by an earlier drop but displays
                    // came back before the delay elapsed — cancel.
                    if triggerWorkItems[profile.id] != nil {
                        cancelPendingTrigger(for: profile.id)
                        ActivityLog.shared.log(.info, "Pending plug-out trigger cancelled (\(profile.name))")
                    }
                }
            }
        }
    }

    private func updateDisplayCount() {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        // Subtract 1 for the built-in display
        let builtInDisplay = displays.first { CGDisplayIsBuiltin($0) != 0 }
        let externalCount = builtInDisplay != nil ? Int(displayCount) - 1 : Int(displayCount)
        externalDisplayCount = max(0, externalCount)
    }

    /// True iff this profile has any OBS-facing work configured — an
    /// action, or a scene collection / profile / scene selection. Script-only
    /// profiles (runScript set, nothing else) return false and therefore
    /// don't cause OBS warm-up, auto-launch, or the full connect pipeline to
    /// run. Kept as a `static` so the scheduling helpers can call it before
    /// an instance is required on the trigger hot path.
    private static func profileHasOBSWork(_ profile: TriggerProfile) -> Bool {
        return !profile.actions.isEmpty
            || !profile.selectedSceneCollection.isEmpty
            || !profile.selectedProfile.isEmpty
            || !profile.selectedScene.isEmpty
    }

    private func scheduleTrigger(for profile: TriggerProfile) {
        cancelPendingTrigger(for: profile.id)

        let profileId = profile.id
        let delay = profile.triggerDelay
        let workItem = DispatchWorkItem { [weak self] in
            self?.executeTrigger(for: profileId)
        }
        triggerWorkItems[profileId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: workItem)

        print("[OBScene] Display trigger scheduled in \(delay)s for profile '\(profile.name)'")
        ActivityLog.shared.log(.triggerScheduled, "Trigger scheduled in \(delay)s (\(profile.name))")

        // Kick off OBS auto-launch + WebSocket warm-up in parallel with the
        // countdown so that by the time the delay elapses, OBS is hopefully
        // already up and connected. Net plug-in-to-recording time stays close
        // to `delay` seconds even when OBS is cold. Skipped for script-only
        // profiles so the hook doesn't incur an unexpected OBS launch.
        let obs = OBSWebSocketManager.shared
        let config = ConfigStore.shared.config
        if Self.profileHasOBSWork(profile)
            && !obs.isConnected
            && config.hasBeenConfigured
            && !config.obsHost.isEmpty
        {
            _ = obs.ensureConnected(
                host: config.obsHost,
                port: config.obsPort,
                password: config.obsPassword,
                autoLaunch: config.autoLaunchOBS,
                timeoutSeconds: config.obsLaunchTimeoutSeconds,
                onReady: { _ in }
            )
        }
    }

    private func cancelPendingTrigger(for profileId: UUID) {
        triggerWorkItems[profileId]?.cancel()
        triggerWorkItems.removeValue(forKey: profileId)
        cancelInFlightActions(for: profileId)
    }

    private func cancelAllPendingTriggers() {
        for (_, item) in triggerWorkItems {
            item.cancel()
        }
        triggerWorkItems.removeAll()
        for (_, items) in inFlightActionWorkItems {
            for item in items { item.cancel() }
        }
        inFlightActionWorkItems.removeAll()
    }

    /// Cancel any still-pending staggered action dispatches for a profile.
    /// Safe to call even when the list is empty. Used both when a profile's
    /// trigger is cancelled mid-flight and at the top of each new firing to
    /// avoid overlapping dispatches from back-to-back triggers.
    private func cancelInFlightActions(for profileId: UUID) {
        if let items = inFlightActionWorkItems[profileId] {
            for item in items { item.cancel() }
        }
        inFlightActionWorkItems.removeValue(forKey: profileId)
    }

    /// Schedule a trigger for a USB profile.
    func scheduleUSBTrigger(for profile: TriggerProfile) {
        let delay = profile.triggerDelay
        let profileId = profile.id

        // Cancel any existing pending trigger for this profile.
        cancelPendingTrigger(for: profileId)

        let workItem = DispatchWorkItem { [weak self] in
            self?.executeTrigger(for: profileId)
        }
        triggerWorkItems[profileId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: workItem)

        print("[OBScene] USB trigger scheduled in \(delay)s for profile '\(profile.name)'")
        ActivityLog.shared.log(.triggerScheduled, "USB trigger scheduled in \(delay)s (\(profile.name))")

        // Kick off OBS auto-launch in parallel. Skipped for script-only
        // profiles so the hook doesn't incur an unexpected OBS launch.
        let obs = OBSWebSocketManager.shared
        let config = ConfigStore.shared.config
        if Self.profileHasOBSWork(profile)
            && !obs.isConnected
            && config.hasBeenConfigured
            && !config.obsHost.isEmpty
        {
            _ = obs.ensureConnected(
                host: config.obsHost,
                port: config.obsPort,
                password: config.obsPassword,
                autoLaunch: config.autoLaunchOBS,
                timeoutSeconds: config.obsLaunchTimeoutSeconds,
                onReady: { _ in }
            )
        }
    }

    /// Cancel any pending trigger for a USB profile. Used when the matching
    /// USB device disappears before the profile's plug-in delay elapses.
    func cancelUSBPendingTrigger(for profile: TriggerProfile) {
        if triggerWorkItems[profile.id] != nil {
            cancelPendingTrigger(for: profile.id)
            ActivityLog.shared.log(.info, "Pending USB trigger cancelled (\(profile.name))")
        }
    }

    /// Run the full trigger path for a specific profile. Used by the Settings
    /// "Simulate Trigger" button so the user can dry-run their configuration
    /// without replugging.
    func runTestTrigger(for profile: TriggerProfile) {
        cancelPendingTrigger(for: profile.id)
        ActivityLog.shared.log(.info, "Test trigger requested (\(profile.name))")
        executeTrigger(for: profile.id)
    }

    /// Legacy test trigger for backward compat — fires the first enabled profile.
    func runTestTrigger() {
        let profiles = ConfigStore.shared.config.profiles.filter { $0.isEnabled }
        if let first = profiles.first {
            runTestTrigger(for: first)
        } else {
            ActivityLog.shared.log(.info, "No enabled profiles to test")
        }
    }

    func executeTrigger(for profileId: UUID) {
        triggerWorkItems.removeValue(forKey: profileId)

        // Look up the profile from the current config (it may have been edited
        // since the trigger was scheduled).
        guard let profile = ConfigStore.shared.config.profiles.first(where: { $0.id == profileId }),
              profile.isEnabled else {
            print("[OBScene] Trigger fired but profile not found or disabled")
            return
        }

        // Fire the per-profile "Run on activate" shell hook FIRST, before any
        // OBS connection gating. This way script-only profiles still work
        // when OBS is disconnected / unconfigured / not installed, and scripts
        // intended to prep or recover OBS (e.g. `open -a OBS`, reset a
        // WebSocket) have a chance to run before the OBS pipeline bails out.
        // The script runs detached; the main trigger pipeline proceeds
        // immediately afterwards. Empty / whitespace-only runScript values
        // are no-ops inside ScriptRunner.
        let hasScript = !profile.runScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // If the profile has both a script AND `restartOBSBeforeRun`, the
        // script must run *after* OBS has restarted (workaround for the
        // Custom Browser Dock refresh limitation — full app restart is the
        // only reliable way to make a dock pick up an updated URL). In that
        // case we route the whole flow through `OBSAppController.restartOBS`,
        // which gates on streaming/recording state and short-circuits if
        // either is active. After the restart settles, we run the script
        // and then resume the rest of the trigger pipeline (OBS actions).
        //
        // For all other cases (no script, or script but no restart), keep
        // the original synchronous behaviour.
        if hasScript && profile.restartOBSBeforeRun {
            ActivityLog.shared.log(.info, "Restart-before-run requested (\(profile.name))")
            OBSAppController.restartOBS(profileName: profile.name) { [weak self] in
                guard let self = self else { return }
                ActivityLog.shared.log(.info, "Running profile script (\(profile.name))")
                ScriptRunner.run(script: profile.runScript, profileName: profile.name)

                // Same script-only fast-path check as the synchronous branch.
                if !Self.profileHasOBSWork(profile) { return }

                // Resume the OBS pipeline. Restart() leaves the WebSocket
                // either connected (happy path) or disconnected (the user has
                // recording/streaming active and we skipped restart, OR the
                // restart aborted on timeout — in both cases the existing
                // ensureConnected logic in `continueOBSPipeline` handles it
                // correctly).
                self.continueOBSPipeline(for: profile)
            }
            return
        }

        if hasScript {
            ActivityLog.shared.log(.info, "Running profile script (\(profile.name))")
            ScriptRunner.run(script: profile.runScript, profileName: profile.name)
        }

        // Script-only fast path: if the profile has no OBS work to do
        // (no actions queued, no scene collection / profile / scene selected),
        // we're done after the script. This avoids an otherwise-avoidable
        // OBS connect / auto-launch side effect for users who just want a
        // shell hook on plug in/out without touching OBS at all. The same
        // predicate gates the warm-up in scheduleTrigger/scheduleUSBTrigger
        // so the OBS connection is never even started for script-only
        // profiles.
        if hasScript && !Self.profileHasOBSWork(profile) {
            return
        }

        continueOBSPipeline(for: profile)
    }

    /// Drives the OBS-connection / action-firing tail of the trigger pipeline.
    /// Extracted from `executeTrigger` so the restart-OBS-before-run flow can
    /// also call into it once the restart settles.
    private func continueOBSPipeline(for profile: TriggerProfile) {
        let config = ConfigStore.shared.config
        let obs = OBSWebSocketManager.shared

        // Fast path: already connected, fire immediately.
        if obs.isConnected {
            runTriggerActions(for: profile)
            return
        }

        // Not connected. Try to auto-launch OBS.
        guard config.hasBeenConfigured, !config.obsHost.isEmpty else {
            print("[OBScene] Trigger fired but OBS connection is not configured")
            ActivityLog.shared.log(.info, "Trigger fired, but OBS not configured (\(profile.name))")
            return
        }

        let obsAlreadyRunning = obs.isOBSRunning()
        let timeout = obsAlreadyRunning ? 10 : config.obsLaunchTimeoutSeconds

        print("[OBScene] Trigger fired for '\(profile.name)', waiting for OBS WebSocket (timeout: \(timeout)s)")
        ActivityLog.shared.log(.info, "Waiting for OBS WebSocket (\(timeout)s) (\(profile.name))")

        _ = obs.ensureConnected(
            host: config.obsHost,
            port: config.obsPort,
            password: config.obsPassword,
            autoLaunch: config.autoLaunchOBS,
            timeoutSeconds: timeout,
            onReady: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .connected:
                    self.runTriggerActions(for: profile)
                case .cancelled:
                    print("[OBScene] Auto-launch cancelled for '\(profile.name)'")
                case .obsNotInstalled:
                    print("[OBScene] OBS is not installed")
                    ActivityLog.shared.log(.info, "OBS is not installed")
                    UserNotifier.post(
                        title: "OBScene: OBS not installed",
                        body: "OBS Studio isn't installed on this Mac. Download it from obsproject.com/download."
                    )
                case .autoLaunchDisabled:
                    print("[OBScene] Trigger fired but OBS is not running and auto-launch is disabled")
                    ActivityLog.shared.log(.info, "OBS not running and auto-launch disabled")
                    UserNotifier.post(
                        title: "OBScene: OBS not running",
                        body: "Enable auto-launch in Settings or start OBS manually."
                    )
                case .websocketUnavailable:
                    print("[OBScene] OBS is up but WebSocket didn't become available in time")
                    ActivityLog.shared.log(.info, "OBS WebSocket did not respond in time")
                    UserNotifier.post(
                        title: "OBScene: couldn't connect to OBS",
                        body: "OBS is running but its WebSocket server didn't respond. Enable it in Tools → WebSocket Server Settings."
                    )
                }
            }
        )
    }

    // MARK: - Trigger step delays
    //
    // Empirically OBS has well-known race conditions when you fire
    // `SetCurrentSceneCollection`, `SetCurrentProfile`, `SetCurrentProgramScene`,
    // and `StartRecord` at once over the WebSocket:
    //
    //   * `SetCurrentSceneCollection` reloads OBS's entire scene list
    //     asynchronously on OBS's side. Immediately issuing a
    //     `SetCurrentProgramScene` for a scene defined in the new collection
    //     can silently fail because the new scenes haven't been indexed yet.
    //   * Profile switches re-read recording/encoder settings. `StartRecord`
    //     fired before the profile has applied can use the old output path /
    //     encoder settings.
    //
    // As of 2026-04-18 we now verify each profile / scene-collection change
    // landed by polling OBS for the current value, with up to 3 retries on
    // failure — see `setProfileAndVerify` / `setSceneCollectionAndVerify`
    // in `OBSWebSocketManager`. That replaces the blind fixed-delay approach
    // for those two steps. We still use a short fixed delay between the
    // verified scene-collection set and the scene/action phase, because the
    // scene list itself is populated by OBS asynchronously after the
    // collection switch (the WebSocket v5 request ACK returns before the
    // new scenes are indexed).
    //
    // Order note (Ethan's diagnosis, 2026-04-18): profile switches lag more
    // than scene-collection switches, so we now switch the PROFILE FIRST
    // and the scene collection SECOND. That makes the overall operation
    // land more deterministically — by the time the scene-collection change
    // completes, the profile has settled too.
    private static let sceneToActionsDelay:      TimeInterval = 0.25 // 250ms
    /// Brief settle delay after a verified scene-collection change before
    /// we ask OBS for the new scene list. OBS repopulates `GetSceneList`
    /// asynchronously after the collection switch; the verification poll
    /// tells us the collection name flipped but doesn't guarantee the scene
    /// list has been rebuilt yet.
    private static let collectionSettleDelay:    TimeInterval = 0.5  // 500ms

    private func runTriggerActions(for profile: TriggerProfile) {
        let obs = OBSWebSocketManager.shared

        print("[OBScene] Trigger fired for '\(profile.name)' (\(profile.mode.shortLabel))! Executing OBS actions...")
        ActivityLog.shared.log(.triggerFired, "Trigger fired — executing actions (\(profile.name))")

        // Both plug-in and plug-out fire the same notification; consumers can
        // inspect `profile.mode` if they care.
        NotificationCenter.default.post(
            name: profile.mode == .plugOut ? .displayUnplugTriggerFired : .displayTriggerFired,
            object: nil,
            userInfo: ["profile": profile]
        )

        // Profile FIRST, scene collection SECOND. See the MARK comment above
        // for rationale. Both are verified + retried on failure; the error
        // case is surfaced via ActivityLog + UserNotifier and does NOT abort
        // the trigger — we still try to advance to the scene / actions so
        // that e.g. a missing profile doesn't suppress "Start Recording"
        // on a reasonable default profile OBS is already on.
        func runProfile(then next: @escaping () -> Void) {
            if profile.selectedProfile.isEmpty {
                next()
                return
            }
            obs.setProfileAndVerify(profile.selectedProfile) { _ in
                next()
            }
        }

        func runSceneCollection(then next: @escaping () -> Void) {
            if profile.selectedSceneCollection.isEmpty {
                next()
                return
            }
            obs.setSceneCollectionAndVerify(profile.selectedSceneCollection) { _ in
                // Even after verification, the new scene list may not be
                // populated in OBS yet; wait briefly before the scene step.
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.collectionSettleDelay,
                    execute: next
                )
            }
        }

        func runScene(then next: @escaping () -> Void) {
            if profile.selectedScene.isEmpty {
                next()
                return
            }
            obs.setScene(profile.selectedScene)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.sceneToActionsDelay,
                execute: next
            )
        }

        func runConfiguredActions() {
            // Clear any leftover in-flight dispatches from a prior firing of
            // this profile before scheduling a new batch.
            self.cancelInFlightActions(for: profile.id)

            let betweenDelay = max(0.0, profile.delayBetweenActions)
            let profileId = profile.id

            // Closure that actually fires a single action. Kept inline so it
            // can close over `obs` / `profile` without shared state games.
            func fire(_ action: TriggerActionConfig) {
                switch action.kind {
                case .recording:
                    if action.mode == .start { obs.startRecording() } else { obs.stopRecording() }
                case .streaming:
                    if action.mode == .start { obs.startStreaming() } else { obs.stopStreaming() }
                case .virtualCam:
                    if action.mode == .start { obs.startVirtualCam() } else { obs.stopVirtualCam() }
                case .replayBuffer:
                    if action.mode == .start { obs.startReplayBuffer() } else { obs.stopReplayBuffer() }
                case .refreshBrowsers, .refreshOBSBrowserSources:
                    // Both action kinds now refresh OBS browser sources only.
                    // The legacy `.refreshBrowsers` used to also reload the
                    // system Chrome/Safari/Arc/Firefox windows via AppleScript,
                    // but that was never the intent — the feature is meant to
                    // reload the browser SOURCES inside OBS scenes, not the
                    // user's system browser apps. Kept as an alias so older
                    // saved configs still work. Bug fix 2026-04-21.
                    ActivityLog.shared.log(.info, "Refreshing OBS browser sources")
                    obs.refreshAllBrowserSources()
                }
            }

            // Classify an action into one of three execution buckets. Ordering
            // matters because if a user puts "Start Recording" as action #1
            // and e.g. a refresh / virtual-cam toggle as action #2, the
            // recording would otherwise capture the wrong initial state.
            // We always fire:
            //   1. stops first  (let any pre-existing recording/stream/replay
            //                    buffer wrap up before we change state),
            //   2. non-recording actions in user order,
            //   3. recording-family STARTS last (recording, streaming, replay
            //      buffer — so the scene is fully settled when capture begins).
            // Within each bucket we preserve the user's relative order, and
            // the stagger index for `delayBetweenActions` is the new flat
            // position (not per-bucket), so the counter is not reset.
            enum ActionBucket { case stop, middle, recordingStart }
            func bucket(for action: TriggerActionConfig) -> ActionBucket {
                switch action.kind {
                case .recording, .streaming, .replayBuffer:
                    return action.mode == .start ? .recordingStart : .stop
                case .virtualCam:
                    // Virtual cam isn't a "capture to disk / to wire" action,
                    // so treat its start as a middle-bucket toggle and its
                    // stop like any other stop.
                    return action.mode == .start ? .middle : .stop
                case .refreshBrowsers, .refreshOBSBrowserSources:
                    return .middle
                }
            }

            let stops = profile.actions.filter { bucket(for: $0) == .stop }
            let middles = profile.actions.filter { bucket(for: $0) == .middle }
            let recordingStarts = profile.actions.filter { bucket(for: $0) == .recordingStart }
            let orderedActions = stops + middles + recordingStarts

            if betweenDelay == 0 {
                // Back-compat path: preserve the historical behaviour where
                // the OBS start/stop actions fire immediately and refresh
                // actions are deferred by a small fixed delay so they land
                // after any scene switch has settled. Reordering only affects
                // the OBS start/stop actions within this synchronous burst —
                // refresh actions still get their own post-trigger delay.
                for action in orderedActions {
                    switch action.kind {
                    case .recording, .streaming, .virtualCam, .replayBuffer:
                        fire(action)
                    case .refreshBrowsers, .refreshOBSBrowserSources:
                        break
                    }
                }

                // `.refreshBrowsers` is now an alias for `.refreshOBSBrowserSources`
                // (see `fire(_:)` above), so we only need a single deferred
                // refresh here even if a profile has both action kinds — they
                // do the same thing and one OBS refresh call covers both.
                let hasAnyBrowserRefresh = profile.actions.contains {
                    $0.kind == .refreshBrowsers || $0.kind == .refreshOBSBrowserSources
                }

                if hasAnyBrowserRefresh {
                    let item = DispatchWorkItem {
                        ActivityLog.shared.log(.info, "Refreshing OBS browser sources")
                        obs.refreshAllBrowserSources()
                    }
                    self.inFlightActionWorkItems[profileId, default: []].append(item)
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + BrowserRefresher.postTriggerDelay,
                        execute: item
                    )
                }
            } else {
                // Staggered path: first action fires immediately, each
                // subsequent action is offset by `index * delayBetweenActions`.
                // `index` is the position in the reordered flat list, so the
                // stops → middles → recordingStarts ordering is honoured and
                // the stagger counter is never reset per bucket.
                for (index, action) in orderedActions.enumerated() {
                    if index == 0 {
                        fire(action)
                    } else {
                        let item = DispatchWorkItem { fire(action) }
                        self.inFlightActionWorkItems[profileId, default: []].append(item)
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + Double(index) * betweenDelay,
                            execute: item
                        )
                    }
                }
            }
        }

        // Order: profile → scene collection → scene → actions.
        // See the MARK comment above — profile goes first on purpose.
        runProfile {
            runSceneCollection {
                runScene {
                    runConfiguredActions()
                }
            }
        }
    }
}
