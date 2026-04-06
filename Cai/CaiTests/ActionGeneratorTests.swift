import XCTest
@testable import Cai

/// Tests for ActionGenerator — validates that the right actions appear for each
/// content type, and that filter-to-reveal (generateAllActions) exposes everything.
final class ActionGeneratorTests: XCTestCase {

    private var settings: CaiSettings!

    override func setUp() {
        super.setUp()
        settings = CaiSettings.shared
    }

    // MARK: - Helpers

    private func detection(_ type: ContentType, entities: ContentEntities = ContentEntities()) -> ContentResult {
        ContentResult(type: type, confidence: 1.0, entities: entities)
    }

    private func titles(_ actions: [ActionItem]) -> [String] {
        actions.map { $0.title }
    }

    private func hasAction(_ actions: [ActionItem], id: String) -> Bool {
        actions.contains { $0.id == id }
    }

    // MARK: - Ask AI is always first

    func testAskAIIsAlwaysFirstAction() {
        let types: [ContentType] = [.shortText, .longText, .url, .json, .word, .meeting, .address, .image]
        for type in types {
            let actions = ActionGenerator.generateActions(
                for: "sample content that is long enough to matter",
                detection: detection(type),
                settings: settings
            )
            XCTAssertEqual(actions.first?.id, "custom_prompt",
                           "Ask AI should be first for content type \(type)")
            XCTAssertEqual(actions.first?.shortcut, 1,
                           "Ask AI should have shortcut 1 for content type \(type)")
        }
    }

    // MARK: - Empty clipboard

