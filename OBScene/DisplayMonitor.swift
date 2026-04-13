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

        // Evaluate each enabled display profile independently.
        let store = ConfigStore.shared
        let displayProfiles = store.enabledProfiles(ofType: .display)

        for profile in displayProfiles {
            let required = profile.requiredExternalDisplays

            // Trigger when we reach the required number of external displays
            // and previously we had fewer
            if externalDisplayCount >= required && previousCount < required {
                scheduleTrigger(for: profile)
            }

            // Cancel pending trigger if displays were disconnected, and fire
            // the unplug trigger.
            if externalDisplayCount < required && previousCount >= required {
                cancelPendingTrigger(for: profile.id)
                OBSWebSocketManager.shared.cancelInflightEnsureConnected()
                ActivityLog.shared.log(.info, "Pending trigger cancelled (\(profile.name))")
                executeUnplugTrigger(for: profile)
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
        // to `delay` seconds even when OBS is cold.
        let obs = OBSWebSocketManager.shared
        let config = ConfigStore.shared.config
        if !obs.isConnected && config.hasBeenConfigured && !config.obsHost.isEmpty {
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
    }

    private func cancelAllPendingTriggers() {
        for (_, item) in triggerWorkItems {
            item.cancel()
        }
        triggerWorkItems.removeAll()
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

        // Kick off OBS auto-launch in parallel.
        let obs = OBSWebSocketManager.shared
        let config = ConfigStore.shared.config
        if !obs.isConnected && config.hasBeenConfigured && !config.obsHost.isEmpty {
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

    /// Fire the unplug trigger for a USB profile.
    func executeUSBUnplugTrigger(for profile: TriggerProfile) {
        cancelPendingTrigger(for: profile.id)
        executeUnplugTrigger(for: profile)
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
    // OBS doesn't expose synchronous confirmation over the WebSocket v5
    // request/response channel for scene collection + profile switches
    // (the collection-changed event comes later), so we sequence the steps
    // with small fixed delays instead.
    private static let collectionToProfileDelay: TimeInterval = 0.5  // 500ms
    private static let profileToSceneDelay:      TimeInterval = 0.5  // 500ms
    private static let sceneToActionsDelay:      TimeInterval = 0.25 // 250ms

    private func runTriggerActions(for profile: TriggerProfile) {
        let obs = OBSWebSocketManager.shared

        print("[OBScene] Trigger fired for '\(profile.name)'! Executing OBS actions...")
        ActivityLog.shared.log(.triggerFired, "Trigger fired — executing actions (\(profile.name))")

        NotificationCenter.default.post(
            name: .displayTriggerFired,
            object: nil,
            userInfo: ["profile": profile]
        )

        func runSceneCollection(then next: @escaping () -> Void) {
            if profile.selectedSceneCollection.isEmpty {
                next()
                return
            }
            obs.setSceneCollection(profile.selectedSceneCollection)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.collectionToProfileDelay,
                execute: next
            )
        }

        func runProfile(then next: @escaping () -> Void) {
            if profile.selectedProfile.isEmpty {
                next()
                return
            }
            obs.setProfile(profile.selectedProfile)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.profileToSceneDelay,
                execute: next
            )
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

        func runStartActions() {
            if profile.startRecording    { obs.startRecording()    }
            if profile.startStreaming    { obs.startStreaming()    }
            if profile.startVirtualCam   { obs.startVirtualCam()   }
            if profile.startReplayBuffer { obs.startReplayBuffer() }
        }

        runSceneCollection {
            runProfile {
                runScene {
                    runStartActions()

                    if profile.refreshBrowsersOnTrigger {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + BrowserRefresher.postTriggerDelay
                        ) {
                            ActivityLog.shared.log(.info, "Refreshing browser tabs")
                            BrowserRefresher.refreshAllBrowsers()
                        }
                    }

                    if profile.refreshOBSBrowserSourcesOnTrigger {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + BrowserRefresher.postTriggerDelay + 1.0
                        ) {
                            ActivityLog.shared.log(.info, "Refreshing OBS browser sources")
                            obs.refreshAllBrowserSources()
                        }
                    }
                }
            }
        }
    }

    private func executeUnplugTrigger(for profile: TriggerProfile) {
        // Nothing to do if no stop-on-unplug option is enabled.
        guard profile.stopRecordingOnUnplug
                || profile.stopStreamingOnUnplug
                || profile.stopVirtualCamOnUnplug
                || profile.stopReplayBufferOnUnplug else { return }

        let obs = OBSWebSocketManager.shared

        guard obs.isConnected else {
            print("[OBScene] Unplug trigger fired for '\(profile.name)' but OBS is not connected")
            return
        }

        print("[OBScene] Unplug trigger for '\(profile.name)'! Executing stop actions...")

        NotificationCenter.default.post(
            name: .displayUnplugTriggerFired,
            object: nil,
            userInfo: ["profile": profile]
        )

        if profile.stopRecordingOnUnplug    { obs.stopRecording()    }
        if profile.stopStreamingOnUnplug    { obs.stopStreaming()    }
        if profile.stopVirtualCamOnUnplug   { obs.stopVirtualCam()   }
        if profile.stopReplayBufferOnUnplug { obs.stopReplayBuffer() }
    }
}
