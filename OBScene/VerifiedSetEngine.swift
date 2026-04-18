import Foundation

// MARK: - Verified-set engine
//
// A pure, deterministic state machine for "set a value in OBS, verify it
// landed, retry on failure". Lives in its own file so that it can be
// compiled into a standalone XCTest/Swift-run unit test alongside this
// source (see `scripts/test-retry-verify.swift`). Depends only on
// Foundation — no AppKit, no OBSWebSocketManager instance state.
//
// Bug fix 2026-04-18: `SetCurrentProfile` is unreliable over the OBS
// WebSocket v5 request channel — OBS ACKs the request before the profile
// actually switches, and sometimes never switches at all. We need an
// explicit verify-and-retry loop instead of trusting the ACK.

enum VerifiedSetError: Error, Equatable {
    /// WebSocket is not connected. Fail fast.
    case notConnected
    /// Target doesn't exist in OBS's known list. Fail fast.
    case notFound(name: String, available: [String])
    /// After N attempts, OBS's current value still didn't match the target.
    case verificationFailed(target: String, current: String?, attempts: Int)
}

/// Callback type used by the engine to log progress. Supplied by callers so
/// they can route to the platform-appropriate log (`print` + `ActivityLog`
/// in the app, a buffer in tests).
typealias VerifiedSetLogger = (String) -> Void

/// Schedule a block to run after `delay` seconds on the main queue. Swapped
/// out in tests for a fake clock that runs the block synchronously.
typealias VerifiedSetScheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

/// Default real scheduler: `DispatchQueue.main.asyncAfter`.
let realMainQueueScheduler: VerifiedSetScheduler = { delay, work in
    if delay <= 0 {
        DispatchQueue.main.async(execute: work)
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Default "now" provider. Tests inject a fake that advances with the
/// fake clock.
typealias VerifiedSetClock = () -> Date

/// Engine configuration. The defaults match what the app uses; tests tweak
/// the timeouts to shrink runtime.
struct VerifiedSetConfig {
    /// Hard cap on total attempts (initial + retries).
    var maxAttempts: Int = 3
    /// Per-attempt set+verify deadline.
    var timeout: TimeInterval = 8.0
    /// Interval between successive `fetchCurrent` polls inside one attempt.
    var pollInterval: TimeInterval = 0.25
    /// Delay before each retry. `retryBackoffs[attempt - 1]` is the delay
    /// BEFORE attempt `attempt+1` (i.e. after attempt `attempt` fails).
    var retryBackoffs: [TimeInterval] = [1.0, 2.0, 4.0]
}

/// Dependencies the engine calls out to. All are closures so tests can stub
/// them without owning an OBSWebSocketManager.
struct VerifiedSetDependencies {
    /// Returns true iff the WebSocket is currently up.
    var isConnected: () -> Bool
    /// Returns the last-known list of profiles / collections. Empty means
    /// "unknown" and the not-found fast-fail is skipped.
    var knownList: () -> [String]
    /// Issue the set request. Call `done` when OBS ACKs or times out.
    var apply: (_ target: String, _ done: @escaping () -> Void) -> Void
    /// Ask OBS for the current value. Call `done(name?)`.
    var fetchCurrent: (_ done: @escaping (String?) -> Void) -> Void
    /// Logger (info-level messages).
    var log: VerifiedSetLogger
    /// Scheduler used for backoff + poll waits. Default is the main queue.
    var schedule: VerifiedSetScheduler = realMainQueueScheduler
    /// Clock used for deadline comparisons.
    var clock: VerifiedSetClock = { Date() }
}

enum VerifiedSetEngine {
    /// Entry point. Returns via `completion` on whatever queue the scheduler
    /// dispatches on (main queue in the app, synchronous in fake-clock tests).
    static func run(
        kind: String,
        target: String,
        config: VerifiedSetConfig,
        deps: VerifiedSetDependencies,
        completion: @escaping (Result<Void, VerifiedSetError>) -> Void
    ) {
        if target.isEmpty {
            deps.schedule(0) { completion(.success(())) }
            return
        }

        guard deps.isConnected() else {
            deps.log("Cannot set \(kind) '\(target)' — WebSocket not connected")
            deps.schedule(0) { completion(.failure(.notConnected)) }
            return
        }

        deps.fetchCurrent { initialCurrent in
            if let current = initialCurrent, current == target {
                deps.log("\(kind.capitalized) '\(target)' already active — skipping")
                deps.schedule(0) { completion(.success(())) }
                return
            }

            let known = deps.knownList()
            if !known.isEmpty, !known.contains(target) {
                deps.log("\(kind.capitalized) '\(target)' not found in OBS. Available: \(known)")
                deps.schedule(0) {
                    completion(.failure(.notFound(name: target, available: known)))
                }
                return
            }

            runAttempt(
                kind: kind,
                target: target,
                attempt: 1,
                lastObservedCurrent: initialCurrent,
                config: config,
                deps: deps,
                completion: completion
            )
        }
    }

    private static func runAttempt(
        kind: String,
        target: String,
        attempt: Int,
        lastObservedCurrent: String?,
        config: VerifiedSetConfig,
        deps: VerifiedSetDependencies,
        completion: @escaping (Result<Void, VerifiedSetError>) -> Void
    ) {
        guard deps.isConnected() else {
            deps.log("\(kind.capitalized) set aborted — WebSocket disconnected mid-retry")
            deps.schedule(0) { completion(.failure(.notConnected)) }
            return
        }

        deps.log("Setting \(kind) to '\(target)' (attempt \(attempt) of \(config.maxAttempts))")

        deps.apply(target) {
            let deadline = deps.clock().addingTimeInterval(config.timeout)
            pollUntilVerified(
                kind: kind,
                target: target,
                deadline: deadline,
                lastObservedCurrent: lastObservedCurrent,
                config: config,
                deps: deps
            ) { verified, current in
                if verified {
                    deps.log("Verified: \(kind) now = '\(target)'")
                    deps.schedule(0) { completion(.success(())) }
                    return
                }

                if attempt >= config.maxAttempts {
                    deps.log("Failed to change \(kind) to '\(target)' after \(attempt) attempts — current: '\(current ?? "<unknown>")'")
                    deps.schedule(0) {
                        completion(.failure(.verificationFailed(
                            target: target,
                            current: current,
                            attempts: attempt
                        )))
                    }
                    return
                }

                let backoffIdx = min(attempt - 1, config.retryBackoffs.count - 1)
                let backoff = config.retryBackoffs[backoffIdx]
                deps.log("Verification failed for \(kind) '\(target)' (got '\(current ?? "<none>")'), retrying in \(backoff)s")

                deps.schedule(backoff) {
                    runAttempt(
                        kind: kind,
                        target: target,
                        attempt: attempt + 1,
                        lastObservedCurrent: current,
                        config: config,
                        deps: deps,
                        completion: completion
                    )
                }
            }
        }
    }

    private static func pollUntilVerified(
        kind: String,
        target: String,
        deadline: Date,
        lastObservedCurrent: String?,
        config: VerifiedSetConfig,
        deps: VerifiedSetDependencies,
        done: @escaping (Bool, String?) -> Void
    ) {
        deps.fetchCurrent { current in
            if let current = current, current == target {
                done(true, current)
                return
            }
            let latest = current ?? lastObservedCurrent
            if deps.clock() >= deadline {
                done(false, latest)
                return
            }
            deps.schedule(config.pollInterval) {
                pollUntilVerified(
                    kind: kind,
                    target: target,
                    deadline: deadline,
                    lastObservedCurrent: latest,
                    config: config,
                    deps: deps,
                    done: done
                )
            }
        }
    }
}
