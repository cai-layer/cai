import XCTest
@testable import Cai

// MARK: - MCPActionConfigRegistry Action Config Tests

/// Validates that provider action configs are well-formed — catches typos in field IDs,
/// submit mappings, and tool names that would silently break at runtime.
final class MCPActionConfigTests: XCTestCase {

    func testGitHubConfigIsWellFormed() {
        let config = MCPActionConfigRegistry.githubCreateIssue(serverConfigId: UUID())
        XCTAssertEqual(config.submitTool, "issue_write")
        XCTAssertEqual(config.staticArguments["method"], "create")

        let fieldIds = Set(config.fields.map { $0.id })
        // Every submit mapping key must reference an existing field
        for (_, template) in config.submitMapping {
            let fieldId = template.replacingOccurrences(of: "{{", with: "")
                .replacingOccurrences(of: "}}", with: "")
                .split(separator: ":").first.map(String.init) ?? ""
            XCTAssertTrue(fieldIds.contains(fieldId), "Submit mapping references unknown field '\(fieldId)'")
        }

        // LLM prompt targets existing fields
        XCTAssertTrue(fieldIds.contains(config.llmPrompt!.titleField))
        XCTAssertTrue(fieldIds.contains(config.llmPrompt!.bodyField!))

        // Triage config references existing fields
        XCTAssertNotNil(config.triageConfig)
        XCTAssertTrue(fieldIds.contains(config.triageConfig!.queryField))
    }

    func testLinearConfigIsWellFormed() {
        let config = MCPActionConfigRegistry.linearCreateIssue(serverConfigId: UUID())
        XCTAssertEqual(config.submitTool, "save_issue")

        let fieldIds = Set(config.fields.map { $0.id })
        for (_, template) in config.submitMapping {
            let fieldId = template.replacingOccurrences(of: "{{", with: "")
                .replacingOccurrences(of: "}}", with: "")
                .split(separator: ":").first.map(String.init) ?? ""
            XCTAssertTrue(fieldIds.contains(fieldId), "Submit mapping references unknown field '\(fieldId)'")
        }

        XCTAssertTrue(fieldIds.contains(config.llmPrompt!.titleField))
        XCTAssertTrue(fieldIds.contains(config.llmPrompt!.bodyField!))
        XCTAssertNil(config.triageConfig) // Linear MCP doesn't support filtered search
    }

    func testConfigIdsAreUniquePerServer() {
        let s1 = UUID(), s2 = UUID()
        let gh1 = MCPActionConfigRegistry.githubCreateIssue(serverConfigId: s1)
        let gh2 = MCPActionConfigRegistry.githubCreateIssue(serverConfigId: s2)
        XCTAssertNotEqual(gh1.id, gh2.id)
    }

    func testAllRequiredFieldsAreMarkedRequired() {
        // GitHub: repo and title must be required
        let gh = MCPActionConfigRegistry.githubCreateIssue(serverConfigId: UUID())
        XCTAssertTrue(gh.fields.first { $0.id == "repo" }!.required)
        XCTAssertTrue(gh.fields.first { $0.id == "title" }!.required)

        // Linear: title and team must be required
        let lin = MCPActionConfigRegistry.linearCreateIssue(serverConfigId: UUID())
        XCTAssertTrue(lin.fields.first { $0.id == "title" }!.required)
        XCTAssertTrue(lin.fields.first { $0.id == "team" }!.required)
    }
}
