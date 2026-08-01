import Foundation

@main
struct AppConfigTests {
    static func main() throws {
        let decoder = JSONDecoder()

        let legacy = try decoder.decode(AppConfig.self, from: Data("{}".utf8))
        guard !legacy.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("missing recovery toggle must default to disabled")
        }
        guard !legacy.restoreMissingCustomBrowserDocksAfterProfileChanges else {
            fatalError("missing dock-restoration toggle must default to disabled")
        }

        let enabledJSON = """
        {"automaticallyRecoverOBSAfterWakeAndDisplayChanges":true}
        """
        let enabled = try decoder.decode(
            AppConfig.self,
            from: Data(enabledJSON.utf8)
        )
        guard enabled.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("explicitly enabled recovery toggle was not decoded")
        }

        let encoded = try JSONEncoder().encode(enabled)
        let roundTrip = try decoder.decode(AppConfig.self, from: encoded)
        guard roundTrip.automaticallyRecoverOBSAfterWakeAndDisplayChanges else {
            fatalError("enabled recovery toggle did not persist")
        }

        let dockEnabledJSON = """
        {"restoreMissingCustomBrowserDocksAfterProfileChanges":true}
        """
        let dockEnabled = try decoder.decode(
            AppConfig.self,
            from: Data(dockEnabledJSON.utf8)
        )
        guard dockEnabled.restoreMissingCustomBrowserDocksAfterProfileChanges else {
            fatalError("explicitly enabled dock-restoration toggle was not decoded")
        }

        let dockEncoded = try JSONEncoder().encode(dockEnabled)
        let dockRoundTrip = try decoder.decode(AppConfig.self, from: dockEncoded)
        guard dockRoundTrip.restoreMissingCustomBrowserDocksAfterProfileChanges else {
            fatalError("enabled dock-restoration toggle did not persist")
        }

        let triggerActionJSON = """
        {
          "kind": "refresh_macos_capture_source",
          "mode": "stop"
        }
        """
        let triggerAction = try decoder.decode(
            TriggerActionConfig.self,
            from: Data(triggerActionJSON.utf8)
        )
        guard triggerAction.kind == .refreshMacOSCaptureSource else {
            fatalError("macOS capture refresh action kind was not decoded")
        }
        guard triggerAction.mode == .start else {
            fatalError("macOS capture refresh must remain a one-shot action")
        }

        guard TriggerActionKind.displayOrder.contains(.refreshMacOSCaptureSource) else {
            fatalError("macOS capture refresh is missing from Trigger Actions")
        }

        let actionEncoded = try JSONEncoder().encode(triggerAction)
        let actionRoundTrip = try decoder.decode(
            TriggerActionConfig.self,
            from: actionEncoded
        )
        guard actionRoundTrip.kind == .refreshMacOSCaptureSource,
              actionRoundTrip.mode == .start else {
            fatalError("macOS capture refresh action did not persist")
        }

        guard triggerAction.executionPhase == .middle else {
            fatalError("macOS capture refresh must be a middle-phase action")
        }

        let startRecording = TriggerActionConfig(
            kind: .recording,
            mode: .start
        )
        let stopStreaming = TriggerActionConfig(
            kind: .streaming,
            mode: .stop
        )
        let ordered = TriggerActionExecutionPlan.ordered([
            startRecording,
            triggerAction,
            stopStreaming
        ])
        guard ordered.map(\.kind) == [
            .streaming,
            .refreshMacOSCaptureSource,
            .recording
        ] else {
            fatalError("macOS capture refresh was not ordered before recording")
        }

        let wakeProfileJSON = """
        {
          "name": "Wake capture repair",
          "isEnabled": true,
          "triggerType": "wake",
          "mode": "plug_out",
          "triggerDelay": 10,
          "actions": [
            {"kind": "refresh_macos_capture_source", "mode": "start"}
          ]
        }
        """
        let wakeProfile = try decoder.decode(
            TriggerProfile.self,
            from: Data(wakeProfileJSON.utf8)
        )
        guard wakeProfile.triggerType == .wake,
              wakeProfile.triggerEventShortLabel == "wake",
              wakeProfile.triggerDelay == 10,
              !wakeProfile.usesPlugOutSemantics else {
            fatalError("wake profile configuration was not decoded")
        }

        var disabledWakeProfile = wakeProfile
        disabledWakeProfile.isEnabled = false
        var displayProfile = TriggerProfile()
        displayProfile.triggerType = .display
        let profilesToFire = WakeTriggerPolicy.profilesToFire(
            from: [displayProfile, disabledWakeProfile, wakeProfile]
        )
        guard profilesToFire.map(\.id) == [wakeProfile.id] else {
            fatalError("wake policy must select only enabled wake profiles")
        }

        let wakeEncoded = try JSONEncoder().encode(wakeProfile)
        let wakeRoundTrip = try decoder.decode(
            TriggerProfile.self,
            from: wakeEncoded
        )
        guard wakeRoundTrip.triggerType == .wake,
              wakeRoundTrip.triggerEventShortLabel == "wake" else {
            fatalError("wake profile did not persist")
        }

        print("AppConfig tests passed (15 tests)")
    }
}
