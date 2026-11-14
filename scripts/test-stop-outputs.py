#!/usr/bin/env python3
"""Run the production stop waiter on a virtual clock without controlling OBS.

Called by run-tests.sh. --source-ref COMMIT reproduces an older stop window
against the same slow-stop case, rather than testing a second implementation.
"""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-ref")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    relative_source = "OBScene/OBSWebSocketManager.swift"
    source = (
        subprocess.check_output(
            ["git", "show", f"{args.source_ref}:{relative_source}"], cwd=root, text=True
        )
        if args.source_ref
        else (root / relative_source).read_text()
    )
    start = source.index("    private static func stopOutputs(")
    end = source.index("    private static func saveSceneCollectionBestEffort", start)
    constants: list[str] = []
    for name in ["stopOutputsTimeoutSeconds", "restartRequestTimeoutSeconds"]:
        match = re.search(rf"private static let {name}: TimeInterval = ([\d.]+)", source)
        if match is None:
            raise ValueError(f"Missing production constant: {name}")
        constants.append(f"    static let {name}: TimeInterval = {match.group(1)}")

    fixture = r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }
}

// Only the clock, queue and OBS boundary are fakes; the waiter below is extracted
// unchanged from the app. Advance time instead of sleeping or touching live OBS.
var clock = 0.0
var serial = 0
var jobs: [(Double, Int, () -> Void)] = []
struct Date: Comparable {
    var value: Double = clock
    init() {}
    init(value: Double) { self.value = value }
    func addingTimeInterval(_ seconds: Double) -> Date { Date(value: value + seconds) }
    func timeIntervalSince(_ other: Date) -> Double { value - other.value }
    var timeIntervalSinceNow: Double { value - clock }
    static func < (a: Date, b: Date) -> Bool { a.value < b.value }
}
struct Deadline {
    let time: Double
    static func now() -> Deadline { Deadline(time: clock) }
    static func + (a: Deadline, b: Double) -> Deadline { Deadline(time: a.time + b) }
}
final class DispatchQueue {
    static let main = DispatchQueue()
    func async(execute job: @escaping () -> Void) { asyncAfter(deadline: .now(), execute: job) }
    func asyncAfter(deadline: Deadline, execute job: @escaping () -> Void) {
        serial += 1
        jobs.append((deadline.time, serial, job))
    }
}
enum LogKind { case info }
final class ActivityLog {
    static let shared = ActivityLog()
    func log(_ kind: LogKind, _ text: String, userVisible: Bool = false) {}
}
enum ReplyMode { case normal, unknown, silent, late, duplicate }
final class OBSWebSocketManager {
    var recordUntil = 0.0
    var streamUntil = 0.0
    var mode: ReplyMode = .normal
    var recordStops = 0
    var streamStops = 0
    func stopStreaming() { streamStops += 1 }
    func stopRecording() { recordStops += 1 }
    func getStreamingActive(_ callback: @escaping (Bool?) -> Void) {
        reply(until: streamUntil, callback: callback)
    }
    func getRecordingActive(_ callback: @escaping (Bool?) -> Void) {
        reply(until: recordUntil, callback: callback)
    }
    private func reply(until: Double, callback: @escaping (Bool?) -> Void) {
        switch mode {
        case .normal:
            callback(clock < until)
        case .unknown:
            callback(nil)
        case .silent:
            break
        case .late:
            DispatchQueue.main.asyncAfter(deadline: .now() + 61) { callback(clock < until) }
        case .duplicate:
            callback(clock < until)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { callback(clock < until) }
        }
    }
}
enum StopTests {
'''
    fixture += "\n".join(constants) + "\n" + source[start:end]
    fixture += r'''
    static func run(_ name: String, recordUntil: Double, streamUntil: Double = 0,
                    recording: Bool = true, streaming: Bool = false,
                    mode: ReplyMode = .normal, expected: Bool, expectedTime: Double) {
        clock = 0; serial = 0; jobs = []
        let obs = OBSWebSocketManager()
        obs.recordUntil = recordUntil; obs.streamUntil = streamUntil; obs.mode = mode
        var results: [(Bool, Double)] = []
        stopOutputs(obs: obs, streaming: streaming, recording: recording, profileName: name) {
            results.append(($0, clock))
        }
        var executed = 0
        while !jobs.isEmpty {
            jobs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            let job = jobs.removeFirst()
            clock = job.0; job.2()
            executed += 1
            require(executed < 10000, "unbounded polling")
        }
        require(results.count == 1, "\(name): completion must happen once")
        require(results[0].0 == expected, "\(name): wrong stopped result")
        require(abs(results[0].1 - expectedTime) < 0.001, "\(name): wrong deadline")
        require(obs.recordStops == (recording ? 1 : 0), "\(name): repeated StopRecord")
        require(obs.streamStops == (streaming ? 1 : 0), "\(name): repeated StopStream")
        print("PASS: \(name) -> \(results[0].0) at \(results[0].1)s, one completion")
    }
    static func main() {
        // This first case fails against the old 20s production window.
        run("observed 22.637s stop", recordUntil: 22.637, expected: true, expectedTime: 23)
        require(stopOutputsTimeoutSeconds == 60, "Ethan requested a one-minute limit")
        run("quick stop proceeds immediately", recordUntil: 2.1, expected: true, expectedTime: 2.5)
        run("stop near minute boundary", recordUntil: 59.2, expected: true, expectedTime: 59.5)
        run("stop after minute stays blocked", recordUntil: 60.1, expected: false, expectedTime: 60)
        run("streaming must stop too", recordUntil: 22.637, streamUntil: 45,
            streaming: true, expected: true, expectedTime: 45)
        run("unknown state stays blocked", recordUntil: 0, mode: .unknown, expected: false, expectedTime: 60)
        run("missing replies cannot hang", recordUntil: 0, mode: .silent, expected: false, expectedTime: 60)
        run("late replies cannot resume aborted work", recordUntil: 0, mode: .late, expected: false, expectedTime: 60)
        run("duplicate replies cannot double-complete", recordUntil: 5, mode: .duplicate, expected: true, expectedTime: 5)
        run("inactive outputs need no stop", recordUntil: 0, recording: false, expected: true, expectedTime: 0)
    }
}
StopTests.main()
'''
    with tempfile.TemporaryDirectory(prefix="obscene-stop-tests-", suffix=".noindex") as directory:
        harness = Path(directory) / "main.swift"
        binary = Path(directory) / "stop-tests"
        harness.write_text(fixture)
        subprocess.run(["xcrun", "swiftc", str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
