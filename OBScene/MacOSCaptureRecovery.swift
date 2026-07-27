import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

/// The subset of an OBS WebSocket request response that recovery decisions
/// need. Keeping this independent from the socket manager makes the recovery
/// policy directly unit-testable.
struct OBSRequestResultSnapshot {
    let result: Bool
    let code: Int
    let comment: String?
    let responseData: Any?
}

enum MacOSCaptureReactivationOutcome: Equatable {
    case reactivated
    case buttonDisabled
    case failed(code: Int?, comment: String?)
}

struct MacOSCaptureRecoveryEntry: Equatable {
    let inputName: String
    let outcome: MacOSCaptureReactivationOutcome
}

enum MacOSCaptureRecoveryRunResult: Equatable {
    case notConnected
    case listFailed(code: Int?, comment: String?)
    case noInputs
    case completed([MacOSCaptureRecoveryEntry])
}

struct MacOSCaptureRecoveryDependencies {
    let isConnected: () -> Bool
    let listInputs: (@escaping (OBSRequestResultSnapshot?) -> Void) -> Void
    let reactivate: (
        _ inputName: String,
        _ completion: @escaping (OBSRequestResultSnapshot?) -> Void
    ) -> Void
}

struct MacOSCaptureRecoveryRequest: Equatable {
    private(set) var reasons: [String]

    init(reason: String) {
        reasons = [reason]
    }

    var diagnosticReason: String {
        reasons.joined(separator: " + ")
    }

    mutating func merge(_ newer: MacOSCaptureRecoveryRequest) {
        for reason in newer.reasons where !reasons.contains(reason) {
            reasons.append(reason)
        }
    }
}

enum MacOSCaptureRecoverySubmission: Equatable {
    case started
    case queued(coalescedReasonCount: Int)
}

/// Allows at most one complete recovery transaction to touch OBS at a time.
///
/// Display reconfiguration callbacks can arrive faster than OBS answers the
/// first `reactivate_capture` request. Keep only one coalesced follow-up while
/// the current native property-button request is in flight. This prevents
/// overlapping reactivation calls when macOS emits several display callbacks
/// for one physical dock connection.
final class MacOSCaptureRecoverySerialGate {
    typealias Starter = (
        _ request: MacOSCaptureRecoveryRequest,
        _ completion: @escaping () -> Void
    ) -> Void

    private let start: Starter
    private var isInFlight = false
    private var pending: MacOSCaptureRecoveryRequest?

    init(start: @escaping Starter) {
        self.start = start
    }

    @discardableResult
    func submit(
        _ request: MacOSCaptureRecoveryRequest
    ) -> MacOSCaptureRecoverySubmission {
        guard isInFlight else {
            startNow(request)
            return .started
        }

        if var pending {
            pending.merge(request)
            self.pending = pending
        } else {
            pending = request
        }
        return .queued(coalescedReasonCount: pending?.reasons.count ?? 0)
    }

    private func startNow(_ request: MacOSCaptureRecoveryRequest) {
        isInFlight = true
        start(request) { [weak self] in
            guard let self else { return }
            if let next = pending {
                pending = nil
                startNow(next)
            } else {
                isInFlight = false
            }
        }
    }
}

struct MacOSCaptureScreenshotHealth: Equatable {
    let width: Int
    let height: Int
    let meanLuma: Double
    let nearBlackPixelRatio: Double
    let sha256: String

    /// A tiny bright cursor or menu-bar indicator should not make an otherwise
    /// black frame look healthy. Require both measurable average light and at
    /// least five percent of sampled pixels above near-black.
    var isVisiblyNonBlack: Bool {
        meanLuma > 2 && nearBlackPixelRatio < 0.95
    }

