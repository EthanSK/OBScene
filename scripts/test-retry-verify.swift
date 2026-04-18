// test-retry-verify.swift — unit tests for VerifiedSetEngine.
//
// Covers the set-then-verify-then-retry state machine used for OBS profile
// and scene-collection switches. Uses a fake clock + synchronous scheduler
// so the tests run in milliseconds instead of seconds.
//
// Run:
//   ./scripts/run-tests.sh
//
// Exit code is 0 on success, 1 on any failure. Prints a summary to stdout.

import Foundation

// Because this script compiles VerifiedSetEngine.swift alongside the test
// source with `#sourceLocation`-style includes, we just paste-import by
// reading the file text at runtime. Simpler approach: include the file
// contents directly below via a macro-free copy of the types we need.
//
// Swift's script mode doesn't support "include another file" natively, so
// we compile this script via:  swift <engine.swift> <this-file>.swift
// See `run_tests` at the bottom if invoked with no engine path.

// MARK: - Fake clock + scheduler
//
// The engine calls `deps.schedule(delay) { ... }` for every wait (poll and
// backoff). Tests wrap `schedule` in a priority-queue by `fire_at` time and
// advance the clock to the next scheduled event synchronously. That turns
// 8-second timeouts and 4-second backoffs into O(1) instant steps.

final class FakeClock {
    private(set) var now: Date = Date(timeIntervalSince1970: 0)
    /// Scheduled work items sorted by fire time.
    private var pending: [(Date, () -> Void)] = []

    func date() -> Date { now }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        let fireAt = now.addingTimeInterval(max(0, delay))
        pending.append((fireAt, work))
        pending.sort { $0.0 < $1.0 }
    }

    /// Run all scheduled work in order, advancing `now` to each fire time.
    /// Continues until the queue is empty OR `stop` is set true.
    func runUntilIdle(maxSteps: Int = 10_000) {
        var steps = 0
        while !pending.isEmpty {
            steps += 1
            if steps > maxSteps {
                fatalError("FakeClock runaway: more than \(maxSteps) scheduled events — infinite loop?")
            }
            let (fireAt, work) = pending.removeFirst()
            if fireAt > now { now = fireAt }
            work()
        }
    }
}

// MARK: - Test harness

final class FakeOBS {
    var isConnected: Bool = true
    /// List of known profile/collection names.
    var known: [String] = []
    /// What OBS reports as "current" when `fetchCurrent` is called.
    var current: String? = nil
    /// Record of every `apply(target)` invocation.
    var applyCalls: [String] = []
    /// Record of every `fetchCurrent` invocation.
    var fetchCurrentCalls: Int = 0
    /// Log buffer populated by the engine.
    var logs: [String] = []

    init(isConnected: Bool = true, known: [String] = [], current: String? = nil) {
        self.isConnected = isConnected
        self.known = known
        self.current = current
    }
}

/// Helper that wires a FakeOBS up to VerifiedSetDependencies / FakeClock.
/// `applyBehaviour` controls what happens on each apply call (defaults to
/// "apply lands immediately — next fetchCurrent returns target").
func makeDeps(
    obs: FakeOBS,
    clock: FakeClock,
    applyBehaviour: @escaping (_ target: String, _ attempt: Int, _ obs: FakeOBS) -> Void = { target, _, obs in
        obs.current = target
    }
) -> VerifiedSetDependencies {
    var applyCount = 0
    return VerifiedSetDependencies(
        isConnected: { obs.isConnected },
        knownList: { obs.known },
        apply: { target, done in
            applyCount += 1
            obs.applyCalls.append(target)
            applyBehaviour(target, applyCount, obs)
            clock.schedule(0) { done() }
        },
        fetchCurrent: { done in
            obs.fetchCurrentCalls += 1
            let v = obs.current
            clock.schedule(0) { done(v) }
        },
        log: { msg in obs.logs.append(msg) },
        schedule: { delay, work in clock.schedule(delay, work) },
        clock: { clock.date() }
    )
}

// MARK: - Assertion helpers

var testFailures: [String] = []
var currentTestName: String = ""

