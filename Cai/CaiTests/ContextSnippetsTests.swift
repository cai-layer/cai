import XCTest
@testable import Cai

/// Tests for Context Snippets v1:
/// - `ContextSnippet` model Codable round-trip + validation
/// - `ContextSnippetsFile` envelope decoding
/// - `ContextSnippetsManager` load paths (missing, empty, valid, malformed, future version)
/// - `snippet(forBundleId:)` matching logic
///
/// Manager tests use a per-test temp directory so they don't touch the real
/// `~/.config/cai/snippets.json`. The `ContextSnippetsManager` init takes an
/// optional `configDirectory: URL?` param to support this.
final class ContextSnippetsTests: XCTestCase {

    // MARK: - Model: ContextSnippet Codable

    func testContextSnippetCodableRoundTrip() throws {
        let original = ContextSnippet(
            bundleId: "com.apple.Terminal",
            appName: "Terminal",
            context: "Ruby/Rails debugging context",
            enabled: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContextSnippet.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.bundleId, original.bundleId)
        XCTAssertEqual(decoded.appName, original.appName)
        XCTAssertEqual(decoded.context, original.context)
        XCTAssertEqual(decoded.enabled, original.enabled)
    }

    func testContextSnippetRejectsInvalidUUID() {
        let badJSON = """
        {
          "id": "not-a-valid-uuid",
          "bundleId": "com.apple.Terminal",
          "appName": "Terminal",
          "context": "test",
          "enabled": true
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(ContextSnippet.self, from: badJSON),
                             "Decoding should throw on invalid UUID")
    }

    func testContextSnippetUnknownKeysIgnored() throws {
        let jsonWithExtra = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "bundleId": "com.apple.Terminal",
          "appName": "Terminal",
          "context": "test",
          "enabled": true,
          "extraField": "should be ignored",
          "anotherExtra": 42
        }
        """.data(using: .utf8)!

        let snippet = try JSONDecoder().decode(ContextSnippet.self, from: jsonWithExtra)
        XCTAssertEqual(snippet.bundleId, "com.apple.Terminal")
    }

    // MARK: - Model: ContextSnippetsFile envelope

