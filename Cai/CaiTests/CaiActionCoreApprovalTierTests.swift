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
                label: "shell reaching for a secret",
                action: CoreFixture.snapshot(
                    type: .shell,
                    value: "curl -H \"Bearer {{secrets.NOTION_API_TOKEN}}\" https://api.notion.com"
                ),
                expected: [.runsShellCommands, .referencesSecrets],
                line: #line
            ),
            TierCase(
                label: "prompt mentioning a secret still flags it (refused at execution, but the approval must not undersell)",
                action: CoreFixture.snapshot(type: .prompt, value: "Use {{secrets.NOTION_API_TOKEN}}"),
                expected: [.referencesSecrets],
                line: #line
            ),
            TierCase(
                label: "bare uppercase placeholder is an ordinary variable, not a secret",
                action: CoreFixture.snapshot(type: .shell, value: "echo {{API_KEY}}"),
                expected: [.runsShellCommands],
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
                expected: [.chainsToUnknownAction],
                line: #line
            ),
            TierCase(
                label: "every reason at once",
                action: CoreFixture.snapshot(
                    type: .shell,
                    value: "say hi",
                    autoReplaceSelection: true,
                    runInBackground: true,
                    next: [.action(name: "Slack"), .action(name: "Not installed")]
                ),
                expected: [
                    .runsShellCommands, .sendsSelectionToURL, .replacesSelection,
                    .runsWithoutShowingOutput, .chainsToUnknownAction,
                ],
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

    func testAChainedActionsSecretReferenceEscalatesTheProposal() {
        // The proposal's own text is innocent; the installed action it chains
        // into reaches for a token. The union must carry both reasons — the
        // callout falls back to generic copy when the payload on screen has
        // no reference of its own.
        let installed = CoreFixture.snapshot(
            id: UUID(),
            name: "Post to Notion",
            type: .shell,
            value: "curl -H \"Bearer {{secrets.NOTION_API_TOKEN}}\" https://api.notion.com"
        )
        let known = KnownActions(shortcuts: [installed], destinations: [], builtInActionNames: [])
        let proposal = CoreFixture.snapshot(id: UUID(), type: .prompt, next: [.action(name: "Post to Notion")])

        XCTAssertEqual(
            ApprovalClassifier.escalationReasons(for: proposal, known: known),
            [.runsShellCommands, .referencesSecrets]
        )
    }

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

    /// The staging attack the unknown-name escalation exists to stop: propose
    /// harmless-looking B chaining to "X" before X exists, get B approved on
    /// one click, then propose shell action X. B now reaches shell and its
    /// callout never appeared. The first approval is where the blind handoff
    /// is visible, so that is where the interlock goes.
    func testAChainStepNoOneHasClaimedYetEscalatesOnItsOwn() {
        let before = CoreFixture.snapshot(name: "Tidy up", type: .prompt, next: [.action(name: "X")])
        let empty = KnownActions(shortcuts: [], destinations: [], builtInActionNames: [])

        XCTAssertEqual(
            ApprovalClassifier.escalationReasons(for: before, known: empty),
            [.chainsToUnknownAction]
        )
        XCTAssertEqual(ApprovalClassifier.tier(for: before, known: empty), .escalated)

        // Once X is installed the reason changes to what X actually is, so
        // the user is never told less than the truth in either order.
        let x = CoreFixture.snapshot(id: CoreFixture.otherId, name: "X", type: .shell, value: "./x.sh")
        let after = KnownActions(shortcuts: [x], destinations: [], builtInActionNames: [])
        XCTAssertEqual(
            ApprovalClassifier.escalationReasons(for: before, known: after),
            [.runsShellCommands]
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

    // MARK: - Traversal shape

    func testSharedDownstreamActionStillEscalatesThroughEitherRoute() {
        // Diamond: root → B and C, both → D (shell). The shared visited set
        // walks D once; its risk must surface all the same.
        let d = CoreFixture.snapshot(id: UUID(), name: "D", type: .shell, value: "./x.sh")
        let b = CoreFixture.snapshot(id: UUID(), name: "B", next: [.action(name: "D")])
        let c = CoreFixture.snapshot(id: UUID(), name: "C", next: [.action(name: "D")])
        let root = CoreFixture.snapshot(id: UUID(), name: "Root", next: [.action(name: "B"), .action(name: "C")])
        let known = KnownActions(shortcuts: [b, c, d, root], destinations: [], builtInActionNames: [])

        XCTAssertEqual(ApprovalClassifier.escalationReasons(for: root, known: known), [.runsShellCommands])
    }

    func testShallowRouteEscalatesWhenALongerRouteHitsTheDepthCapFirst() {
        // Root's first step reaches X through nine intermediaries, putting X
        // past the step cap on that route; its second step reaches X directly.
        // The direct route is one the executor runs, so X's shell destination
        // must escalate no matter which route the walk encounters first —
        // this is the case a depth-first walk with a shared visited set gets
        // wrong (X parked in `visited` at the cap, chain uncounted).
        let x = CoreFixture.snapshot(id: UUID(), name: "X", next: [.action(name: "Run script")])
        var intermediaries: [ActionSnapshot] = []
        for index in 1...9 {
            let nextName = index == 9 ? "X" : "L\(index + 1)"
            intermediaries.append(
                CoreFixture.snapshot(id: UUID(), name: "L\(index)", next: [.action(name: nextName)])
            )
        }
        let root = CoreFixture.snapshot(
            id: UUID(),
            name: "Root",
            next: [.action(name: "L1"), .action(name: "X")]
        )
        let known = KnownActions(
            shortcuts: intermediaries + [x, root],
            destinations: [DestinationSummary(name: "Run script", kind: .shell)],
            builtInActionNames: []
        )

        XCTAssertEqual(ApprovalClassifier.escalationReasons(for: root, known: known), [.runsShellCommands])
    }

    func testDenseMeshClassifiesWithoutEnumeratingPaths() {
        // Twelve prompt actions, each chaining into ten others: a dozen
        // reachable nodes but millions of simple paths. A per-path walk hangs
        // the suite here; the breadth-first walk returns instantly.
        let names = (0..<12).map { "Mesh \($0)" }
        let ids = (0..<12).map { _ in UUID() }
        let mesh = names.indices.map { index in
            CoreFixture.snapshot(
                id: ids[index],
                name: names[index],
                next: names.indices.filter { $0 != index }.prefix(10).map { .action(name: names[$0]) }
            )
        }
        let known = KnownActions(shortcuts: mesh, destinations: [], builtInActionNames: [])

        XCTAssertEqual(ApprovalClassifier.escalationReasons(for: mesh[0], known: known), [])
    }
}
