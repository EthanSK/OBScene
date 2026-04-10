import Foundation
import CoreGraphics

extension Notification.Name {
    static let displayTriggerFired = Notification.Name("displayTriggerFired")
    static let externalDisplayCountChanged = Notification.Name("externalDisplayCountChanged")
    static let obsConnectionChanged = Notification.Name("obsConnectionChanged")
}

class DisplayMonitor {
    static let shared = DisplayMonitor()

    private(set) var externalDisplayCount: Int = 0
    private var isMonitoring = false
    private var triggerWorkItem: DispatchWorkItem?

    private init() {
        updateDisplayCount()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // Respond to display add/remove events after reconfiguration is complete
            if flags.contains(.addFlag) || flags.contains(.removeFlag) {
                // Use beginTransaction/endTransaction pattern:
                // Only process when the reconfiguration is done (no beginFlag)
                if !flags.contains(.beginConfigurationFlag) {
                    DispatchQueue.main.async {
                        monitor.handleDisplayChange()
                    }
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        CGDisplayRemoveReconfigurationCallback({ displayID, flags, userInfo in
            // Matching callback signature for removal
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func handleDisplayChange() {
        let previousCount = externalDisplayCount
        updateDisplayCount()

        NotificationCenter.default.post(name: .externalDisplayCountChanged, object: nil)

        let config = ConfigStore.shared.config
        let requiredDisplays = config.requiredExternalDisplays

        // Trigger when we reach the required number of external displays
        // and previously we had fewer
        if externalDisplayCount >= requiredDisplays && previousCount < requiredDisplays {
            scheduleTrigger(delay: config.triggerDelay)
        }

        // Cancel pending trigger if displays were disconnected
        if externalDisplayCount < requiredDisplays && previousCount >= requiredDisplays {
            cancelPendingTrigger()
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
    }

    private func cancelPendingTrigger() {
        triggerWorkItem?.cancel()
        triggerWorkItem = nil
    }

    private func executeTrigger() {
        triggerWorkItem = nil

        let config = ConfigStore.shared.config
        let obs = OBSWebSocketManager.shared

        guard obs.isConnected else {
            print("[OBScene] Trigger fired but OBS is not connected")
            return
        }

        print("[OBScene] Display trigger fired! Executing OBS actions...")

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
    }
}
