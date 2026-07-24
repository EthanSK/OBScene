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

private func testHealthyCaptureIsNoOp() {
    currentTest = "healthyCaptureIsNoOp"
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
        "OBS 604 is a healthy no-op"
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
}

@main
struct MacOSCaptureRecoveryTests {
    static func main() {
        testStoppedCaptureReactivates()
        testHealthyCaptureIsNoOp()
        testDisconnectedStopsBeforeListing()
        testNoCaptureInputsIsNoOp()
        testUnexpectedFailureIsPreserved()
        testEventScheduleIsImmediateAndBounded()

        if failures.isEmpty {
            print("MacOSCaptureRecovery tests passed (6 tests)")
        } else {
            print("\(failures.count) MacOSCaptureRecovery test failure(s)")
            exit(1)
        }
    }
}
