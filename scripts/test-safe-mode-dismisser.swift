// test-safe-mode-dismisser.swift — unit tests for SafeModeDialogDismisser.
//
// Covers the pure decision logic that identifies the OBS Safe Mode dialog
// and picks the right button to press. Uses a fake `DialogProbe` to avoid
// needing a real OBS process / Accessibility runtime.
//
// Run:
//   ./scripts/run-tests.sh
//
// Exit code is 0 on success, 1 on any failure. Prints a summary.

import Foundation

// MARK: - Fake probe

final class FakeDialogProbe: DialogProbe {
    /// Hard-coded snapshot of what "the OBS process's windows look like
    /// right now". Tests flip this between scenarios.
    var windowsToReturn: [AXElementSnapshot] = []
    /// Record of every `press(path:in:)` call so tests can assert the
    /// dismisser pressed the right button(s).
    var pressCalls: [(windowIndex: Int, path: [Int])] = []
    /// If true, `press` returns false to simulate AX failure.
    var simulatePressFailure: Bool = false

    func currentWindows() -> [AXElementSnapshot] {
        return windowsToReturn
    }

    func press(path: [Int], in windowIndex: Int) -> Bool {
        pressCalls.append((windowIndex, path))
        return !simulatePressFailure
    }
}

// MARK: - Convenience builders

func button(_ title: String) -> AXElementSnapshot {
    return AXElementSnapshot(
        role: "AXButton",
        roleDescription: "button",
        title: title,
        description: nil,
        value: nil,
        children: []
    )
}

func checkbox(_ title: String, checked: Bool = false) -> AXElementSnapshot {
    return AXElementSnapshot(
        role: "AXCheckBox",
        roleDescription: "checkbox",
        title: title,
        description: nil,
        value: checked ? "1" : "0",
        children: []
    )
}

func staticText(_ text: String) -> AXElementSnapshot {
    return AXElementSnapshot(
        role: "AXStaticText",
        roleDescription: "text",
        title: text,
        description: nil,
        value: text,
        children: []
    )
}

func window(title: String?, children: [AXElementSnapshot]) -> AXElementSnapshot {
    return AXElementSnapshot(
        role: "AXWindow",
        roleDescription: "window",
        title: title,
        description: nil,
        value: nil,
        children: children
    )
}

// MARK: - Assertion helpers (reused from test-retry-verify.swift conventions)

var dismisserTestFailures: [String] = []
var dismisserCurrentTestName: String = ""

func dExpect(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    if !condition {
        let msg = "  [\(dismisserCurrentTestName)] FAIL: \(message()) (line \(line))"
        dismisserTestFailures.append(msg)
        print(msg)
    }
}

func dExpectEqual<T: Equatable>(
    _ lhs: T,
    _ rhs: T,
    _ label: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    dExpect(lhs == rhs, "\(label): expected \(rhs), got \(lhs)", file: file, line: line)
}

// MARK: - Decision-logic tests

