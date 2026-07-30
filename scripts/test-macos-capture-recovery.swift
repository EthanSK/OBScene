import Foundation
import CoreGraphics
import ImageIO

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

private func testDisabledButtonRemainsAmbiguous() {
    currentTest = "disabledButtonRemainsAmbiguous"
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
            MacOSCaptureRecoveryEntry(inputName: "Display", outcome: .buttonDisabled)
        ]),
        "OBS 604 is classified only as a disabled property button"
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

private func testMultipleInputsReactivateSerially() {
    currentTest = "multipleInputsReactivateSerially"
    var started: [String] = []
    var pendingCompletions: [(OBSRequestResultSnapshot?) -> Void] = []
    var result: MacOSCaptureRecoveryRunResult?
    let dependencies = MacOSCaptureRecoveryDependencies(
        isConnected: { true },
        listInputs: { completion in
            completion(success(inputs: [
                ["inputName": "Display B"],
                ["inputName": "Display A"]
            ]))
        },
        reactivate: { inputName, completion in
            started.append(inputName)
            pendingCompletions.append(completion)
        }
    )

    MacOSCaptureRecoveryEngine.run(dependencies: dependencies) { result = $0 }
    expect(started == ["Display A"], "starts only the first sorted input")
    expect(result == nil, "does not finish while the first input is pending")

    pendingCompletions.removeFirst()(success())
    expect(
        started == ["Display A", "Display B"],
        "starts the second input only after the first completes"
    )
    expect(result == nil, "waits for the second input")

    pendingCompletions.removeFirst()(failure(
        code: 604,
        comment: "The property item found is not enabled."
    ))
    expect(
        result == .completed([
            MacOSCaptureRecoveryEntry(
                inputName: "Display A",
                outcome: .reactivated
            ),
            MacOSCaptureRecoveryEntry(
                inputName: "Display B",
                outcome: .buttonDisabled
            )
        ]),
        "returns every serially collected input result"
    )
}

private func testRecoveryTriggerSchedules() {
    currentTest = "recoveryTriggerSchedules"
    expect(
        MacOSCaptureRecoveryTrigger.displayConnected.delays == [10],
        "display connection performs one native attempt after ten seconds"
    )
    expect(
        MacOSCaptureRecoveryTrigger.wake.delays == [10],
        "system wake performs one native attempt after ten seconds"
    )
    expect(
        MacOSCaptureRecoveryTrigger.recordingStarted.delays == [1],
        "recording start performs one native attempt after one second"
    )
}

private func testRecordingStartedEventMatching() {
    currentTest = "recordingStartedEventMatching"
    expect(
        OBSRecordingCaptureRecoveryPolicy.shouldSchedule(
            eventType: "RecordStateChanged",
            outputState: "OBS_WEBSOCKET_OUTPUT_STARTED"
        ),
        "schedules only after OBS confirms recording started"
    )
    expect(
        !OBSRecordingCaptureRecoveryPolicy.shouldSchedule(
            eventType: "RecordStateChanged",
            outputState: "OBS_WEBSOCKET_OUTPUT_STARTING"
        ),
        "ignores the intermediate recording-starting state"
    )
    expect(
        !OBSRecordingCaptureRecoveryPolicy.shouldSchedule(
            eventType: "StreamStateChanged",
            outputState: "OBS_WEBSOCKET_OUTPUT_STARTED"
        ),
        "ignores started events for other outputs"
    )
}

private func testSerialGateCoalescesWithoutOverlap() {
    currentTest = "serialGateCoalescesWithoutOverlap"
    var started: [MacOSCaptureRecoveryRequest] = []
    var completions: [() -> Void] = []
    var concurrentRuns = 0
    var maximumConcurrentRuns = 0

    let gate = MacOSCaptureRecoverySerialGate { request, completion in
        concurrentRuns += 1
        maximumConcurrentRuns = max(maximumConcurrentRuns, concurrentRuns)
        started.append(request)
        completions.append {
            concurrentRuns -= 1
            completion()
        }
    }

    let first = MacOSCaptureRecoveryRequest(reason: "display connected, batch 1")
    let second = MacOSCaptureRecoveryRequest(reason: "display connected, batch 2")
    let third = MacOSCaptureRecoveryRequest(reason: "display connected, batch 3")

    expect(gate.submit(first) == .started, "starts the first request")
    expect(
        gate.submit(second) == .queued(coalescedReasonCount: 1),
        "queues a follow-up while the first request is pending"
    )
    expect(
        gate.submit(third) == .queued(coalescedReasonCount: 2),
        "coalesces further trigger churn into the one pending request"
    )
    expect(started == [first], "never starts a second request concurrently")

    let finishFirst = completions.removeFirst()
    finishFirst()

    expect(started.count == 2, "starts the coalesced follow-up after completion")
    expect(
        started[1].reasons == [
            "display connected, batch 2",
            "display connected, batch 3"
        ],
        "preserves every coalesced trigger reason"
    )
    expect(maximumConcurrentRuns == 1, "allows at most one recovery transaction")

    let finishSecond = completions.removeFirst()
    finishSecond()
    expect(concurrentRuns == 0, "returns to idle after the follow-up completes")
}

