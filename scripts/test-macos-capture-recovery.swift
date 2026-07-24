import Foundation

private var failures: [String] = []
private var currentTest = ""

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String,
    line: UInt = #line
) {
    if !condition() {
        let failure = "[\(currentTest)] \(message()) (line \(line))"
        failures.append(failure)
        print("  FAIL: \(failure)")
    }
}

private func success(
    inputs: [[String: Any]]? = nil,
    code: Int = 100
) -> OBSRequestResultSnapshot {
    OBSRequestResultSnapshot(
        result: true,
        code: code,
        comment: nil,
        responseData: inputs.map { ["inputs": $0] }
    )
}

private func failure(
    code: Int,
    comment: String
) -> OBSRequestResultSnapshot {
    OBSRequestResultSnapshot(
        result: false,
        code: code,
        comment: comment,
        responseData: nil
    )
}

private func testStoppedCaptureReactivates() {
    currentTest = "stoppedCaptureReactivates"
    var pressed: [String] = []
    var result: MacOSCaptureRecoveryRunResult?

    let dependencies = MacOSCaptureRecoveryDependencies(
        isConnected: { true },
        listInputs: { completion in
            completion(success(inputs: [
                ["inputName": "Display", "inputKind": "screen_capture"],
                ["inputName": "Camera", "inputKind": "av_capture_input"]
            ]))
        },
        reactivate: { inputName, completion in
            pressed.append(inputName)
            completion(success())
        }
    )

    MacOSCaptureRecoveryEngine.run(dependencies: dependencies) { result = $0 }

    expect(pressed == ["Display"], "pressed only the screen-capture input")
    expect(
        result == .completed([
            MacOSCaptureRecoveryEntry(inputName: "Display", outcome: .reactivated)
        ]),
        "successful property press is classified as reactivated"
    )
}

private func testDisabledButtonIsNoOp() {
    currentTest = "disabledButtonIsNoOp"
    var result: MacOSCaptureRecoveryRunResult?
    let dependencies = MacOSCaptureRecoveryDependencies(
        isConnected: { true },
        listInputs: { completion in
            completion(success(inputs: [["inputName": "Display"]]))
        },
        reactivate: { _, completion in
            completion(failure(
                code: 604,
                comment: "The property item found is not enabled."
            ))
        }
    )

    MacOSCaptureRecoveryEngine.run(dependencies: dependencies) { result = $0 }

    expect(
        result == .completed([
            MacOSCaptureRecoveryEntry(inputName: "Display", outcome: .alreadyHealthy)
        ]),
        "OBS 604 is classified as a disabled-button no-op"
    )
}

private func testDisconnectedStopsBeforeListing() {
    currentTest = "disconnectedStopsBeforeListing"
    var listed = false
    var result: MacOSCaptureRecoveryRunResult?
    let dependencies = MacOSCaptureRecoveryDependencies(
        isConnected: { false },
        listInputs: { _ in listed = true },
        reactivate: { _, _ in }
    )

    MacOSCaptureRecoveryEngine.run(dependencies: dependencies) { result = $0 }

    expect(result == .notConnected, "returns notConnected")
    expect(!listed, "does not send a request while disconnected")
}

private func testNoCaptureInputsIsNoOp() {
    currentTest = "noCaptureInputsIsNoOp"
    var pressed = false
    var result: MacOSCaptureRecoveryRunResult?
    let dependencies = MacOSCaptureRecoveryDependencies(
        isConnected: { true },
        listInputs: { completion in
            completion(success(inputs: [
                ["inputName": "Camera", "inputKind": "av_capture_input"]
            ]))
        },
        reactivate: { _, _ in pressed = true }
    )

    MacOSCaptureRecoveryEngine.run(dependencies: dependencies) { result = $0 }

    expect(result == .noInputs, "returns noInputs")
    expect(!pressed, "does not press a property on unrelated inputs")
}