func test_decide_noSafeModeText_keepsWatching() {
    dismisserCurrentTestName = "decide_noSafeModeText_keepsWatching"
    let w = window(title: "OBS 32.1.1", children: [
        staticText("Program"),
        button("Start Recording")
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [w])
    if case .keepWatching = decision { /* ok */ } else {
        dExpect(false, "expected .keepWatching, got \(decision)")
    }
}

func test_decide_standardDialog_findsLaunchNormallyButton() {
    dismisserCurrentTestName = "decide_standardDialog_findsLaunchNormallyButton"
    let dialog = window(title: "OBS Studio", children: [
        staticText("OBS Studio was not properly shut down the last time it was used."),
        staticText("OBS is able to run in Safe Mode to help diagnose the issue."),
        button("Launch Normally"),
        button("Launch in Safe Mode"),
        button("Cancel")
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [dialog])
    switch decision {
    case .dismiss(let idx, let paths):
        dExpectEqual(idx, 0, "window index")
        dExpectEqual(paths.count, 1, "one press (just the button)")
        // Children: [static, static, btn, btn, btn]. "Launch Normally" is index 2.
        dExpectEqual(paths.first ?? [], [2], "path to Launch Normally button")
    default:
        dExpect(false, "expected .dismiss, got \(decision)")
    }
}

func test_decide_picksCheckboxThenButton_whenRememberChoicePresent() {
    dismisserCurrentTestName = "decide_picksCheckboxThenButton_whenRememberChoicePresent"
    let dialog = window(title: "OBS Studio", children: [
        staticText("Safe Mode"),
        checkbox("Don't ask me again"),
        button("Launch Normally"),
        button("Launch in Safe Mode")
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [dialog])
    switch decision {
    case .dismiss(_, let paths):
        dExpectEqual(paths.count, 2, "checkbox + button")
        dExpectEqual(paths[0], [1], "checkbox path (child index 1)")
        dExpectEqual(paths[1], [2], "button path (child index 2)")
    default:
        dExpect(false, "expected .dismiss, got \(decision)")
    }
}

func test_decide_recognisesRunNormallyPhrasing() {
    dismisserCurrentTestName = "decide_recognisesRunNormallyPhrasing"
    let dialog = window(title: "OBS Studio", children: [
        staticText("Safe Mode recovery"),
        button("Run Normally"),
        button("Run in Safe Mode")
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [dialog])
    switch decision {
    case .dismiss(_, let paths):
        dExpectEqual(paths.first ?? [], [1], "Run Normally at index 1")
    default:
        dExpect(false, "expected .dismiss, got \(decision)")
    }
}

func test_decide_neverPicksSafeModeButtonByAccident() {
    dismisserCurrentTestName = "decide_neverPicksSafeModeButtonByAccident"
    // Dialog where the ONLY button label containing "launch" is "Launch in
    // Safe Mode". Must not dismiss (dumps tree instead).
    let dialog = window(title: "OBS Studio", children: [
        staticText("Safe Mode"),
        button("Launch in Safe Mode"),
        button("Cancel")
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [dialog])
    switch decision {
    case .dumpUnknownTree(let idx):
        dExpectEqual(idx, 0, "window index")
    default:
        dExpect(false, "expected .dumpUnknownTree (never press safe-mode button), got \(decision)")
    }
}

func test_decide_ignoresUnrelatedWindow_findsSafeModeInNext() {
    dismisserCurrentTestName = "decide_ignoresUnrelatedWindow_findsSafeModeInNext"
    let main = window(title: "OBS 32.1.1 - Profile: Default", children: [
        staticText("Scene"),
        button("Start Streaming")
    ])
    let dialog = window(title: "OBS Studio", children: [
        staticText("Safe Mode"),
        button("Launch Normally"),
        button("Launch in Safe Mode")
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [main, dialog])
    switch decision {
    case .dismiss(let idx, let paths):
        dExpectEqual(idx, 1, "window index = 1 (second window)")
        dExpectEqual(paths.first ?? [], [1], "Launch Normally at index 1")
    default:
        dExpect(false, "expected .dismiss on second window, got \(decision)")
    }
}

func test_decide_buttonLabelInAXDescription_whenTitleEmpty() {
    dismisserCurrentTestName = "decide_buttonLabelInAXDescription_whenTitleEmpty"
    // QMessageBox quirk: AXTitle is present but empty, real label lives in
    // AXDescription. We must still recognise the button.
    let buttonWithDescOnly = AXElementSnapshot(
        role: "AXButton", roleDescription: "button",
        title: "", description: "Launch Normally", value: nil, children: []
    )
    let safeModeBtn = AXElementSnapshot(
        role: "AXButton", roleDescription: "button",
        title: "", description: "Launch in Safe Mode", value: nil, children: []
    )
    let dialog = window(title: "OBS Studio", children: [
        staticText("Safe Mode"),
        buttonWithDescOnly,
        safeModeBtn
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [dialog])
    switch decision {
    case .dismiss(_, let paths):
        dExpectEqual(paths.first ?? [], [1], "Launch Normally identified via AXDescription")
    default:
        dExpect(false, "expected .dismiss when label lives in AXDescription, got \(decision)")
    }
}

func test_decide_nestedButtons_foundByDepthFirstWalk() {
    dismisserCurrentTestName = "decide_nestedButtons_foundByDepthFirstWalk"
    // Real OBS / Qt dialogs often wrap buttons in an AXGroup.
    let buttonGroup = AXElementSnapshot(
        role: "AXGroup", roleDescription: "group",
        title: nil, description: nil, value: nil,
        children: [button("Launch Normally"), button("Launch in Safe Mode")]
    )
    let dialog = window(title: "OBS Studio", children: [
        staticText("Safe Mode recovery"),
        buttonGroup
    ])
    let decision = SafeModeDismissalLogic.decide(windows: [dialog])
    switch decision {
    case .dismiss(_, let paths):
        // child 1 (the group) -> child 0 (Launch Normally)
        dExpectEqual(paths.first ?? [], [1, 0], "nested path")
    default:
        dExpect(false, "expected .dismiss, got \(decision)")
    }
}

// MARK: - Engine tick tests

func test_tick_dismissesSuccessfully() {
    dismisserCurrentTestName = "tick_dismissesSuccessfully"
    let probe = FakeDialogProbe()
    probe.windowsToReturn = [
        window(title: "OBS Studio", children: [
            staticText("Safe Mode"),
            button("Launch Normally"),
            button("Launch in Safe Mode")
        ])
    ]
    var logs: [String] = []
    let result = SafeModeDismisserEngine.tick(probe: probe, log: { logs.append($0) })

    dExpectEqual(result, .dismissed, "tick result")
    dExpectEqual(probe.pressCalls.count, 1, "one press")
    dExpectEqual(probe.pressCalls.first?.windowIndex ?? -1, 0, "window 0")
    dExpectEqual(probe.pressCalls.first?.path ?? [], [1], "path")
    dExpect(logs.contains { $0.contains("found OBS Safe Mode dialog") }, "logs discovery")
}

func test_tick_keepsPollingWhenNoDialog() {
    dismisserCurrentTestName = "tick_keepsPollingWhenNoDialog"
    let probe = FakeDialogProbe()
    probe.windowsToReturn = []
    var logs: [String] = []
    let result = SafeModeDismisserEngine.tick(probe: probe, log: { logs.append($0) })
    dExpectEqual(result, .keepPolling, "no windows yet")
    dExpectEqual(probe.pressCalls.count, 0, "no press")
}

func test_tick_pressesCheckboxBeforeButton() {
    dismisserCurrentTestName = "tick_pressesCheckboxBeforeButton"
    let probe = FakeDialogProbe()
    probe.windowsToReturn = [
        window(title: "OBS Studio", children: [
            staticText("Safe Mode"),
            checkbox("Don't ask me again"),
            button("Launch Normally"),
            button("Launch in Safe Mode")
        ])
    ]
    var logs: [String] = []
    let result = SafeModeDismisserEngine.tick(probe: probe, log: { logs.append($0) })
    dExpectEqual(result, .dismissed, "tick result")
    dExpectEqual(probe.pressCalls.count, 2, "two presses")
    dExpectEqual(probe.pressCalls[0].path, [1], "checkbox first")
    dExpectEqual(probe.pressCalls[1].path, [2], "button second")
}

func test_tick_abandonsOnAmbiguousDialog() {
    dismisserCurrentTestName = "tick_abandonsOnAmbiguousDialog"
    let probe = FakeDialogProbe()
    probe.windowsToReturn = [
        window(title: "OBS Studio", children: [
            staticText("Safe Mode"),
            button("Launch in Safe Mode"),
            button("Cancel")
        ])
    ]
    var logs: [String] = []
    let result = SafeModeDismisserEngine.tick(probe: probe, log: { logs.append($0) })
    dExpectEqual(result, .abandoned, "tick result")
    dExpectEqual(probe.pressCalls.count, 0, "no press")
    dExpect(logs.contains { $0.contains("dumping AX tree") }, "logs AX tree dump")
}

func test_tick_abandonsIfPressFails() {
    dismisserCurrentTestName = "tick_abandonsIfPressFails"
    let probe = FakeDialogProbe()
    probe.simulatePressFailure = true
    probe.windowsToReturn = [
        window(title: "OBS Studio", children: [
            staticText("Safe Mode"),
            button("Launch Normally")
        ])
    ]
    var logs: [String] = []
    let result = SafeModeDismisserEngine.tick(probe: probe, log: { logs.append($0) })
    dExpectEqual(result, .abandoned, "tick abandoned on press failure")
    dExpectEqual(probe.pressCalls.count, 1, "tried once")
}

// MARK: - Predicate unit checks

func test_predicate_launchNormallyAliases() {
    dismisserCurrentTestName = "predicate_launchNormallyAliases"
    dExpect(SafeModeDismissalLogic.looksLikeLaunchNormallyButton("Launch Normally"), "Launch Normally")
    dExpect(SafeModeDismissalLogic.looksLikeLaunchNormallyButton("Run Normally"), "Run Normally")
    dExpect(SafeModeDismissalLogic.looksLikeLaunchNormallyButton("Start Normally"), "Start Normally")
    dExpect(SafeModeDismissalLogic.looksLikeLaunchNormallyButton("Continue Normally"), "Continue Normally")
    dExpect(SafeModeDismissalLogic.looksLikeLaunchNormallyButton("continue"), "plain continue")
    dExpect(!SafeModeDismissalLogic.looksLikeLaunchNormallyButton("Launch in Safe Mode"), "must NOT match safe mode launch")
    dExpect(!SafeModeDismissalLogic.looksLikeLaunchNormallyButton("Cancel"), "Cancel")
}

func test_predicate_rememberChoiceAliases() {
    dismisserCurrentTestName = "predicate_rememberChoiceAliases"
    dExpect(SafeModeDismissalLogic.looksLikeRememberChoiceCheckbox("Don't ask me again"), "don't ask")
    dExpect(SafeModeDismissalLogic.looksLikeRememberChoiceCheckbox("Do not ask again"), "do not ask")
    dExpect(SafeModeDismissalLogic.looksLikeRememberChoiceCheckbox("Remember my choice"), "remember choice")
    dExpect(SafeModeDismissalLogic.looksLikeRememberChoiceCheckbox("Don't show this again"), "don't show")
    dExpect(!SafeModeDismissalLogic.looksLikeRememberChoiceCheckbox("Enable Studio Mode"), "unrelated")
}

// MARK: - Runner

@main
struct SafeModeDismisserTestRunner {
    static func main() {
        let tests: [(String, () -> Void)] = [
            ("decide_noSafeModeText_keepsWatching", test_decide_noSafeModeText_keepsWatching),
            ("decide_standardDialog_findsLaunchNormallyButton", test_decide_standardDialog_findsLaunchNormallyButton),
            ("decide_picksCheckboxThenButton_whenRememberChoicePresent", test_decide_picksCheckboxThenButton_whenRememberChoicePresent),
            ("decide_recognisesRunNormallyPhrasing", test_decide_recognisesRunNormallyPhrasing),
            ("decide_neverPicksSafeModeButtonByAccident", test_decide_neverPicksSafeModeButtonByAccident),
            ("decide_ignoresUnrelatedWindow_findsSafeModeInNext", test_decide_ignoresUnrelatedWindow_findsSafeModeInNext),
            ("decide_buttonLabelInAXDescription_whenTitleEmpty", test_decide_buttonLabelInAXDescription_whenTitleEmpty),
            ("decide_nestedButtons_foundByDepthFirstWalk", test_decide_nestedButtons_foundByDepthFirstWalk),
            ("tick_dismissesSuccessfully", test_tick_dismissesSuccessfully),
            ("tick_keepsPollingWhenNoDialog", test_tick_keepsPollingWhenNoDialog),
            ("tick_pressesCheckboxBeforeButton", test_tick_pressesCheckboxBeforeButton),
            ("tick_abandonsOnAmbiguousDialog", test_tick_abandonsOnAmbiguousDialog),
            ("tick_abandonsIfPressFails", test_tick_abandonsIfPressFails),
            ("predicate_launchNormallyAliases", test_predicate_launchNormallyAliases),
            ("predicate_rememberChoiceAliases", test_predicate_rememberChoiceAliases)
        ]

        print("== SafeModeDialogDismisser unit tests ==")
        var perTestFailures: [(String, [String])] = []
        for (name, fn) in tests {
            let before = dismisserTestFailures.count
            fn()
            let newFailures = Array(dismisserTestFailures[before...])
            if newFailures.isEmpty {
                print("  PASS: \(name)")
            } else {
                print("  FAIL: \(name) (\(newFailures.count) failure(s))")
                perTestFailures.append((name, newFailures))
            }
        }

        if dismisserTestFailures.isEmpty {
            print("\nAll \(tests.count) tests passed.")
            exit(0)
        } else {
            print("\n\(dismisserTestFailures.count) FAILURES across \(tests.count) tests:")
            for (name, failures) in perTestFailures {
                print("  \(name):")
                for f in failures { print("    \(f)") }
            }
            exit(1)
        }
    }
}