    func testContextSnippetsFileVersionField() throws {
        let json = """
        {
          "version": 1,
          "snippets": []
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder().decode(ContextSnippetsFile.self, from: json)
        XCTAssertEqual(file.version, 1)
        XCTAssertTrue(file.snippets.isEmpty)
    }

    func testContextSnippetsFileDecodesWithSnippets() throws {
        let json = """
        {
          "version": 1,
          "snippets": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "bundleId": "com.apple.Terminal",
              "appName": "Terminal",
              "context": "Rails debugging",
              "enabled": true
            },
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "bundleId": "com.tinyspeck.slackmacgap",
              "appName": "Slack",
              "context": "Casual but professional",
              "enabled": false
            }
          ]
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder().decode(ContextSnippetsFile.self, from: json)
        XCTAssertEqual(file.snippets.count, 2)
        XCTAssertEqual(file.snippets[0].appName, "Terminal")
        XCTAssertEqual(file.snippets[1].appName, "Slack")
        XCTAssertFalse(file.snippets[1].enabled)
    }

    // MARK: - Manager: Load Paths

    /// Creates a temp directory for the test and returns its URL.
    /// The test's manager writes to this dir instead of `~/.config/cai/`.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextSnippetsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanupTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func testManagerLoadMissingFileSeedsEmptyAndReturnsEmptyList() {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        // Ensure the file doesn't exist yet
        let fileURL = dir.appendingPathComponent("snippets.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let manager = ContextSnippetsManager(configDirectory: dir)

        // Empty snippets
        XCTAssertTrue(manager.snippets.isEmpty)
        // Seed file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Seed file contains a valid empty envelope
        let data = try! Data(contentsOf: fileURL)
        let decoded = try! JSONDecoder().decode(ContextSnippetsFile.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.snippets.isEmpty)
    }

    func testManagerLoadEmptyFileReturnsEmptyList() throws {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        let fileURL = dir.appendingPathComponent("snippets.json")
        try Data().write(to: fileURL)  // 0-byte file

        let manager = ContextSnippetsManager(configDirectory: dir)
        XCTAssertTrue(manager.snippets.isEmpty)
    }

    func testManagerLoadValidFile() throws {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        let fileURL = dir.appendingPathComponent("snippets.json")
        let json = """
        {
          "version": 1,
          "snippets": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "bundleId": "com.apple.Terminal",
              "appName": "Terminal",
              "context": "Rails context",
              "enabled": true
            }
          ]
        }
        """
        try json.write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = ContextSnippetsManager(configDirectory: dir)
        XCTAssertEqual(manager.snippets.count, 1)
        XCTAssertEqual(manager.snippets[0].bundleId, "com.apple.Terminal")
    }

    func testManagerLoadMalformedJSONFallsBackToEmpty() throws {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        let fileURL = dir.appendingPathComponent("snippets.json")
        try "{ this is not valid JSON".write(to: fileURL, atomically: true, encoding: .utf8)

        // Subscribe to toast notifications to verify one fires
        let toastExpectation = expectation(description: "Toast posted for malformed JSON")
        let observer = NotificationCenter.default.addObserver(
            forName: .caiShowToast, object: nil, queue: nil
        ) { notification in
            if let message = notification.userInfo?["message"] as? String,
               message.lowercased().contains("json") {
                toastExpectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let manager = ContextSnippetsManager(configDirectory: dir)
        XCTAssertTrue(manager.snippets.isEmpty)

        wait(for: [toastExpectation], timeout: 1.0)
    }

    func testManagerLoadFutureVersionRejected() throws {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        let fileURL = dir.appendingPathComponent("snippets.json")
        let futureJSON = """
        {
          "version": 99,
          "snippets": []
        }
        """
        try futureJSON.write(to: fileURL, atomically: true, encoding: .utf8)

        let toastExpectation = expectation(description: "Toast posted for future version")
        let observer = NotificationCenter.default.addObserver(
            forName: .caiShowToast, object: nil, queue: nil
        ) { notification in
            if let message = notification.userInfo?["message"] as? String,
               message.lowercased().contains("newer version") {
                toastExpectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let manager = ContextSnippetsManager(configDirectory: dir)
        XCTAssertTrue(manager.snippets.isEmpty)

        wait(for: [toastExpectation], timeout: 1.0)
    }

    func testManagerDoesNotOverwriteExistingFile() throws {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        let fileURL = dir.appendingPathComponent("snippets.json")
        let userContent = """
        {
          "version": 1,
          "snippets": [
            {
              "id": "00000000-0000-0000-0000-000000000042",
              "bundleId": "com.example.MyApp",
              "appName": "My App",
              "context": "user content",
              "enabled": true
            }
          ]
        }
        """
        try userContent.write(to: fileURL, atomically: true, encoding: .utf8)

        // Create the manager — seed should NOT overwrite the existing file
        _ = ContextSnippetsManager(configDirectory: dir)

        let reloaded = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(reloaded.contains("com.example.MyApp"))
        XCTAssertTrue(reloaded.contains("user content"))
    }

    // MARK: - Manager: Matching Logic

    private func makeManagerWithSnippets(_ snippets: [ContextSnippet]) throws -> ContextSnippetsManager {
        let dir = makeTempDir()
        // NOTE: caller is responsible for cleanup via a tempDirs array or similar.
        // For simplicity, these tests leak the temp dir — each test uses its own UUID,
        // and the OS cleans /tmp on restart.
        let fileURL = dir.appendingPathComponent("snippets.json")
        let file = ContextSnippetsFile(version: 1, snippets: snippets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(file)
        try data.write(to: fileURL)
        return ContextSnippetsManager(configDirectory: dir)
    }

    func testSnippetForBundleIdMatchEnabled() throws {
        let manager = try makeManagerWithSnippets([
            ContextSnippet(bundleId: "com.apple.Terminal", appName: "Terminal",
                           context: "Rails", enabled: true)
        ])

        let result = manager.snippet(forBundleId: "com.apple.Terminal")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.context, "Rails")
    }

    func testSnippetForBundleIdSkipDisabled() throws {
        let manager = try makeManagerWithSnippets([
            ContextSnippet(bundleId: "com.apple.Terminal", appName: "Terminal",
                           context: "Rails", enabled: false)
        ])

        let result = manager.snippet(forBundleId: "com.apple.Terminal")
        XCTAssertNil(result, "Disabled snippets should not be returned")
    }

    func testSnippetForBundleIdNilInputReturnsNil() throws {
        let manager = try makeManagerWithSnippets([
            ContextSnippet(bundleId: "com.apple.Terminal", appName: "Terminal",
                           context: "Rails", enabled: true)
        ])

        XCTAssertNil(manager.snippet(forBundleId: nil))
    }

    func testSnippetForBundleIdEmptyInputReturnsNil() throws {
        let manager = try makeManagerWithSnippets([
            ContextSnippet(bundleId: "com.apple.Terminal", appName: "Terminal",
                           context: "Rails", enabled: true)
        ])

        XCTAssertNil(manager.snippet(forBundleId: ""))
    }

    func testSnippetForBundleIdNoMatchReturnsNil() throws {
        let manager = try makeManagerWithSnippets([
            ContextSnippet(bundleId: "com.apple.Terminal", appName: "Terminal",
                           context: "Rails", enabled: true)
        ])

        XCTAssertNil(manager.snippet(forBundleId: "com.unknown.app"))
    }
}