    func testEmptyClipboardHidesAllTextActions() {
        // Empty clipboard should only show Ask AI (+ any configured destinations).
        // No Summarize/Explain/Reply — they'd have no content to operate on.
        let actions = ActionGenerator.generateActions(
            for: "",
            detection: detection(.empty),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "custom_prompt"))
        XCTAssertFalse(hasAction(actions, id: "summarize"))
        XCTAssertFalse(hasAction(actions, id: "explain"))
        XCTAssertFalse(hasAction(actions, id: "reply"))
        XCTAssertFalse(hasAction(actions, id: "proofread"))
        XCTAssertFalse(hasAction(actions, id: "define_word"))
    }

    // MARK: - Extension early return

    func testExtensionOnlyShowsInstallAction() {
        let actions = ActionGenerator.generateActions(
            for: "# cai-extension\nname: Test",
            detection: detection(.caiExtension),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "custom_prompt"))
        XCTAssertTrue(hasAction(actions, id: "install_extension"))
        XCTAssertFalse(hasAction(actions, id: "summarize"))
        XCTAssertFalse(hasAction(actions, id: "explain"))
    }

    // MARK: - Bare URL — focused list

    func testBareURLShowsOpenInBrowserButNoTextActions() {
        let entities = ContentEntities(url: "https://example.com")
        let actions = ActionGenerator.generateActions(
            for: "https://example.com",
            detection: detection(.url, entities: entities),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "open_url"))
        XCTAssertFalse(hasAction(actions, id: "summarize"),
                       "Bare URL should not show Summarize by default")
        XCTAssertFalse(hasAction(actions, id: "reply"),
                       "Bare URL should not show Reply by default")
    }

    // MARK: - JSON — focused list

    func testJSONShowsPrettyPrintButNoTextActions() {
        let actions = ActionGenerator.generateActions(
            for: "{\"key\": \"value\"}",
            detection: detection(.json),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "pretty_print"))
        XCTAssertFalse(hasAction(actions, id: "reply"),
                       "JSON should not show Reply by default")
        XCTAssertFalse(hasAction(actions, id: "proofread"),
                       "JSON should not show Fix Grammar by default")
    }

    // MARK: - Word — define + text actions, no reply/proofread

    func testWordShowsDefineButNoReplyOrProofread() {
        let actions = ActionGenerator.generateActions(
            for: "ephemeral",
            detection: detection(.word),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "define_word"))
        XCTAssertTrue(hasAction(actions, id: "explain"))
        XCTAssertFalse(hasAction(actions, id: "reply"),
                       "Single word should not show Reply")
        XCTAssertFalse(hasAction(actions, id: "proofread"),
                       "Single word should not show Fix Grammar")
    }

    // MARK: - Short text — full prose action set

    func testShortTextShowsReplyAndProofread() {
        let actions = ActionGenerator.generateActions(
            for: "Can we push the release to next Monday?",
            detection: detection(.shortText),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "explain"))
        XCTAssertTrue(hasAction(actions, id: "reply"))
        XCTAssertTrue(hasAction(actions, id: "proofread"))
        XCTAssertTrue(hasAction(actions, id: "translate"))
    }

    // MARK: - Long text — includes Summarize, excludes Search

    func testLongTextShowsSummarizeAndExcludesSearch() {
        let longText = String(repeating: "This is a long paragraph of text. ", count: 10)
        let actions = ActionGenerator.generateActions(
            for: longText,
            detection: detection(.longText),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "summarize"))
        XCTAssertTrue(hasAction(actions, id: "reply"))
        XCTAssertFalse(hasAction(actions, id: "search_web"),
                       "Long text should not show Search Web")
    }

    // MARK: - Meeting — calendar + text actions, no reply/proofread

    func testMeetingShowsCalendarButNoReplyOrProofread() {
        let entities = ContentEntities(date: Date(), location: "WeWork")
        let actions = ActionGenerator.generateActions(
            for: "Team standup Thursday 3pm at WeWork",
            detection: detection(.meeting, entities: entities),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "create_event"))
        XCTAssertFalse(hasAction(actions, id: "reply"),
                       "Meeting should not show Reply")
        XCTAssertFalse(hasAction(actions, id: "proofread"),
                       "Meeting should not show Fix Grammar")
    }

    // MARK: - Address — maps + text actions, no reply/proofread

    func testAddressShowsMapsButNoReplyOrProofread() {
        let entities = ContentEntities(address: "Torstraße 123, 10119 Berlin")
        let actions = ActionGenerator.generateActions(
            for: "Torstraße 123, 10119 Berlin",
            detection: detection(.address, entities: entities),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "open_maps"))
        XCTAssertFalse(hasAction(actions, id: "reply"),
                       "Address should not show Reply")
    }

    // MARK: - Summarize content-length guard

    func testSummarizeRequiresAtLeast100Characters() {
        let shortActions = ActionGenerator.generateActions(
            for: "Too short.",
            detection: detection(.shortText),
            settings: settings
        )
        XCTAssertFalse(hasAction(shortActions, id: "summarize"),
                       "Summarize should not appear for text under 100 chars")

        let longEnough = String(repeating: "Long enough text. ", count: 10) // > 100 chars
        let longActions = ActionGenerator.generateActions(
            for: longEnough,
            detection: detection(.shortText),
            settings: settings
        )
        // Note: .shortText with >= 100 chars still gets summarize via content guard
        XCTAssertTrue(hasAction(longActions, id: "summarize"),
                      "Summarize should appear when text >= 100 chars")
    }

    // MARK: - Filter-to-reveal (generateAllActions)

    func testGenerateAllActionsIncludesUniversalTextActionsForJSON() {
        let json = "{\"key\": \"value\"}"
        let all = ActionGenerator.generateAllActions(
            for: json,
            detection: detection(.json),
            settings: settings
        )
        XCTAssertTrue(hasAction(all, id: "summarize"),
                      "generateAllActions should include Summarize even for JSON")
        XCTAssertTrue(hasAction(all, id: "explain"),
                      "generateAllActions should include Explain even for JSON")
        XCTAssertTrue(hasAction(all, id: "reply"),
                      "generateAllActions should include Reply even for JSON")
        XCTAssertTrue(hasAction(all, id: "proofread"),
                      "generateAllActions should include Fix Grammar even for JSON")
    }

    func testGenerateAllActionsIncludesUniversalTextActionsForURL() {
        let entities = ContentEntities(url: "https://example.com")
        let all = ActionGenerator.generateAllActions(
            for: "https://example.com",
            detection: detection(.url, entities: entities),
            settings: settings
        )
        XCTAssertTrue(hasAction(all, id: "summarize"))
        XCTAssertTrue(hasAction(all, id: "explain"))
        XCTAssertTrue(hasAction(all, id: "reply"))
        XCTAssertTrue(hasAction(all, id: "proofread"))
        // Primary URL action should still be there
        XCTAssertTrue(hasAction(all, id: "open_url"))
    }

    func testGenerateAllActionsDedupesActionsAcrossPrimaryAndExtras() {
        let all = ActionGenerator.generateAllActions(
            for: "Some prose content that is long enough to get summarize.",
            detection: detection(.shortText),
            settings: settings
        )
        // Count unique IDs — should equal total count (no dupes)
        let ids = all.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count,
                       "generateAllActions must not contain duplicate action IDs")
    }

    // MARK: - Action shortcuts

    func testGenerateAllActionsPreservesPrimaryShortcutsAndSetsExtrasToZero() {
        // Critical contract: `generateAllActions` must keep primary actions' shortcuts
        // intact (Cmd+1-9 binding depends on this) and mark extras with shortcut 0
        // so ActionListWindow.filteredActions can renumber them during filtering.
        let json = "{\"key\": \"value\"}"
        let detectionResult = detection(.json)
        let primary = ActionGenerator.generateActions(
            for: json, detection: detectionResult, settings: settings
        )
        let all = ActionGenerator.generateAllActions(
            for: json, detection: detectionResult, settings: settings
        )
        let primaryShortcutById = Dictionary(
            uniqueKeysWithValues: primary.map { ($0.id, $0.shortcut) }
        )

        for action in all {
            if let primaryShortcut = primaryShortcutById[action.id] {
                XCTAssertEqual(action.shortcut, primaryShortcut,
                               "Primary action \(action.id) must keep its shortcut in generateAllActions")
                XCTAssertGreaterThan(action.shortcut, 0,
                                     "Primary action \(action.id) must have a non-zero shortcut")
            } else {
                XCTAssertEqual(action.shortcut, 0,
                               "Extra action \(action.id) must have shortcut 0 (filter will renumber)")
            }
        }
    }

    // MARK: - Open in Browser for URL+text

    func testURLWithTextShowsBothBrowserAndTextActions() {
        let longText = "Check out this article https://example.com/article it's really interesting and worth reading through carefully."
        let entities = ContentEntities(url: "https://example.com/article")
        let actions = ActionGenerator.generateActions(
            for: longText,
            detection: detection(.url, entities: entities),
            settings: settings
        )
        XCTAssertTrue(hasAction(actions, id: "open_url"),
                      "URL+text should show Open in Browser")
        XCTAssertTrue(hasAction(actions, id: "summarize"),
                      "URL+text should show Summarize (text is long enough)")
    }
}