private func testUnexpectedFailureIsPreserved() {
    currentTest = "unexpectedFailureIsPreserved"
    var result: MacOSCaptureRecoveryRunResult?
    let dependencies = MacOSCaptureRecoveryDependencies(
        isConnected: { true },
        listInputs: { completion in
            completion(success(inputs: [["inputName": "Display"]]))
        },
        reactivate: { _, completion in
            completion(failure(code: 600, comment: "Unable to find property"))
        }
    )

    MacOSCaptureRecoveryEngine.run(dependencies: dependencies) { result = $0 }

    expect(
        result == .completed([
            MacOSCaptureRecoveryEntry(
                inputName: "Display",
                outcome: .failed(code: 600, comment: "Unable to find property")
            )
        ]),
        "unexpected OBS failure stays diagnostic"
    )
}

private func testEventScheduleIsImmediateAndBounded() {
    currentTest = "eventScheduleIsImmediateAndBounded"
    expect(
        MacOSCaptureRecoveryTrigger.wake.delays == [0, 2],
        "wake probes immediately and once after two seconds"
    )
    expect(
        MacOSCaptureRecoveryTrigger.displayChange.delays == [0, 1],
        "display change probes immediately and once after one second"
    )
    expect(
        MacOSCaptureRecoveryTrigger.sceneSelectionSettled.delays == [0],
        "settled scene selection probes immediately"
    )
    expect(
        MacOSCaptureRecoveryTrigger.wake.forceReinitializeOnFinalAttempt,
        "wake forces one final stream rebuild when OBS reports 604"
    )
    expect(
        MacOSCaptureRecoveryTrigger.displayChange.forceReinitializeOnFinalAttempt,
        "display change forces one final stream rebuild when OBS reports 604"
    )
    expect(
        !MacOSCaptureRecoveryTrigger.sceneSelectionSettled.forceReinitializeOnFinalAttempt,
        "normal scene selection does not force a disabled-button rebuild"
    )
}

private func testDiagnosticsDeleteOnlyExpiredNDJSON() {
    currentTest = "diagnosticsDeleteOnlyExpiredNDJSON"
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
        "obscene-capture-recovery-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = directory.appendingPathComponent("expired.ndjson")
        let recent = directory.appendingPathComponent("recent.ndjson")
        let boundary = directory.appendingPathComponent("boundary.ndjson")
        let unrelated = directory.appendingPathComponent("keep.txt")
        for file in [expired, recent, boundary, unrelated] {
            fileManager.createFile(atPath: file.path, contents: Data())
        }
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: expired.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-6 * 24 * 60 * 60)],
            ofItemAtPath: recent.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7 * 24 * 60 * 60)],
            ofItemAtPath: boundary.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30 * 24 * 60 * 60)],
            ofItemAtPath: unrelated.path
        )

        try CaptureRecoveryDiagnostics.removeExpiredLogs(
            in: directory,
            now: now,
            fileManager: fileManager
        )

        expect(
            !fileManager.fileExists(atPath: expired.path),
            "NDJSON older than seven days is removed"
        )
        expect(
            fileManager.fileExists(atPath: recent.path),
            "recent NDJSON is retained"
        )
        expect(
            fileManager.fileExists(atPath: boundary.path),
            "exactly seven-day-old NDJSON is retained"
        )
        expect(
            fileManager.fileExists(atPath: unrelated.path),
            "unrelated files are never removed"
        )
    } catch {
        expect(false, "diagnostics cleanup threw \(error)")
    }
}

@main
struct MacOSCaptureRecoveryTests {
    static func main() {
        testStoppedCaptureReactivates()
        testDisabledButtonIsNoOp()
        testDisconnectedStopsBeforeListing()
        testNoCaptureInputsIsNoOp()
        testUnexpectedFailureIsPreserved()
        testEventScheduleIsImmediateAndBounded()
        testDiagnosticsDeleteOnlyExpiredNDJSON()

        if failures.isEmpty {
            print("MacOSCaptureRecovery tests passed (7 tests)")
        } else {
            print("\(failures.count) MacOSCaptureRecovery test failure(s)")
            exit(1)
        }
    }
}
