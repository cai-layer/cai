import Foundation

// MARK: - Context Snippets Manager

/// Manages per-app context snippets persisted to `~/.config/cai/snippets.json`.
///
/// **v1 scope:** JSON-only, no inline editor UI. Power users edit the file
/// directly; a directory watcher reloads it on save (see `startWatching()`),
/// so edits apply without restarting Cai. Docs:
/// https://getcai.app/docs/usage/context-snippets/. Settings has a single
/// "Open snippets.json in Finder" button for discoverability. The v1.1 UI will
/// add in-memory CRUD methods and call `loadSnippets()` after saves.
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

    /// Pending load-failure message, captured at init time and consumed on first
    /// Cai invocation so the user sees the toast in context (not as a decontextualized
    /// floating pill at app launch). Call `consumePendingLoadError()` from the place
    /// that shows the Cai window.
    private var pendingLoadError: String?

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
        seedStarterFileIfMissing()
        loadSnippets()
    }

    // MARK: - Live Reload

    /// Watches `~/.config/cai/` and reloads snippets when the file changes, so
    /// hand edits apply without restarting Cai. Reuses `PendingChangeWatcher`,
    /// which is a generic debounced directory watcher despite its name (the
    /// rename is deferred so the in-flight helper PR isn't churned). Watching
    /// the directory rather than the file survives editors that save via
    /// temp-file-plus-rename, which would orphan a file-descriptor watch.
    private var watcher: PendingChangeWatcher?

    /// Starts live reload. Called once from `AppDelegate` at launch after the
    /// eager warm-up. MainActor because the watcher delivers on the main queue
    /// and `snippets` drives SwiftUI.
    @MainActor func startWatching() {
        guard watcher == nil else { return }
        let watcher = PendingChangeWatcher(directory: configDirectory) { [weak self] in
            self?.loadSnippets()
        }
        watcher.start()
        self.watcher = watcher
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
            postLoadFailureToast(reason: "Context Snippets: could not read snippets file")
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
                postLoadFailureToast(reason: "Context Snippets: file was created by a newer version of Cai")
                snippets = []
                return
            }

            snippets = file.snippets
        } catch {
            print("⚠️ ContextSnippets: failed to decode snippets.json: \(error.localizedDescription)")
            postLoadFailureToast(reason: "Context Snippets: JSON error")
            snippets = []
        }
    }

    /// Writes a starter file on first run so the file teaches its own schema:
    /// a `_docs` link plus one disabled example entry. A power user who opens
    /// it (Settings → Open in Finder) sees the exact shape to copy instead of
    /// an empty array. The example ships `enabled: false`, so seeding never
    /// changes behavior; flipping it on, or copying the entry, is the tutorial.
    ///
    /// `_docs` is an unknown key to `ContextSnippetsFile` and `JSONDecoder`
    /// ignores unknown keys, so it survives parsing untouched. The underscore
    /// prefix keeps it out of any future real schema field's namespace.
    ///
    /// Deliberately NO comments in the seed: strict JSON has none, and the
    /// v1.1 editor UI will rewrite this file through `JSONEncoder`, which
    /// would silently destroy user comments however they were smuggled in.
    /// Full examples stay canonical in the docs page.
    ///
    /// Note: snippets only require `bundleId`, `appName`, and `context` —
    /// `id` and `enabled` are optional in the file. See
    /// `ContextSnippet.init(from:)` for the custom decoder.
    private func seedStarterFileIfMissing() {
        guard !FileManager.default.fileExists(atPath: configFileURL.path) else { return }
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let starter = """
        {
          "version": 1,
          "_docs": "https://getcai.app/docs/usage/context-snippets/",
          "snippets": [
            {
              "bundleId": "com.apple.Terminal",
              "appName": "Terminal",
              "context": "When I copy from Terminal, I am usually debugging. Prefer technical, concise answers.",
              "enabled": false
            }
          ]
        }

        """
        try? starter.write(to: configFileURL, atomically: true, encoding: .utf8)
    }

    /// Captures a load-failure message to be shown the next time Cai is invoked.
    /// We defer the toast until the user opens Cai so the error is seen in context —
    /// showing a floating toast at app launch is easy to miss and confusing.
    private func postLoadFailureToast(reason: String) {
        pendingLoadError = "\(reason). Check console for details."
    }

    /// Returns and clears the pending load-error message. Called by the window
    /// controller when Cai is shown, so the toast fires once and then clears.
    func consumePendingLoadError() -> String? {
        defer { pendingLoadError = nil }
        return pendingLoadError
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
