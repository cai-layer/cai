import Foundation

// MARK: - Context Snippets Manager

/// Manages per-app context snippets persisted to `~/.config/cai/snippets.json`.
///
/// **v1 scope (this PR):** JSON-only, no UI. Power users edit the file directly.
/// Changes require an app restart to take effect — documented in
/// `_docs/features/context-snippets.md`. The v1.1 UI will add in-memory CRUD
/// methods and call `loadSnippets()` after saves.
///
/// **Load flow:**
///
/// ```text
///   init() ──▶ seedEmptyFileIfMissing() ──▶ loadSnippets()
///                                              │
///                                              ├─ file missing  → snippets = []
///                                              ├─ file empty    → snippets = []
///                                              ├─ valid v1      → snippets = [...]
///                                              ├─ malformed     → [], toast
///                                              └─ version > 1   → [], toast "needs newer Cai"
/// ```
///
/// **Toast on failure:** Uses the same `.caiShowToast` notification pattern as
/// MLX model load failures in `AppDelegate`, so users see a visible signal when
/// their JSON has an error instead of silent fallback.
class ContextSnippetsManager: ObservableObject {

    static let shared = ContextSnippetsManager()

    // MARK: - Published State

    /// All loaded snippets. In v1 this is only mutated once at init (on load).
    /// The v1.1 UI will add CRUD methods that mutate this property and
    /// `@Published` will propagate changes to any observing views.
    @Published private(set) var snippets: [ContextSnippet] = []

    // MARK: - Config File Location

    private let configDirectory: URL
    private var configFileURL: URL {
        configDirectory.appendingPathComponent("snippets.json")
    }

    /// Designated initializer. Test-friendly — tests pass a temp directory;
    /// production uses the default `~/.config/cai/`.
    init(configDirectory: URL? = nil) {
        self.configDirectory = configDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cai", isDirectory: true)
        seedEmptyFileIfMissing()
        loadSnippets()
    }

    // MARK: - Persistence

    /// Reads `snippets.json` from disk and populates the in-memory `snippets` array.
    /// Safe to call multiple times — each call replaces the in-memory state.
    /// v1 only calls this once at init. v1.1 UI will call it after saves.
    func loadSnippets() {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            snippets = []
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: configFileURL)
        } catch {
            print("⚠️ ContextSnippets: failed to read snippets.json: \(error.localizedDescription)")
            postLoadFailureToast(reason: "Could not read snippets file")
            snippets = []
            return
        }

        // Empty file is a valid state (newly-seeded) — no toast, just empty list
        guard !data.isEmpty else {
            snippets = []
            return
        }

        do {
            let file = try JSONDecoder().decode(ContextSnippetsFile.self, from: data)

            // Reject files from future schema versions with a clear error.
            // See TODO "Context Snippets schema version migration" for the
            // forward-migration story when v2 ships.
            guard file.version == 1 else {
                print("⚠️ ContextSnippets: snippets.json has version \(file.version) — this Cai build only supports version 1. Update Cai to use this file.")
                postLoadFailureToast(reason: "Snippets file was created by a newer version of Cai")
                snippets = []
                return
            }

            snippets = file.snippets
        } catch {
            print("⚠️ ContextSnippets: failed to decode snippets.json: \(error.localizedDescription)")
            postLoadFailureToast(reason: "Snippets file has a JSON error")
            snippets = []
        }
    }

    /// Writes a minimal valid JSON file on first run so power users can find it
    /// when poking around `~/.config/cai/`. The help doc has the full schema and
    /// copy-paste examples.
    ///
    /// We explicitly do NOT seed with an example snippet because:
    /// - JSON doesn't support comments (a `_comment` field would be decoded as unknown)
    /// - Any placeholder `id` field would need to be a valid UUID or Swift's `UUID`
    ///   Codable decoder throws, silently breaking first-run
    /// - Examples belong in docs, not in the data file
    private func seedEmptyFileIfMissing() {
        guard !FileManager.default.fileExists(atPath: configFileURL.path) else { return }
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let empty = """
        {
          "version": 1,
          "snippets": []
        }

        """
        try? empty.write(to: configFileURL, atomically: true, encoding: .utf8)
    }

    /// Posts a `.caiShowToast` notification on the main thread so load failures
    /// are user-visible instead of silent. Same pattern as MLX model load failures
    /// in `AppDelegate.startBuiltInLLMAndAutoDetect`.
    private func postLoadFailureToast(reason: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .caiShowToast, object: nil,
                userInfo: ["message": "\(reason). Check console for details."]
            )
        }
    }

    // MARK: - Lookup

    /// Returns the enabled snippet matching the given bundle ID, or nil.
    ///
    /// Returns nil when:
    /// - `bundleId` is nil or empty string
    /// - No snippet matches `bundleId`
    /// - The matching snippet has `enabled: false`
    ///
    /// If multiple snippets share the same `bundleId` (shouldn't happen via the
    /// v1.1 UI, but the JSON schema allows it), the first enabled one wins —
    /// deterministic and predictable for users hand-editing the file.
    func snippet(forBundleId bundleId: String?) -> ContextSnippet? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        return snippets.first { $0.bundleId == bundleId && $0.enabled }
    }
}
