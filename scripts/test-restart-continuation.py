#!/usr/bin/env python3
"""Exercise the actual restart preflight without opening or stopping real OBS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "OBScene/OBSWebSocketManager.swift").read_text()
entry = "    static func restartOBS(profileName: String," + source.split(
    "    static func restartOBS(profileName: String,", 1
)[1].split("    /// Pre-flight outcome", 1)[0]
display = (root / "OBScene/DisplayMonitor.swift").read_text()
assert display.count("guard canRunOBSWork else") == 2
assert "if isSimulated { beforeRun() }" not in source
assert "beforeRun: @escaping () -> Void" not in source

fixture = r'''
import Foundation
enum LogKind { case info }
final class ActivityLog {
    static let shared = ActivityLog()
    func log(_ kind: LogKind, _ text: String, userVisible: Bool = false) {}
}
final class OBSWebSocketManager {
    static let shared = OBSWebSocketManager()
    var running = true
    var isConnected = true
    func isOBSRunning() -> Bool { running }
}
enum OBSAppController {
    static var restartInFlight = false
    static var lastRestartAt: Date?
    static let throttleWindow = 30.0
    static let stopOutputsTimeoutSeconds = 20.0
    enum LiveState { case inactive, unknown, active(streaming: Bool, recording: Bool) }
    static var state: LiveState = .inactive
    static var stopped = true
    static var restartResult = true
    static var restartCalls = 0
    static func checkLiveSession(obs: OBSWebSocketManager, completion: (LiveState) -> Void) { completion(state) }
    static func stopOutputs(obs: OBSWebSocketManager, streaming: Bool, recording: Bool,
                            profileName: String, completion: (Bool) -> Void) { completion(stopped) }
    static func saveSceneCollectionBestEffort(obs: OBSWebSocketManager, completion: () -> Void) { completion() }
    static func performRestart(profileName: String, selectedProfile: String, selectedSceneCollection: String,
                               selectedScene: String, isSimulated: Bool, beforeRun: (Bool) -> Void) {
        precondition(selectedProfile == "3000AD Music")
        precondition(selectedSceneCollection == "3000ad v3 new")
        restartCalls += 1
        restartInFlight = false
        beforeRun(restartResult)
    }
'''
fixture += entry + "\n}\n"
fixture += r'''
func check(_ name: String, state: OBSAppController.LiveState = .inactive,
           running: Bool = true, connected: Bool = true, stopped: Bool = true,
           inFlight: Bool = false, throttled: Bool = false, simulated: Bool = false,
           restartResult: Bool = true, expected: Bool, expectedRestarts: Int = 0) {
    OBSAppController.state = state
    OBSAppController.stopped = stopped
    OBSAppController.restartInFlight = inFlight
    OBSAppController.lastRestartAt = throttled ? Date() : nil
    OBSAppController.restartResult = restartResult
    OBSAppController.restartCalls = 0
    OBSWebSocketManager.shared.running = running
    OBSWebSocketManager.shared.isConnected = connected
    var result: Bool?
    var completions = 0
    OBSAppController.restartOBS(profileName: name, selectedProfile: "3000AD Music",
        selectedSceneCollection: "3000ad v3 new", selectedScene: "Scene", isSimulated: simulated) {
        result = $0
        completions += 1
    }
    let deadline = Date().addingTimeInterval(2)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(result == expected, "\(name): wrong pipeline permission")
    precondition(completions == 1, "\(name): duplicate completion")
    precondition(OBSAppController.restartCalls == expectedRestarts, "\(name): unexpected restart")
    print("PASS: \(name)")
}
check("unknown live state blocks OBS actions", state: .unknown, expected: false)
check("unknown live state also blocks simulated OBS actions", state: .unknown, simulated: true, expected: false)
check("disconnected safety skip blocks OBS actions", connected: false, expected: false)
check("failed output stop blocks OBS actions", state: .active(streaming: true, recording: true), stopped: false, expected: false)
check("in-flight restart does not permit another collection switch", inFlight: true, expected: false)
check("throttled restart does not permit a collection switch", throttled: true, expected: false)
check("absent OBS preserves cold-launch continuation", running: false, expected: true)
check("inactive outputs permit successful restart", expected: true, expectedRestarts: 1)
check("clean output stop permits successful restart", state: .active(streaming: false, recording: true), expected: true, expectedRestarts: 1)
check("failed relaunch result does not permit OBS actions", restartResult: false, expected: false, expectedRestarts: 1)
'''
with tempfile.TemporaryDirectory(prefix="obscene-restart-test-") as directory:
    harness = Path(directory) / "main.swift"
    binary = Path(directory) / "restart-test"
    harness.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("PASS: both trigger orderings gate OBS actions; script execution remains separate")
