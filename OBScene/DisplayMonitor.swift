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
    }

    private func cancelPendingTrigger() {
        triggerWorkItem?.cancel()
        triggerWorkItem = nil
    }

    func executeTrigger() {
        triggerWorkItem = nil

        let config = ConfigStore.shared.config
        let obs = OBSWebSocketManager.shared

        guard obs.isConnected else {
            print("[OBScene] Trigger fired but OBS is not connected")
            ActivityLog.shared.log(.info, "Trigger fired, but OBS not connected")
            return
        }

        print("[OBScene] Display trigger fired! Executing OBS actions...")
        ActivityLog.shared.log(.triggerFired, "Trigger fired — executing actions")

        NotificationCenter.default.post(name: .displayTriggerFired, object: nil)

        // Switch scene collection if configured
        if !config.selectedSceneCollection.isEmpty {
            obs.setSceneCollection(config.selectedSceneCollection)
        }

        // Switch profile if configured (delay slightly to let collection switch complete)
        if !config.selectedProfile.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                obs.setProfile(config.selectedProfile)
            }
        }

        // Switch scene if configured
        if !config.selectedScene.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                obs.setScene(config.selectedScene)
            }
        }

        // Start recording if enabled
        if config.startRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                obs.startRecording()
            }
        }

        // Start streaming if enabled
        if config.startStreaming {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                obs.startStreaming()
            }
        }

        // Start virtual camera if enabled
        if config.startVirtualCam {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                obs.startVirtualCam()
            }
        }

        // Start replay buffer if enabled
        if config.startReplayBuffer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                obs.startReplayBuffer()
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
