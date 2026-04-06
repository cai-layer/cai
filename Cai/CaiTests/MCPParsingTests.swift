import XCTest
@testable import Cai

/// Tests for MCP parsing logic — response unwrapping, error message extraction,
/// URL extraction. These are pure functions with regression history, so tests
/// here protect against silent breakage when provider response formats shift.
final class MCPParsingTests: XCTestCase {

    // MARK: - parsePickerOptions

    /// parsePickerOptions is nonisolated on the actor, so we can call it directly.
    private let service = MCPClientService.shared

    func testParsesBareArrayOfObjects() {
        let json = """
        [
          {"id": 1, "name": "bug"},
          {"id": 2, "name": "enhancement"}
        ]
        """
        let options = service.parsePickerOptions(from: json, toolName: "list_label")
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].label, "bug")
        XCTAssertEqual(options[1].label, "enhancement")
    }

    func testAutoUnwrapsSingleArrayFromDict() {
        // GitHub labels wrapped in {"labels": [...]}
        let json = """
        {"labels": [
          {"id": "LA_123", "name": "bug", "color": "d73a4a"}
        ]}
        """
        let options = service.parsePickerOptions(from: json, toolName: "list_label")
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].label, "bug")
    }

    func testUnwrapsItemsKey() {
        // GitHub search API format
        let json = """
        {"items": [
          {"full_name": "clipboard-ai/cai", "name": "cai"}
        ]}
        """
        let options = service.parsePickerOptions(from: json, toolName: "search_repositories")
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].id, "clipboard-ai/cai",
                       "Repos should use full_name as id for owner/repo splitting")
        XCTAssertEqual(options[0].label, "clipboard-ai/cai")
    }

    func testPrefersFullNameOverId() {
        let json = """
        [
          {"id": 123456, "full_name": "org/repo", "name": "repo"}
        ]
        """
        let options = service.parsePickerOptions(from: json, toolName: "search_repositories")
        XCTAssertEqual(options[0].id, "org/repo",
                       "full_name should win over numeric id")
    }

    func testUsesNameWhenNoFullName() {
        // GitHub label: no full_name, name is the submit value
        let json = """
        [
          {"id": 123, "name": "bug"}
        ]
        """
        let options = service.parsePickerOptions(
            from: json, toolName: "list_label", idKey: "name"
        )
        XCTAssertEqual(options[0].id, "bug",
                       "idKey override should pick name over numeric id")
        XCTAssertEqual(options[0].label, "bug")
    }

    func testReturnsEmptyForEmptyInput() {
        let options = service.parsePickerOptions(from: "", toolName: "empty")
        XCTAssertTrue(options.isEmpty)
    }

    func testReturnsEmptyForUnrecognizedFormat() {
        let json = "{\"error\": \"something unexpected\"}"
        let options = service.parsePickerOptions(from: json, toolName: "unknown")
        XCTAssertTrue(options.isEmpty,
                      "Unrecognized formats should return empty, not crash")
    }

    func testReturnsEmptyWhenObjectsLackIdAndLabel() {
        // Regression guard: when array objects have no usable id/label fields,
        // parsePickerOptions should skip them and return empty — not crash or
        // produce garbage options.
        let json = "[{\"unused\": \"x\"}, {\"other\": 1}]"
        let options = service.parsePickerOptions(from: json, toolName: "unknown")
        XCTAssertTrue(options.isEmpty,
                      "Objects without id/label fields should be skipped")
    }

    func testHandlesLinearTeamsFormat() {
        // Linear returns team objects with UUIDs as ids
        let json = """
        {"teams": [
          {"id": "595559a5-62d5-4baf-bebd-8e0b5097bbe5", "name": "Engineering"}
        ]}
        """
        let options = service.parsePickerOptions(from: json, toolName: "list_teams")
        XCTAssertEqual(options[0].id, "595559a5-62d5-4baf-bebd-8e0b5097bbe5")
        XCTAssertEqual(options[0].label, "Engineering")
    }

    // MARK: - extractErrorMessage

    func testExtractsGitHubNotFoundError() {
        let json = "{\"message\": \"Not Found\", \"status\": \"404\"}"
        let msg = MCPFormView.extractErrorMessage(from: json)
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("Not Found") ?? false)
        XCTAssertTrue(msg?.contains("404") ?? false)
    }

    func testExtractsGitHubForbiddenError() {
        let json = "{\"message\": \"Forbidden\", \"status\": \"403\"}"
        let msg = MCPFormView.extractErrorMessage(from: json)
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.lowercased().contains("forbidden") ?? false)
    }

    func testExtractsLinearGraphQLError() {
        let json = """
        {"errors": [{"message": "Unauthorized: team access denied"}]}
        """
        let msg = MCPFormView.extractErrorMessage(from: json)
        XCTAssertEqual(msg, "Unauthorized: team access denied")
    }

    func testExtractsNestedErrorMessage() {
        let json = "{\"error\": {\"message\": \"Rate limit exceeded\"}}"
        let msg = MCPFormView.extractErrorMessage(from: json)
        XCTAssertEqual(msg, "Rate limit exceeded")
    }

    func testExtractsSimpleErrorString() {
        let json = "{\"error\": \"Invalid token\"}"
        let msg = MCPFormView.extractErrorMessage(from: json)
        XCTAssertEqual(msg, "Invalid token")
    }

    func testReturnsNilForMessageWithoutErrorKeywords() {
        // A "message" field that isn't actually an error
        let json = "{\"message\": \"Welcome to the API\"}"
        let msg = MCPFormView.extractErrorMessage(from: json)
        XCTAssertNil(msg, "Message without error keywords should return nil")
    }

    func testExtractsPlainTextHTTPError() {
        // The plain-text fallback requires both an HTTP status prefix (4xx/5xx)
        // AND a recognized error keyword ("error", "not found", "forbidden").
        let text = "404 not found: repository does not exist"
        let msg = MCPFormView.extractErrorMessage(from: text)
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("404") ?? false)
    }

    func testReturnsNilForPlainNonErrorText() {
        let text = "Issue created successfully"
        let msg = MCPFormView.extractErrorMessage(from: text)
        XCTAssertNil(msg)
    }

    // MARK: - extractURL

    func testExtractsGitHubHtmlURL() {
        let json = """
        {"html_url": "https://github.com/owner/repo/issues/42", "number": 42}
        """
        let url = MCPFormView.extractURL(from: json)
        XCTAssertEqual(url, "https://github.com/owner/repo/issues/42")
    }

    func testPrefersHtmlURLOverURL() {
        let json = """
        {"html_url": "https://github.com/x", "url": "https://api.github.com/x"}
        """
        let url = MCPFormView.extractURL(from: json)
        XCTAssertEqual(url, "https://github.com/x",
                       "html_url should be preferred over url for user display")
    }

    func testFallsBackToRegexURLExtraction() {
        let text = "Successfully created: https://linear.app/team/issue/ENG-123"
        let url = MCPFormView.extractURL(from: text)
        XCTAssertEqual(url, "https://linear.app/team/issue/ENG-123")
    }

    func testReturnsNilForNoURLPresent() {
        let text = "Something succeeded but no URL in the response"
        let url = MCPFormView.extractURL(from: text)
        XCTAssertNil(url)
    }

    func testExtractsLinearIssueURL() {
        let json = """
        {"url": "https://linear.app/team/issue/ENG-456", "identifier": "ENG-456"}
        """
        let url = MCPFormView.extractURL(from: json)
        XCTAssertEqual(url, "https://linear.app/team/issue/ENG-456")
    }
}
