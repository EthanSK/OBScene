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
    private var triggerWorkItem: DispatchWorkItem?

    private init() {
        updateDisplayCount()
    }

    deinit {
        stopMonitoring()
        cancelPendingTrigger()
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

        let config = ConfigStore.shared.config
        let requiredDisplays = config.requiredExternalDisplays

        // Trigger when we reach the required number of external displays
        // and previously we had fewer
        if externalDisplayCount >= requiredDisplays && previousCount < requiredDisplays {
            scheduleTrigger(delay: config.triggerDelay)
        }

        // Cancel pending trigger if displays were disconnected, and fire the
        // "displays unplugged" trigger so listeners can stop recording/streaming.
        if externalDisplayCount < requiredDisplays && previousCount >= requiredDisplays {
            cancelPendingTrigger()
            // Also abort any in-flight OBS auto-launch wait — the trigger is
            // no longer going to fire, so polling the socket is pointless.
            OBSWebSocketManager.shared.cancelInflightEnsureConnected()
            ActivityLog.shared.log(.info, "Pending trigger cancelled")
            executeUnplugTrigger()
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

    private func scheduleTrigger(delay: Int) {
        cancelPendingTrigger()

        let workItem = DispatchWorkItem { [weak self] in
            self?.executeTrigger()
        }
        triggerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: workItem)

        print("[OBScene] Display trigger scheduled in \(delay) seconds")
        ActivityLog.shared.log(.triggerScheduled, "Trigger scheduled in \(delay)s")

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
                onReady: { _ in
                    // The result is consumed by executeTrigger — it'll run
                    // ensureConnected again when the delay fires and either
                    // get `.connected` immediately or block until the shared
                    // wait finishes. We don't need to do anything here.
                }
            )
        }
    }

    private func cancelPendingTrigger() {
        triggerWorkItem?.cancel()
        triggerWorkItem = nil
    }

    /// Run the full trigger path as if an external display had just reached
    /// the required count. Used by the Settings "Simulate Display Connection"
    /// button so the user can dry-run their configuration without replugging.
    ///
    /// Unlike real triggers, this:
    ///   - fires immediately (ignores `config.triggerDelay`)
    ///   - still respects auto-launch OBS (launches OBS if needed)
    ///   - still runs scene collection + profile + scene switch + all 4 start
    ///     actions, with the same inter-action delays as a real trigger
    ///
    /// i.e. it's identical to a real trigger, minus the countdown delay.
    func runTestTrigger() {
        // Cancel any real pending trigger so the test can't fight with it.
        cancelPendingTrigger()
        ActivityLog.shared.log(.info, "Test trigger requested (simulating display connection)")
        executeTrigger()
    }

    func executeTrigger() {
        triggerWorkItem = nil

        let config = ConfigStore.shared.config
        let obs = OBSWebSocketManager.shared

        // Fast path: already connected, fire immediately.
        if obs.isConnected {
            runTriggerActions()
            return
        }

        // Not connected. Try to auto-launch OBS (or just reconnect to an
        // already-running OBS) and fire when the WebSocket is up.
        guard config.hasBeenConfigured, !config.obsHost.isEmpty else {
            print("[OBScene] Trigger fired but OBS connection is not configured")
            ActivityLog.shared.log(.info, "Trigger fired, but OBS not configured")
            return
        }

        // Pick a timeout. If OBS is already running we only need enough time
        // for the WebSocket handshake to complete (OBS usually binds the
        // socket within a second of startup, but we give it some slack). If
        // OBS is cold we respect the full user-configured launch timeout.
        //
        // Note: scheduleTrigger may already have kicked off a parallel
        // ensureConnected during the delay countdown — in that case this
        // call supersedes it but inherits the launched OBS process, so the
        // shorter timeout is usually fine.
        let obsAlreadyRunning = obs.isOBSRunning()
        let timeout = obsAlreadyRunning ? 10 : config.obsLaunchTimeoutSeconds

        print("[OBScene] Trigger fired, waiting for OBS WebSocket (timeout: \(timeout)s)")
        ActivityLog.shared.log(.info, "Waiting for OBS WebSocket (\(timeout)s)")

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
                    self.runTriggerActions()
                case .cancelled:
                    print("[OBScene] Auto-launch cancelled (displays unplugged mid-wait)")
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
    // with small fixed delays instead. Keeping them as named constants so
    // the next person to tweak them knows exactly what each gap guards.
    //
    // If reliability regresses on slower machines, bump these — especially
    // `collectionToProfileDelay`, which guards the slowest OBS reload step.
    // See also docs/RELEASING.md "Trigger sequencing" for the rationale.
    private static let collectionToProfileDelay: TimeInterval = 0.5  // 500ms
    private static let profileToSceneDelay:      TimeInterval = 0.5  // 500ms
    private static let sceneToActionsDelay:      TimeInterval = 0.25 // 250ms

    private func runTriggerActions() {
        let config = ConfigStore.shared.config
        let obs = OBSWebSocketManager.shared

        print("[OBScene] Display trigger fired! Executing OBS actions...")
        ActivityLog.shared.log(.triggerFired, "Trigger fired — executing actions")

        NotificationCenter.default.post(name: .displayTriggerFired, object: nil)

        // Build the step pipeline as an ordered sequence. Each step runs on
        // the main queue and schedules the next with the configured delay,
        // so delays compose naturally and we never fire a later step before
        // the earlier one has at least been issued. Skipped steps fall
        // through immediately (no delay) — we only pay latency for steps the
        // user actually enabled.
        //
        // (We use asyncAfter from .now() at each hop rather than pre-computing
        // absolute deadlines so that a slow main queue doesn't compress the
        // gaps between steps — the gap is always "500ms after the previous
        // request was posted", regardless of scheduling jitter.)

        func runSceneCollection(then next: @escaping () -> Void) {
            if config.selectedSceneCollection.isEmpty {
                next()
                return
            }
            obs.setSceneCollection(config.selectedSceneCollection)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.collectionToProfileDelay,
                execute: next
            )
        }

        func runProfile(then next: @escaping () -> Void) {
            if config.selectedProfile.isEmpty {
                next()
                return
            }
            obs.setProfile(config.selectedProfile)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.profileToSceneDelay,
                execute: next
            )
        }

        func runScene(then next: @escaping () -> Void) {
            if config.selectedScene.isEmpty {
                next()
                return
            }
            obs.setScene(config.selectedScene)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.sceneToActionsDelay,
                execute: next
            )
        }

        func runStartActions() {
            // These four are independent — no ordering constraint between
            // them, so fire in parallel.
            if config.startRecording    { obs.startRecording()    }
            if config.startStreaming    { obs.startStreaming()    }
            if config.startVirtualCam   { obs.startVirtualCam()   }
            if config.startReplayBuffer { obs.startReplayBuffer() }
        }

        runSceneCollection {
            runProfile {
                runScene {
                    runStartActions()
                }
            }
        }
    }

    private func executeUnplugTrigger() {
        let config = ConfigStore.shared.config

        // Nothing to do if no stop-on-unplug option is enabled.
        guard config.stopRecordingOnUnplug
                || config.stopStreamingOnUnplug
                || config.stopVirtualCamOnUnplug
                || config.stopReplayBufferOnUnplug else { return }

        let obs = OBSWebSocketManager.shared

        guard obs.isConnected else {
            print("[OBScene] Unplug trigger fired but OBS is not connected")
            return
        }

        print("[OBScene] Displays unplugged! Executing stop actions...")

        NotificationCenter.default.post(name: .displayUnplugTriggerFired, object: nil)

        // Stop immediately — no delay on teardown.
        if config.stopRecordingOnUnplug {
            obs.stopRecording()
        }
        if config.stopStreamingOnUnplug {
            obs.stopStreaming()
        }
        if config.stopVirtualCamOnUnplug {
            obs.stopVirtualCam()
        }
        if config.stopReplayBufferOnUnplug {
            obs.stopReplayBuffer()
        }
    }
}