func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    if !condition {
        let msg = "  [\(currentTestName)] FAIL: \(message()) (line \(line))"
        testFailures.append(msg)
        print(msg)
    }
}

func expectEqual<T: Equatable>(
    _ lhs: T,
    _ rhs: T,
    _ label: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    expect(lhs == rhs, "\(label): expected \(rhs), got \(lhs)", file: file, line: line)
}

// MARK: - Tests

/// Test config with tiny timeouts / backoffs so the fake clock doesn't
/// have to burn through thousands of events. Still exercises the same
/// state transitions.
let testConfig = VerifiedSetConfig(
    maxAttempts: 3,
    timeout: 1.0,
    pollInterval: 0.1,
    retryBackoffs: [0.1, 0.2, 0.4]
)

func test_happyPath_firstAttemptSucceeds() {
    currentTestName = "happyPath_firstAttemptSucceeds"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: true, known: ["Streaming", "Recording"], current: "Recording")

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "Streaming",
        config: testConfig,
        deps: makeDeps(obs: obs, clock: clock)
    ) { r in result = r }

    clock.runUntilIdle()

    expect(result != nil, "completion fired")
    if case .success = result { /* ok */ } else { expect(false, "expected .success, got \(String(describing: result))") }
    expectEqual(obs.applyCalls, ["Streaming"], "single apply")
    expect(obs.fetchCurrentCalls >= 2, "verified by polling (calls=\(obs.fetchCurrentCalls))")
}

func test_alreadyActive_skipsApply() {
    currentTestName = "alreadyActive_skipsApply"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: true, known: ["Streaming"], current: "Streaming")

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "Streaming",
        config: testConfig,
        deps: makeDeps(obs: obs, clock: clock)
    ) { r in result = r }

    clock.runUntilIdle()

    if case .success = result { /* ok */ } else { expect(false, "expected .success") }
    expectEqual(obs.applyCalls.count, 0, "no apply when already active")
    expect(obs.logs.contains { $0.contains("already active") }, "logs already-active")
}

func test_notFound_failsFast() {
    currentTestName = "notFound_failsFast"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: true, known: ["Streaming", "Recording"], current: "Recording")

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "Nonexistent",
        config: testConfig,
        deps: makeDeps(obs: obs, clock: clock)
    ) { r in result = r }

    clock.runUntilIdle()

    switch result {
    case .failure(.notFound(let name, let available)):
        expectEqual(name, "Nonexistent", "name")
        expectEqual(available, ["Streaming", "Recording"], "available")
    default:
        expect(false, "expected .notFound, got \(String(describing: result))")
    }
    expectEqual(obs.applyCalls.count, 0, "no apply when notFound")
}

func test_notConnected_failsFast() {
    currentTestName = "notConnected_failsFast"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: false)

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "Streaming",
        config: testConfig,
        deps: makeDeps(obs: obs, clock: clock)
    ) { r in result = r }

    clock.runUntilIdle()

    switch result {
    case .failure(.notConnected):
        break // ok
    default:
        expect(false, "expected .notConnected, got \(String(describing: result))")
    }
    expectEqual(obs.applyCalls.count, 0, "no apply when disconnected")
}

func test_verificationFailsFirstTime_retrySucceeds() {
    currentTestName = "verificationFailsFirstTime_retrySucceeds"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: true, known: ["Streaming", "Recording"], current: "Recording")

    // Scripted: first apply does NOT update current (simulates OBS dropping
    // the request). Second apply succeeds.
    let deps = makeDeps(obs: obs, clock: clock) { target, attempt, obs in
        if attempt >= 2 {
            obs.current = target
        }
        // else: leave `current` unchanged to simulate silent failure.
    }

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "Streaming",
        config: testConfig,
        deps: deps
    ) { r in result = r }

    clock.runUntilIdle()

    if case .success = result { /* ok */ } else { expect(false, "expected .success, got \(String(describing: result))") }
    expectEqual(obs.applyCalls.count, 2, "retried once")
    expect(obs.logs.contains { $0.contains("attempt 1 of 3") }, "logs attempt 1")
    expect(obs.logs.contains { $0.contains("attempt 2 of 3") }, "logs attempt 2")
    expect(obs.logs.contains { $0.contains("retrying in") }, "logs backoff")
    expect(obs.logs.contains { $0.contains("Verified: profile now = 'Streaming'") }, "logs verified")
}