    static func analyze(dataURL: String) -> Self? {
        guard let comma = dataURL.firstIndex(of: ","),
              let imageData = Data(
                  base64Encoded: String(dataURL[dataURL.index(after: comma)...])
              ),
              let imageSource = CGImageSourceCreateWithData(
                  imageData as CFData,
                  nil
              ),
              let image = CGImageSourceCreateImageAtIndex(
                  imageSource,
                  0,
                  nil
              ),
              image.width > 0,
              image.height > 0 else {
            return nil
        }

        let sampleWidth = min(64, image.width)
        let sampleHeight = min(64, image.height)
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](
            repeating: 0,
            count: bytesPerRow * sampleHeight
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: sampleWidth,
                      height: sampleHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo:
                          CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: sampleWidth,
                    height: sampleHeight
                )
            )
            return true
        }
        guard rendered else { return nil }

        var lumaSum = 0.0
        var nearBlackCount = 0
        let sampleCount = sampleWidth * sampleHeight
        for index in 0..<sampleCount {
            let offset = index * 4
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            let luma = (
                0.2126 * red
                + 0.7152 * green
                + 0.0722 * blue
            )
            lumaSum += luma
            if luma <= 5 {
                nearBlackCount += 1
            }
        }

        // Hash the normalized sample rather than PNG bytes so changing encoder
        // metadata cannot look like changing screen content.
        let digest = SHA256.hash(data: Data(pixels))
        return Self(
            width: image.width,
            height: image.height,
            meanLuma: lumaSum / Double(sampleCount),
            nearBlackPixelRatio:
                Double(nearBlackCount) / Double(sampleCount),
            sha256: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

struct MacOSCaptureSceneItemPlacement: Equatable {
    let positionX: Double
    let positionY: Double
    let width: Double
    let height: Double
    let alignment: Int
    let canvasWidth: Double
    let canvasHeight: Double
    let left: Double
    let top: Double

    var right: Double { left + width }
    var bottom: Double { top + height }
    var intersectsCanvas: Bool {
        right > 0
            && bottom > 0
            && left < canvasWidth
            && top < canvasHeight
    }

    static func analyze(
        transform: [String: Any],
        canvasWidth: Double,
        canvasHeight: Double
    ) -> Self? {
        guard canvasWidth > 0,
              canvasHeight > 0,
              let positionX =
                (transform["positionX"] as? NSNumber)?.doubleValue,
              let positionY =
                (transform["positionY"] as? NSNumber)?.doubleValue,
              let rawWidth = (transform["width"] as? NSNumber)?.doubleValue,
              let rawHeight = (transform["height"] as? NSNumber)?.doubleValue,
              rawWidth != 0,
              rawHeight != 0 else {
            return nil
        }

        let width = abs(rawWidth)
        let height = abs(rawHeight)
        let alignment =
            (transform["alignment"] as? NSNumber)?.intValue ?? 0

        // libobs alignment flags: left=1, right=2, top=4, bottom=8.
        // With neither horizontal/vertical flag, the position is centered.
        let left: Double
        if alignment & 1 != 0 {
            left = positionX
        } else if alignment & 2 != 0 {
            left = positionX - width
        } else {
            left = positionX - width / 2
        }

        let top: Double
        if alignment & 4 != 0 {
            top = positionY
        } else if alignment & 8 != 0 {
            top = positionY - height
        } else {
            top = positionY - height / 2
        }

        return Self(
            positionX: positionX,
            positionY: positionY,
            width: width,
            height: height,
            alignment: alignment,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            left: left,
            top: top
        )
    }
}

/// Pure orchestration for recovering stopped OBS macOS Screen Capture inputs.
///
/// OBS exposes `reactivate_capture` only while it marks a ScreenCaptureKit
/// stream as failed. Pressing it in that state returns success (100). Code 604
/// means only that the property button is disabled. OBS 32.2.0 can return 604
/// for both a healthy source and a black missing-display target, so callers
/// inspect a source frame for reporting but never mutate unrelated source
/// settings to force a rebuild.
enum MacOSCaptureRecoveryEngine {
    static let inputKind = "screen_capture"
    static let propertyName = "reactivate_capture"
    static let buttonDisabledCode = 604

    static func run(
        dependencies: MacOSCaptureRecoveryDependencies,
        completion: @escaping (MacOSCaptureRecoveryRunResult) -> Void
    ) {
        guard dependencies.isConnected() else {
            completion(.notConnected)
            return
        }

        dependencies.listInputs { response in
            guard let response else {
                completion(.listFailed(code: nil, comment: "request timed out"))
                return
            }
            guard response.result else {
                completion(.listFailed(code: response.code, comment: response.comment))
                return
            }

            let inputNames = screenCaptureInputNames(from: response.responseData)
            guard !inputNames.isEmpty else {
                completion(.noInputs)
                return
            }

            reactivateInputs(
                inputNames,
                index: 0,
                entries: [],
                dependencies: dependencies,
                completion: completion
            )
        }
    }

    /// OBS can own more than one ScreenCaptureKit input. Property-button
    /// requests are serialized within the transaction as well as transactions
    /// being serialized by the outer gate, so no two capture sources are asked
    /// to tear down or restart concurrently.
    private static func reactivateInputs(
        _ inputNames: [String],
        index: Int,
        entries: [MacOSCaptureRecoveryEntry],
        dependencies: MacOSCaptureRecoveryDependencies,
        completion: @escaping (MacOSCaptureRecoveryRunResult) -> Void
    ) {
        guard index < inputNames.count else {
            completion(.completed(entries))
            return
        }

        let inputName = inputNames[index]
        dependencies.reactivate(inputName) { response in
            reactivateInputs(
                inputNames,
                index: index + 1,
                entries: entries + [
                    MacOSCaptureRecoveryEntry(
                        inputName: inputName,
                        outcome: classifyReactivation(response)
                    )
                ],
                dependencies: dependencies,
                completion: completion
            )
        }
    }

    static func screenCaptureInputNames(from responseData: Any?) -> [String] {
        guard let data = responseData as? [String: Any],
              let inputs = data["inputs"] as? [[String: Any]] else {
            return []
        }

        let names = inputs.compactMap { input -> String? in
            // OBS normally includes inputKind. Accept an absent kind because
            // GetInputList was already server-filtered; reject an explicit
            // non-screen-capture kind in case an OBS build ignores the filter.
            if let kind = input["inputKind"] as? String, kind != inputKind {
                return nil
            }
            guard let name = input["inputName"] as? String, !name.isEmpty else {
                return nil
            }
            return name
        }

        return Array(Set(names)).sorted()
    }

    static func classifyReactivation(
        _ response: OBSRequestResultSnapshot?
    ) -> MacOSCaptureReactivationOutcome {
        guard let response else {
            return .failed(code: nil, comment: "request timed out")
        }
        if response.result {
            return .reactivated
        }
        if response.code == buttonDisabledCode {
            return .buttonDisabled
        }
        return .failed(code: response.code, comment: response.comment)
    }
}

/// Capture recovery stays native-only and bounded for each event. Display and
/// wake recovery wait for macOS/ScreenCaptureKit to settle; recording-start
/// recovery runs shortly after OBS confirms that recording is active.
enum MacOSCaptureRecoveryTrigger: Hashable {
    case displayConnected
    case wake
    case recordingStarted

    var delays: [TimeInterval] {
        switch self {
        case .displayConnected, .wake:
            return [10]
        case .recordingStarted:
            return [1]
        }
    }

    var label: String {
        switch self {
        case .displayConnected:
            return "display connected"
        case .wake:
            return "system wake"
        case .recordingStarted:
            return "recording started"
        }
    }
}

/// Keep the obs-websocket event match exact so intermediate starting/stopping
/// states and unrelated output events cannot schedule capture recovery.
enum OBSRecordingCaptureRecoveryPolicy {
    static func shouldSchedule(
        eventType: String?,
        outputState: String?
    ) -> Bool {
        eventType == "RecordStateChanged"
            && outputState == "OBS_WEBSOCKET_OUTPUT_STARTED"
    }
}
