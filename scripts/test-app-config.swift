import Foundation

@main
struct AppConfigTests {
    static func main() throws {
        let decoder = JSONDecoder()

        guard TriggerProfile().delayBetweenActions == 2 else {
            fatalError("new profiles must default to a 2-second action delay")
        }

        let legacyProfile = try decoder.decode(
            TriggerProfile.self,
            from: Data("{\"name\":\"Legacy\"}".utf8)
        )
        guard legacyProfile.delayBetweenActions == 0 else {
            fatalError("saved profiles missing the delay key must retain 0 seconds")
        }

        var explicitZeroDelayProfile = TriggerProfile()
        explicitZeroDelayProfile.delayBetweenActions = 0
        let zeroDelayRoundTrip = try decoder.decode(
            TriggerProfile.self,
            from: JSONEncoder().encode(explicitZeroDelayProfile)
        )
        guard zeroDelayRoundTrip.delayBetweenActions == 0 else {
            fatalError("an explicit 0-second action delay did not persist")
        }

        var freshConfig = AppConfig()
        freshConfig.migrateToProfilesIfNeeded()
        guard freshConfig.profiles.first?.delayBetweenActions == 2 else {
            fatalError("the fresh-install profile must default to 2 seconds")
        }

        var preDelayConfig = AppConfig()
        preDelayConfig.hasBeenConfigured = true
        preDelayConfig.migrateToProfilesIfNeeded()
        guard preDelayConfig.profiles.first?.delayBetweenActions == 0 else {
            fatalError("a migrated pre-delay configuration must retain 0 seconds")
        }

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

        var profileA = TriggerProfile()
        profileA.name = "A"
        var profileB = TriggerProfile()
        profileB.name = "B"
        var profileC = TriggerProfile()
        profileC.name = "C"

        let movedForward = ProfileOrdering.moving(
            [profileA, profileB, profileC],
            draggedID: profileA.id,
            over: profileB.id
        )
        guard movedForward.map(\.name) == ["B", "A", "C"] else {
            fatalError("dragging a profile forward produced the wrong order")
        }

        let movedToEnd = ProfileOrdering.moving(
            movedForward,
            draggedID: profileA.id,
            over: profileC.id
        )
        guard movedToEnd.map(\.name) == ["B", "C", "A"] else {
            fatalError("dragging a profile to the end produced the wrong order")
        }

        var reorderedConfig = AppConfig()
        reorderedConfig.profiles = movedToEnd
        let reorderedRoundTrip = try decoder.decode(
            AppConfig.self,
            from: JSONEncoder().encode(reorderedConfig)
        )
        guard reorderedRoundTrip.profiles.map(\.name) == ["B", "C", "A"] else {
            fatalError("the reordered profile-tab order did not persist")
        }

        let movedBackward = ProfileOrdering.moving(
            [profileA, profileB, profileC],
            draggedID: profileC.id,
            over: profileA.id
        )
        guard movedBackward.map(\.name) == ["C", "A", "B"] else {
            fatalError("dragging a profile backward produced the wrong order")
        }

        let unchanged = ProfileOrdering.moving(
            [profileA, profileB, profileC],
            draggedID: profileB.id,
            over: profileB.id
        )
        guard unchanged.map(\.name) == ["A", "B", "C"] else {
            fatalError("dropping a profile on itself must not reorder tabs")
        }

        print("AppConfig tests passed (25 tests)")
    }
}