private func screenshotDataURL(
    width: Int,
    height: Int,
    pixelAt: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
) -> String {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (red, green, blue, alpha) = pixelAt(x, y)
            let offset = (y * width + x) * 4
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
            pixels[offset + 3] = alpha
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    let png = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        png,
        "public.png" as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return "data:image/png;base64,\((png as Data).base64EncodedString())"
}

private func testScreenshotHealthRejectsBlackFrames() {
    currentTest = "screenshotHealthRejectsBlackFrames"
    let black = screenshotDataURL(width: 8, height: 8) { _, _ in
        (0, 0, 0, 255)
    }
    let blackHealth = MacOSCaptureScreenshotHealth.analyze(dataURL: black)
    expect(blackHealth != nil, "decodes a valid black PNG")
    expect(
        blackHealth?.isVisiblyNonBlack == false,
        "rejects an all-black capture frame"
    )

    let cursorOnly = screenshotDataURL(width: 8, height: 8) { x, y in
        x == 0 && y == 0 ? (255, 255, 255, 255) : (0, 0, 0, 255)
    }
    expect(
        MacOSCaptureScreenshotHealth
            .analyze(dataURL: cursorOnly)?
            .isVisiblyNonBlack == false,
        "a tiny bright cursor does not make a black frame healthy"
    )
    let indicatorOnly = screenshotDataURL(width: 64, height: 64) { _, y in
        y < 2 ? (255, 255, 255, 255) : (0, 0, 0, 255)
    }
    expect(
        MacOSCaptureScreenshotHealth
            .analyze(dataURL: indicatorOnly)?
            .isVisiblyNonBlack == false,
        "a thin bright indicator does not make a black frame healthy"
    )
    expect(
        MacOSCaptureScreenshotHealth.analyze(dataURL: "not-an-image") == nil,
        "rejects malformed screenshot data"
    )
}

private func testScreenshotHealthAcceptsVisibleFrames() {
    currentTest = "screenshotHealthAcceptsVisibleFrames"
    let visible = screenshotDataURL(width: 8, height: 8) { x, y in
        (
            UInt8((x + 1) * 255 / 9),
            UInt8((y + 1) * 255 / 9),
            102,
            255
        )
    }
    let health = MacOSCaptureScreenshotHealth.analyze(dataURL: visible)
    expect(health?.isVisiblyNonBlack == true, "accepts a visibly non-black frame")
    expect(health?.width == 8 && health?.height == 8, "records frame dimensions")
    expect(health?.sha256.count == 64, "records a content hash without the image")
}

private func testSceneItemPlacementDetectsOffCanvasCapture() {
    currentTest = "sceneItemPlacementDetectsOffCanvasCapture"
    let offCanvas = MacOSCaptureSceneItemPlacement.analyze(
        transform: [
            "positionX": -6206.0,
            "positionY": 2078.0,
            "width": 3440.0,
            "height": 1440.0,
            "alignment": 5
        ],
        canvasWidth: 3440,
        canvasHeight: 1440
    )
    expect(offCanvas != nil, "parses the live OBS transform shape")
    expect(
        offCanvas?.intersectsCanvas == false,
        "detects a healthy capture item positioned entirely off-canvas"
    )

    let fullCanvas = MacOSCaptureSceneItemPlacement.analyze(
        transform: [
            "positionX": 0.0,
            "positionY": 0.0,
            "width": 3440.0,
            "height": 1440.0,
            "alignment": 5
        ],
        canvasWidth: 3440,
        canvasHeight: 1440
    )
    expect(
        fullCanvas?.intersectsCanvas == true,
        "accepts a full-canvas top-left-aligned source"
    )

    let partiallyVisible = MacOSCaptureSceneItemPlacement.analyze(
        transform: [
            "positionX": -50.0,
            "positionY": 720.0,
            "width": 200.0,
            "height": 200.0,
            "alignment": 0
        ],
        canvasWidth: 3440,
        canvasHeight: 1440
    )
    expect(
        partiallyVisible?.intersectsCanvas == true,
        "handles center alignment and partial canvas intersection"
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
        testDisabledButtonRemainsAmbiguous()
        testDisconnectedStopsBeforeListing()
        testNoCaptureInputsIsNoOp()
        testUnexpectedFailureIsPreserved()
        testMultipleInputsReactivateSerially()
        testRecoveryTriggerSchedules()
        testRecordingStartedEventMatching()
        testSerialGateCoalescesWithoutOverlap()
        testScreenshotHealthRejectsBlackFrames()
        testScreenshotHealthAcceptsVisibleFrames()
        testSceneItemPlacementDetectsOffCanvasCapture()
        testDiagnosticsDeleteOnlyExpiredNDJSON()

        if failures.isEmpty {
            print("MacOSCaptureRecovery tests passed (13 tests)")
        } else {
            print("\(failures.count) MacOSCaptureRecovery test failure(s)")
            exit(1)
        }
    }
}
