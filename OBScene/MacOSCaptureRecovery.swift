import Foundation

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
    case alreadyHealthy
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

/// Pure orchestration for recovering stopped OBS macOS Screen Capture inputs.
///
/// OBS exposes `reactivate_capture` only while it marks a ScreenCaptureKit
/// stream as failed. Pressing it in that state returns success (100). Code 604
/// means only that the property button is disabled; it is the common healthy
/// response, but OBS 32.2.0 can also return it for a black missing-display
/// target. Wake/display recovery therefore treats 604 as a safe no-op on the
/// immediate probe and forces one settings-driven rebuild on its final retry.
enum MacOSCaptureRecoveryEngine {
    static let inputKind = "screen_capture"
    static let propertyName = "reactivate_capture"
    static let alreadyHealthyCode = 604

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

            let lock = NSLock()
            var remaining = inputNames.count
            var entries: [MacOSCaptureRecoveryEntry] = []

            for inputName in inputNames {
                dependencies.reactivate(inputName) { response in
                    let entry = MacOSCaptureRecoveryEntry(
                        inputName: inputName,
                        outcome: classifyReactivation(response)
                    )

                    var finalEntries: [MacOSCaptureRecoveryEntry]?
                    lock.lock()
                    entries.append(entry)
                    remaining -= 1
                    if remaining == 0 {
                        finalEntries = entries.sorted { $0.inputName < $1.inputName }
                    }
                    lock.unlock()

                    if let finalEntries {
                        completion(.completed(finalEntries))
                    }
                }
            }
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
        if response.code == alreadyHealthyCode {
            return .alreadyHealthy
        }
        return .failed(code: response.code, comment: response.comment)
    }
}

/// Recovery is event-driven and bounded. Every event gets an immediate probe;
/// wake/display events get one short retry because ScreenCaptureKit may lag the
/// corresponding macOS notification while displays finish coming online.
enum MacOSCaptureRecoveryTrigger {
    case wake
    case displayChange
    case sceneSelectionSettled

    var delays: [TimeInterval] {
        switch self {
        case .wake:
            return [0, 2]
        case .displayChange:
            return [0, 1]
        case .sceneSelectionSettled:
            return [0]
        }
    }

    var label: String {
        switch self {
        case .wake: return "wake"
        case .displayChange: return "display change"
        case .sceneSelectionSettled: return "scene selection"
        }
    }

    /// A stopped source normally exposes `reactivate_capture`. OBS can also
    /// load an unavailable display target as a black source while reporting
    /// that button disabled (604). On the final wake/display attempt, force
    /// one settings-driven stream rebuild to cover that second state.
    var forceReinitializeOnFinalAttempt: Bool {
        switch self {
        case .wake, .displayChange:
            return true
        case .sceneSelectionSettled:
            return false
        }
    }
}
