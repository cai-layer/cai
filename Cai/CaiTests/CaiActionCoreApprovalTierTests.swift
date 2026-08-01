import XCTest
import CaiActionCore

/// Which proposals get the acknowledgment checkbox.
///
/// Under-escalating is the failure that matters: an action that can run shell
/// slipping through with a one-click Approve is exactly the flow-state click
/// the tier system exists to prevent. The chain cases are the subtle ones, so
/// they carry most of the table.
final class ApprovalTierTests: XCTestCase {

    private struct TierCase {
        let label: String
        let action: ActionSnapshot
        let expected: [EscalationReason]
        let line: UInt
    }

    func testEscalationMatrix() {
        let cases: [TierCase] = [
            TierCase(
                label: "plain prompt action",
                action: CoreFixture.snapshot(type: .prompt),
                expected: [],
                line: #line
            ),
            TierCase(
                label: "shell action",
                action: CoreFixture.snapshot(type: .shell, value: "rm -rf ~/tmp"),
                expected: [.runsShellCommands],
                line: #line
            ),
            TierCase(
                label: "url action",
                action: CoreFixture.snapshot(type: .url, value: "https://example.com/?q=%s"),
                expected: [.sendsSelectionToURL],
                line: #line
            ),
            TierCase(
                label: "prompt that pastes over the selection",
                action: CoreFixture.snapshot(type: .prompt, autoReplaceSelection: true),
                expected: [.replacesSelection],
                line: #line
            ),
            TierCase(
                label: "shell that runs in the background",
                action: CoreFixture.snapshot(type: .shell, value: "say done", runInBackground: true),
                expected: [.runsShellCommands, .runsWithoutShowingOutput],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into a shell destination",
                action: CoreFixture.snapshot(next: [.action(name: "Run script")]),
                expected: [.runsShellCommands],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into an AppleScript destination",
                action: CoreFixture.snapshot(next: [.action(name: "Notes")]),
                expected: [.runsShellCommands],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into a webhook",
                action: CoreFixture.snapshot(next: [.action(name: "Slack")]),
                expected: [.sendsSelectionToURL],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into a deeplink",
                action: CoreFixture.snapshot(next: [.action(name: "Open in Cursor")]),
                expected: [.sendsSelectionToURL],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into Replace Selection",
                action: CoreFixture.snapshot(next: [.action(name: "Replace Selection")]),
                expected: [.replacesSelection],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into Copy to Clipboard",
                action: CoreFixture.snapshot(next: [.action(name: "Copy to Clipboard")]),
                expected: [],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into a built-in transform",
                action: CoreFixture.snapshot(next: [.action(name: "Summarize")]),
                expected: [],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into an inline LLM step",
                action: CoreFixture.snapshot(next: [.inlineLLM(directive: "shorten it")]),
                expected: [],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into an Apple Shortcut",
                action: CoreFixture.snapshot(next: [.appleShortcut(name: "Log to Notion")]),
                expected: [.runsShellCommands],
                line: #line
            ),
            TierCase(
                label: "prompt chaining into a name nothing resolves to",
                action: CoreFixture.snapshot(next: [.action(name: "Not installed")]),
                expected: [],
                line: #line
            ),
            TierCase(
                label: "every reason at once",
                action: CoreFixture.snapshot(
                    type: .shell,
                    value: "say hi",
                    autoReplaceSelection: true,
                    runInBackground: true,
                    next: [.action(name: "Slack")]
                ),
                expected: [.runsShellCommands, .sendsSelectionToURL, .replacesSelection, .runsWithoutShowingOutput],
                line: #line
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ApprovalClassifier.escalationReasons(for: testCase.action, known: CoreFixture.known),
                testCase.expected,
                testCase.label,
                line: testCase.line
            )
            XCTAssertEqual(
                ApprovalClassifier.tier(for: testCase.action, known: CoreFixture.known),
                testCase.expected.isEmpty ? .standard : .escalated,
                testCase.label,
                line: testCase.line
            )
        }
    }

    // MARK: - Chains that reference other actions

    func testEscalationFollowsAReferencedShortcutsOwnType() {
        let shellAction = CoreFixture.snapshot(id: CoreFixture.otherId, name: "Deploy", type: .shell, value: "./deploy.sh")
        let known = KnownActions(shortcuts: [shellAction], destinations: [], builtInActionNames: [])
        let innocent = CoreFixture.snapshot(name: "Tidy up", type: .prompt, next: [.action(name: "Deploy")])

        XCTAssertEqual(
            ApprovalClassifier.escalationReasons(for: innocent, known: known),
            [.runsShellCommands],
            "A prompt action whose chain reaches a shell action still runs shell."
        )
    }

    func testEscalationFollowsChainsTwoActionsDeep() {
        let deep = CoreFixture.snapshot(id: CoreFixture.otherId, name: "Deep", type: .shell, value: "./x.sh")
        let middle = CoreFixture.snapshot(id: UUID(), name: "Middle", type: .prompt, next: [.action(name: "Deep")])
        let known = KnownActions(shortcuts: [deep, middle], destinations: [], builtInActionNames: [])
        let top = CoreFixture.snapshot(name: "Top", type: .prompt, next: [.action(name: "Middle")])

        XCTAssertEqual(ApprovalClassifier.escalationReasons(for: top, known: known), [.runsShellCommands])
    }

    /// Names are not unique. A proposal named the same as an installed action
    /// must not be able to hide that action's risks behind the cycle guard.
    func testAChainStepSharingTheProposalsOwnNameStillEscalates() {
        let installedShell = ActionSnapshot(
            id: CoreFixture.otherId, name: "Deploy", type: .shell, value: "./deploy.sh"
        )
        let known = KnownActions(shortcuts: [installedShell])
        let proposal = ActionSnapshot(
            id: CoreFixture.changeId,
            name: "Deploy",
            type: .prompt,
            value: "Summarize the diff",
            next: [.action(name: "Deploy")]
        )

        XCTAssertEqual(
            ApprovalClassifier.escalationReasons(for: proposal, known: known),
            [.runsShellCommands],
            "The chain step resolves to the user's existing shell action, not to the proposal itself."
        )
    }

    func testCyclicChainTerminates() {
        let a = CoreFixture.snapshot(id: CoreFixture.targetId, name: "A", type: .prompt, next: [.action(name: "B")])
        let b = CoreFixture.snapshot(id: CoreFixture.otherId, name: "B", type: .prompt, next: [.action(name: "A")])
        let known = KnownActions(shortcuts: [a, b], destinations: [], builtInActionNames: [])

        XCTAssertEqual(ApprovalClassifier.escalationReasons(for: a, known: known), [])
    }

    func testSelfReferencingChainTerminates() {
        let loop = CoreFixture.snapshot(name: "Loop", type: .prompt, next: [.action(name: "Loop")])
        let known = KnownActions(shortcuts: [loop], destinations: [], builtInActionNames: [])

        XCTAssertEqual(ApprovalClassifier.escalationReasons(for: loop, known: known), [])
    }
}
