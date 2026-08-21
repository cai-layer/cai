import XCTest
@testable import Cai

/// Browse-path filtering for the extension catalog: search text AND selected
/// tag chips, plus the chip set derived from the catalog itself.
///
/// One table-driven test, two tables, and only rows that guard something that
/// can fail silently: the shipped catalog contains tags with stray whitespace
/// and mixed case (" developer", "design ", "CSS "), so a missing
/// normalisation step renders the same chip twice and a chip matches nothing;
/// AND/OR semantics invert quietly; frequency-then-alphabetical ordering and
/// the chip cap vary by input. Identity cases (no filter, empty catalog) and
/// duplicate code paths (search on description, a contradicting search) are
/// deliberately absent.
final class ExtensionCatalogFilterTests: XCTestCase {

    // MARK: - Fixtures

    private func entry(
        _ slug: String,
        name: String,
        description: String = "",
        author: String = "cai-layer",
        tags: [String]
    ) -> ExtensionService.ExtensionEntry {
        ExtensionService.ExtensionEntry(
            slug: slug, name: name, description: description, author: author,
            version: "1.0.0", icon: "gear", type: "prompt", tags: tags
        )
    }

    private lazy var catalog: [ExtensionService.ExtensionEntry] = [
        entry("fix-grammar", name: "Fix Grammar", description: "Clean up prose",
              tags: ["writing", " developer"]),
        entry("json-pretty", name: "Pretty JSON", description: "Format a JSON blob",
              tags: ["Developer", "formatting"]),
        entry("git-blame", name: "Git Blame", description: "Who wrote this line",
              author: "kisyaki", tags: ["developer", "git", "git"]),
        entry("send-slack", name: "Post to Slack", description: "Send the selection to a channel",
              tags: ["slack", ""]),
    ]

    // MARK: - Filtering

    private struct FilterCase {
        let label: String
        let search: String
        let tags: Set<String>
        let expected: [String]
        let line: UInt
    }

    private struct ChipCase {
        let label: String
        let entries: [ExtensionService.ExtensionEntry]
        let expected: [String]
        let line: UInt
    }

    func testFilterAndChipDerivation() {
        let filterCases: [FilterCase] = [
            FilterCase(
                label: "search matches the name, case-insensitively",
                search: "GRAMMAR", tags: [],
                expected: ["fix-grammar"], line: #line
            ),
            FilterCase(
                label: "search still matches tags",
                search: "git", tags: [],
                expected: ["git-blame"], line: #line
            ),
            FilterCase(
                label: "surrounding whitespace in the query is ignored",
                search: "  slack  ", tags: [],
                expected: ["send-slack"], line: #line
            ),
            FilterCase(
                label: "a chip matches dirty tag data: ' developer' and 'Developer'",
                search: "", tags: ["developer"],
                expected: ["fix-grammar", "json-pretty", "git-blame"], line: #line
            ),
            FilterCase(
                label: "two chips OR against each other",
                search: "", tags: ["writing", "slack"],
                expected: ["fix-grammar", "send-slack"], line: #line
            ),
            FilterCase(
                label: "chips AND the search field",
                search: "json", tags: ["developer"],
                expected: ["json-pretty"], line: #line
            ),
            FilterCase(
                label: "a tag no entry carries yields nothing, not everything",
                search: "", tags: ["meeting"],
                expected: [], line: #line
            ),
        ]

        for testCase in filterCases {
            let got = ExtensionCatalogFilter.filter(
                catalog, searchText: testCase.search, selectedTags: testCase.tags
            ).map(\.slug)
            XCTAssertEqual(got, testCase.expected, testCase.label, line: testCase.line)
        }

        let chipCases: [ChipCase] = [
            ChipCase(
                label: "dirty duplicates collapse; frequency first, then alphabetical",
                entries: catalog,
                expected: ["developer", "formatting", "git", "slack", "writing"], line: #line
            ),
            ChipCase(
                label: "a repeated tag on one entry counts once",
                entries: [catalog[2]],
                expected: ["developer", "git"], line: #line
            ),
            ChipCase(
                label: "empty and whitespace-only tags never become chips",
                entries: [entry("blank", name: "Blank", tags: ["   ", ""])],
                expected: [], line: #line
            ),
            ChipCase(
                label: "the chip set is capped at what fits one row",
                entries: (0..<10).map { entry("e\($0)", name: "E\($0)", tags: ["tag\($0)"]) },
                expected: ["tag0", "tag1", "tag2", "tag3", "tag4", "tag5"], line: #line
            ),
        ]

        for testCase in chipCases {
            XCTAssertEqual(
                ExtensionCatalogFilter.chipTags(for: testCase.entries),
                testCase.expected, testCase.label, line: testCase.line
            )
        }
    }
}
