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
                label: "name that is only invisible scalars",
                change: CoreFixture.createChange(CoreFixture.draft(name: "\u{3164}\u{2800}\u{115F}")),
                expected: .nameEmpty,
                line: #line
            ),
            RejectionCase(
                // One grapheme, 300 scalars: the grapheme cap sees a
                // one-character name and waves it through.
                label: "name stacking more scalars than the cap onto one grapheme",
                change: CoreFixture.createChange(CoreFixture.draft(
                    name: "A" + CoreFixture.repeating("\u{0301}", 300)
                )),
                expected: .nameTooManyScalars(max: 240, found: 300),
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
            RejectionCase(
                label: "url action on http",
                change: CoreFixture.createChange(CoreFixture.draft(type: .url, value: "http://example.com/?q=%s")),
                expected: .urlActionMustUseHTTPS,
                line: #line
            ),
            RejectionCase(
                label: "url action on a file scheme",
                change: CoreFixture.createChange(CoreFixture.draft(type: .url, value: "file:///etc/passwd")),
                expected: .urlActionMustUseHTTPS,
                line: #line
            ),
            RejectionCase(
                label: "url action on an app scheme",
                change: CoreFixture.createChange(CoreFixture.draft(type: .url, value: "cursor://open")),
                expected: .urlActionMustUseHTTPS,
                line: #line
            ),
            RejectionCase(
                label: "url action with no scheme at all",
                change: CoreFixture.createChange(CoreFixture.draft(type: .url, value: "example.com/?q=%s")),
                expected: .urlActionMustUseHTTPS,
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

    // MARK: - URL scheme policy

    func testAnHTTPSURLActionPasses() throws {
        let change = CoreFixture.createChange(CoreFixture.draft(
            type: .url,
            value: "https://www.google.com/search?q=%s"
        ))
        let validated = try ActionValidator.validate(change, known: CoreFixture.known)
        XCTAssertEqual(validated.after.type, .url)
    }

    func testAnUppercaseHTTPSSchemePasses() throws {
        let change = CoreFixture.createChange(CoreFixture.draft(type: .url, value: "HTTPS://example.com/%s"))
        XCTAssertNoThrow(try ActionValidator.validate(change, known: CoreFixture.known))
    }

    /// The rule guards authored values, not pre-existing ones: touching an
    /// unrelated field of the user's own non-https action must not be refused
    /// over a value nobody proposed, but rewriting the value is authored.
    func testTheSchemeRuleOnlyAppliesToFieldsThePatchWrites() throws {
        let known = KnownActions(shortcuts: [CoreFixture.snapshot(type: .url, value: "myapp://open")])

        let pinOnly = CoreFixture.updateChange(
            changes: ActionPatch(pinned: true),
            expected: ActionPatch(pinned: false)
        )
        XCTAssertNoThrow(try ActionValidator.validate(pinOnly, known: known))

        let rewrite = CoreFixture.updateChange(
            changes: ActionPatch(value: "myapp://elsewhere"),
            expected: ActionPatch(value: "myapp://open")
        )
        XCTAssertThrowsError(try ActionValidator.validate(rewrite, known: known)) { error in
            XCTAssertEqual(error as? ActionRejection, .urlActionMustUseHTTPS)
        }
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

    func testMismatchMessageShowsWhereTheValuesActuallyDiverge() {
        // Two versions of the same script: identical for the first 200
        // characters, differing at the end. Clipping from the start would
        // print the same excerpt twice and tell the agent nothing.
        let shared = String(repeating: "echo same line\n", count: 20)
        let rejection = ActionRejection.valueMismatch(
            field: "value",
            expected: shared + "echo OLD ending",
            current: shared + "echo NEW ending"
        )

        XCTAssertTrue(rejection.reason.contains("OLD ending"), rejection.reason)
        XCTAssertTrue(rejection.reason.contains("NEW ending"), rejection.reason)
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

    // MARK: - Invisible-character folding

    /// The approval sheet's duplicate warning is only worth anything if two
    /// names that *render* the same *compare* the same. Everything here
    /// renders identically to a name the user already has, so each row is a
    /// name that could impersonate a trusted action from the ⌥C list.
    ///
    /// One table rather than a method per scalar: the interesting axis is
    /// which scalar classes fold and which are left alone, and that reads as
    /// a list.
    func testInvisibleScalarsFoldSoLookalikeNamesCollide() throws {
        struct FoldCase {
            let label: String
            let proposed: String
            let stored: String
            /// Whether the folded name should trip the duplicate warning
            /// against `CoreFixture.known` ("Existing action", "Slack").
            let collides: Bool
            let line: UInt
        }

        let cases: [FoldCase] = [
            FoldCase(
                label: "braille blank suffix (So, not default-ignorable)",
                proposed: "Existing action\u{2800}",
                stored: "Existing action",
                collides: true,
                line: #line
            ),
            FoldCase(
                label: "hangul filler suffix (Lo, default-ignorable)",
                proposed: "Existing action\u{3164}",
                stored: "Existing action",
                collides: true,
                line: #line
            ),
            FoldCase(
                // The one trimming never caught: it only touches the ends.
                label: "non-breaking space between words",
                proposed: "Existing\u{00A0}action",
                stored: "Existing action",
                collides: true,
                line: #line
            ),
            FoldCase(
                label: "an ordinary name passes through untouched",
                proposed: "Weekly digest",
                stored: "Weekly digest",
                collides: false,
                line: #line
            ),
            FoldCase(
                label: "accents and non-Latin scripts survive",
                proposed: "Résumé 日本語",
                stored: "Résumé 日本語",
                collides: false,
                line: #line
            ),
            FoldCase(
                // Default-ignorable, but dropping it would change how a
                // legitimate name renders rather than protect anyone.
                label: "emoji variation selector is kept",
                proposed: "Mail \u{2709}\u{FE0F}",
                stored: "Mail \u{2709}\u{FE0F}",
                collides: false,
                line: #line
            ),
        ]

        for testCase in cases {
            let validated = try ActionValidator.validate(
                CoreFixture.createChange(CoreFixture.draft(name: testCase.proposed)),
                known: CoreFixture.known
            )
            XCTAssertEqual(
                validated.after.name,
                testCase.stored,
                testCase.label,
                line: testCase.line
            )
            XCTAssertEqual(
                validated.warnings.contains(.duplicateName(testCase.stored)),
                testCase.collides,
                "duplicate warning for \(testCase.label)",
                line: testCase.line
            )
            // A name that had something folded out of it must say so, and a
            // clean name must not claim it was touched.
            XCTAssertEqual(
                validated.warnings.contains(.invisibleCharactersNormalized(field: .name)),
                testCase.proposed != testCase.stored,
                "fold warning for \(testCase.label)",
                line: testCase.line
            )
        }
    }

    /// Canonical equivalence is already Swift's `==`, so an NFD name is not a
    /// duplicate-warning bypass and must not be reported as altered.
    func testDecomposedNameIsStoredComposedWithoutAWarning() throws {
        let validated = try ActionValidator.validate(
            CoreFixture.createChange(CoreFixture.draft(name: "Cafe\u{0301} notes")),
            known: CoreFixture.known
        )
        XCTAssertEqual(validated.after.name.unicodeScalars.count, 10, "Name should be stored composed.")
        XCTAssertFalse(validated.warnings.contains(.invisibleCharactersNormalized(field: .name)))
    }

    /// ZWJ is Cf, so a flat strip broke every emoji sequence in a name. The
    /// exemption cannot be "keep ZWJ", because ZWJ is invisible and that
    /// reopens the impersonation the fold closes. The grapheme cluster is the
    /// discriminator, so both halves belong in one table.
    func testEmojiSequencesSurviveButInvisibleJoinersDoNot() throws {
        struct EmojiCase {
            let label: String
            let proposed: String
            let stored: String
            let line: UInt
        }

        let cases: [EmojiCase] = [
            EmojiCase(
                label: "family ZWJ sequence stays one glyph",
                proposed: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466} Household",
                stored: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466} Household",
                line: #line
            ),
            EmojiCase(
                label: "emoji plus skin-tone modifier",
                proposed: "\u{1F44D}\u{1F3FD} Approve",
                stored: "\u{1F44D}\u{1F3FD} Approve",
                line: #line
            ),
            EmojiCase(
                // Variation selector mid-sequence, the case a naive
                // "strip default-ignorables" rule mangles.
                label: "rainbow flag keeps its variation selector and joiner",
                proposed: "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308} Pride",
                stored: "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308} Pride",
                line: #line
            ),
            EmojiCase(
                label: "joiner between letters is still removed",
                proposed: "Sum\u{200D}marize",
                stored: "Summarize",
                line: #line
            ),
            EmojiCase(
                // Digits are Emoji but not Emoji_Presentation, so they get no
                // protection and cannot smuggle a joiner.
                label: "joiner between digits is still removed",
                proposed: "Report 1\u{200D}2",
                stored: "Report 12",
                line: #line
            ),
            EmojiCase(
                label: "trailing joiner after an emoji is invisible padding",
                proposed: "Household \u{1F468}\u{200D}",
                stored: "Household \u{1F468}",
                line: #line
            ),
        ]

        for testCase in cases {
            let validated = try ActionValidator.validate(
                CoreFixture.createChange(CoreFixture.draft(name: testCase.proposed)),
                known: CoreFixture.known
            )
            XCTAssertEqual(
                validated.after.name,
                testCase.stored,
                testCase.label,
                line: testCase.line
            )
        }
    }

    /// U+2028 / U+2029 are Zl and Zp: not control characters, not
    /// default-ignorable, not `.whitespaces`. They are removed by the
    /// control-character strip before the fold sees them, so the stored name
    /// closes up rather than gaining a space. Pinned because the two stages
    /// treat them differently and the difference is easy to "fix" wrongly.
    func testLineSeparatorsAreRemovedBeforeTheFoldAndDoNotImpersonate() throws {
        let validated = try ActionValidator.validate(
            CoreFixture.createChange(CoreFixture.draft(name: "Existing\u{2028}action")),
            known: CoreFixture.known
        )
        XCTAssertEqual(validated.after.name, "Existingaction")
        XCTAssertTrue(validated.warnings.contains(.controlCharactersRemoved(field: .name)))
        XCTAssertFalse(
            validated.warnings.contains(.duplicateName("Existing action")),
            "The stored name reads differently, so there is nothing to warn about."
        )
    }

    func testScalarCapIsInclusive() throws {
        let atLimit = "A" + CoreFixture.repeating("\u{0301}", 240)
        let validated = try ActionValidator.validate(
            CoreFixture.createChange(CoreFixture.draft(name: atLimit)),
            known: CoreFixture.known
        )
        XCTAssertEqual(validated.after.name.unicodeScalars.count, 240)
    }
}