func test_allAttemptsFail_verificationFailed() {
    currentTestName = "allAttemptsFail_verificationFailed"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: true, known: ["Streaming", "Recording"], current: "Recording")

    // Apply never lands.
    let deps = makeDeps(obs: obs, clock: clock) { _, _, _ in /* no-op */ }

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "Streaming",
        config: testConfig,
        deps: deps
    ) { r in result = r }

    clock.runUntilIdle()

    switch result {
    case .failure(.verificationFailed(let target, let current, let attempts)):
        expectEqual(target, "Streaming", "target")
        expectEqual(current, "Recording", "current reported")
        expectEqual(attempts, 3, "attempts == maxAttempts")
    default:
        expect(false, "expected .verificationFailed, got \(String(describing: result))")
    }
    expectEqual(obs.applyCalls.count, 3, "3 apply calls")
}

func test_emptyTarget_noOp() {
    currentTestName = "emptyTarget_noOp"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: true)

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "",
        config: testConfig,
        deps: makeDeps(obs: obs, clock: clock)
    ) { r in result = r }

    clock.runUntilIdle()

    if case .success = result { /* ok */ } else { expect(false, "expected .success on empty") }
    expectEqual(obs.applyCalls.count, 0, "no apply on empty target")
}

func test_disconnectMidRetry_failsFast() {
    currentTestName = "disconnectMidRetry_failsFast"
    let clock = FakeClock()
    let obs = FakeOBS(isConnected: true, known: ["A", "B"], current: "A")

    // Apply doesn't land; after first attempt fails verification, disconnect.
    let deps = makeDeps(obs: obs, clock: clock) { _, attempt, obs in
        if attempt == 1 {
            // Simulate WebSocket drop between attempt 1 and retry.
            obs.isConnected = false
        }
    }

    var result: Result<Void, VerifiedSetError>?
    VerifiedSetEngine.run(
        kind: "profile",
        target: "B",
        config: testConfig,
        deps: deps
    ) { r in result = r }

    clock.runUntilIdle()

    switch result {
    case .failure(.notConnected):
        break // ok
    default:
        expect(false, "expected .notConnected on mid-retry drop, got \(String(describing: result))")
    }
    expectEqual(obs.applyCalls.count, 1, "only one apply before disconnect detected")
}

// MARK: - Runner

@main
struct TestRunner {
    static func main() {
        let tests: [(String, () -> Void)] = [
            ("happyPath_firstAttemptSucceeds", test_happyPath_firstAttemptSucceeds),
            ("alreadyActive_skipsApply", test_alreadyActive_skipsApply),
            ("notFound_failsFast", test_notFound_failsFast),
            ("notConnected_failsFast", test_notConnected_failsFast),
            ("verificationFailsFirstTime_retrySucceeds", test_verificationFailsFirstTime_retrySucceeds),
            ("allAttemptsFail_verificationFailed", test_allAttemptsFail_verificationFailed),
            ("emptyTarget_noOp", test_emptyTarget_noOp),
            ("disconnectMidRetry_failsFast", test_disconnectMidRetry_failsFast)
        ]

        print("== VerifiedSetEngine unit tests ==")
        var perTestFailures: [(String, [String])] = []
        for (name, fn) in tests {
            let before = testFailures.count
            fn()
            let newFailures = Array(testFailures[before...])
            if newFailures.isEmpty {
                print("  PASS: \(name)")
            } else {
                print("  FAIL: \(name) (\(newFailures.count) failure(s))")
                perTestFailures.append((name, newFailures))
            }
        }

        if testFailures.isEmpty {
            print("\nAll \(tests.count) tests passed.")
            exit(0)
        } else {
            print("\n\(testFailures.count) FAILURES across \(tests.count) tests:")
            for (name, failures) in perTestFailures {
                print("  \(name):")
                for f in failures { print("    \(f)") }
            }
            exit(1)
        }
    }
}
