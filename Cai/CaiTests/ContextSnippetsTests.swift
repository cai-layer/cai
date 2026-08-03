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

    // MARK: - Model: Optional fields in JSON (id, enabled)

    func testContextSnippetDecodesWithoutId() throws {
        // Regression guard: missing id should NOT throw — decoder generates a fresh UUID.
        // This is the JSON-ergonomics fix that lets users hand-author snippets without
        // typing UUIDs. The Swift initializer's default UUID() doesn't apply to Codable
        // (auto-synthesized decoders ignore Swift defaults), so we need a custom init.
        let json = """
        {
          "bundleId": "com.apple.Terminal",
          "appName": "Terminal",
          "context": "Ruby/Rails debugging",
          "enabled": true
        }
        """.data(using: .utf8)!

        let snippet = try JSONDecoder().decode(ContextSnippet.self, from: json)
        XCTAssertEqual(snippet.bundleId, "com.apple.Terminal")
        XCTAssertEqual(snippet.appName, "Terminal")
        XCTAssertEqual(snippet.context, "Ruby/Rails debugging")
        XCTAssertTrue(snippet.enabled)
        // id was auto-generated, exact value doesn't matter — just confirm it exists
        // and is a valid UUID (UUID type guarantees this)
    }

    func testContextSnippetDecodesWithoutEnabled() throws {
        // Regression guard: missing enabled should default to true (matches Swift init default).
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000099",
          "bundleId": "com.apple.Terminal",
          "appName": "Terminal",
          "context": "test"
        }
        """.data(using: .utf8)!

        let snippet = try JSONDecoder().decode(ContextSnippet.self, from: json)
        XCTAssertTrue(snippet.enabled, "Missing 'enabled' should default to true")
        XCTAssertEqual(snippet.id.uuidString, "00000000-0000-0000-0000-000000000099")
    }

    func testContextSnippetDecodesMinimalJSON() throws {
        // The "minimal valid snippet" — only the three required fields (bundleId,
        // appName, context). This is the shape recommended in user-facing docs.
        let json = """
        {
          "bundleId": "com.microsoft.VSCode",
          "appName": "Visual Studio Code",
          "context": "Source code or code review comments. Explain in plain English."
        }
        """.data(using: .utf8)!

        let snippet = try JSONDecoder().decode(ContextSnippet.self, from: json)
        XCTAssertEqual(snippet.bundleId, "com.microsoft.VSCode")
        XCTAssertEqual(snippet.appName, "Visual Studio Code")
        XCTAssertEqual(snippet.context, "Source code or code review comments. Explain in plain English.")
        XCTAssertTrue(snippet.enabled)  // default
        // id is auto-generated; just confirm it exists by accessing it (UUID is non-optional)
        _ = snippet.id
    }

    func testContextSnippetGeneratesNewIdOnEachDecodeWhenMissing() throws {
        // Ephemeral-id semantics: two decodes of the same id-less JSON produce
        // different UUIDs in memory. This is intentional and documented — the
        // first v1.1 Settings UI save will persist whichever id is in memory at
        // that moment, after which the id becomes stable across launches.
        let json = """
        {
          "bundleId": "com.apple.Terminal",
          "appName": "Terminal",
          "context": "test"
        }
        """.data(using: .utf8)!

        let a = try JSONDecoder().decode(ContextSnippet.self, from: json)
        let b = try JSONDecoder().decode(ContextSnippet.self, from: json)
        XCTAssertNotEqual(a.id, b.id,
                          "Each decode of id-less JSON should generate a fresh UUID — confirms id is not statically derived from content")
    }

    func testContextSnippetStillRequiresBundleId() {
        // Negative regression guard: removing the wrong field (a required one)
        // must still throw. We didn't accidentally make everything optional.
        let json = """
        {
          "appName": "Terminal",
          "context": "test"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(ContextSnippet.self, from: json),
                             "Missing required field 'bundleId' should throw")
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

    func testManagerSeedsStarterFileWithDisabledExample() {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        // Ensure the file doesn't exist yet
        let fileURL = dir.appendingPathComponent("snippets.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let manager = ContextSnippetsManager(configDirectory: dir)

        // Seed file was created and decodes as a valid v1 envelope
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let data = try! Data(contentsOf: fileURL)
        let decoded = try! JSONDecoder().decode(ContextSnippetsFile.self, from: data)
        XCTAssertEqual(decoded.version, 1)

        // The starter example is present but disabled — seeding never changes behavior
        XCTAssertEqual(decoded.snippets.count, 1)
        XCTAssertFalse(decoded.snippets[0].enabled)
        XCTAssertEqual(manager.snippets.count, 1)
        XCTAssertNil(manager.snippet(forBundleId: decoded.snippets[0].bundleId),
                     "Disabled starter example must be inert for lookups")

        // The self-documentation link rides along as an ignored unknown key
        let raw = String(data: data, encoding: .utf8)!
        XCTAssertTrue(raw.contains("\"_docs\""),
                      "Starter file should carry a _docs pointer to the manual")
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

        let manager = ContextSnippetsManager(configDirectory: dir)
        XCTAssertTrue(manager.snippets.isEmpty)

        // The manager stores a pending error (consumed by the UI at display time).
        let error = manager.consumePendingLoadError()
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.lowercased().contains("json"))
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

        let manager = ContextSnippetsManager(configDirectory: dir)
        XCTAssertTrue(manager.snippets.isEmpty)

        // The manager stores a pending error (consumed by the UI at display time).
        let error = manager.consumePendingLoadError()
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.lowercased().contains("version"))
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

    // MARK: - Manager: Live Reload

    @MainActor
    func testWatcherReloadsSnippetsOnFileChange() throws {
        let dir = makeTempDir()
        defer { cleanupTempDir(dir) }

        let manager = ContextSnippetsManager(configDirectory: dir)
        manager.startWatching()
        XCTAssertNil(manager.snippet(forBundleId: "com.example.Live"))

        let updated = """
        {
          "version": 1,
          "snippets": [
            { "bundleId": "com.example.Live", "appName": "Live", "context": "hot reload" }
          ]
        }
        """
        try updated.write(to: dir.appendingPathComponent("snippets.json"),
                          atomically: true, encoding: .utf8)

        // The watcher debounces on the main queue (0.25s); pump the runloop
        // until the reload lands or the generous cap expires.
        let deadline = Date().addingTimeInterval(3)
        while manager.snippet(forBundleId: "com.example.Live") == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(manager.snippet(forBundleId: "com.example.Live"),
                        "Editing snippets.json should apply without restarting Cai")
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
