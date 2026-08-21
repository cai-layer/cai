import AppKit
import CaiActionCore
import Foundation
import HotKey
import os.log
import ServiceManagement
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Persistent user settings stored in UserDefaults.
class CaiSettings: ObservableObject {
    static let shared = CaiSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let searchURL = "cai_searchURL"
        static let translationLanguage = "cai_translationLanguage"
        static let modelProvider = "cai_modelProvider"
        static let customModelURL = "cai_customModelURL"
        static let modelName = "cai_modelName"
        static let mapsProvider = "cai_mapsProvider"
        static let launchAtLogin = "cai_launchAtLogin"
        static let shortcuts = "cai_shortcuts"
        static let outputDestinations = "cai_outputDestinations"
        static let builtInModelId = "cai_builtInModelId"
        static let builtInSetupDone = "cai_builtInSetupDone"
        static let crashReportingEnabled = "cai_crashReportingEnabled"
        static let crashReportingPromptShown = "cai_crashReportingPromptShown"
        static let hotKeyCombo = "cai_hotKeyCombo"
        static let aboutYou = "cai_aboutYou"
        static let clipboardHistorySize = "cai_clipboardHistorySize"
        static let pressReturnToSend = "cai_pressReturnToSend"
        static let installedExtensions = "cai_installedExtensions"
        static let hiddenBuiltInActions = "cai_hiddenBuiltInActions"
        static let appearance = "cai_appearance"
        static let anthropicModelName = "cai_anthropicModelName"
        static let openRouterModelName = "cai_openRouterModelName"
        static let allowAgentProposals = "cai_allowAgentProposals"
        static let migratedPasteBackDefaultsV3 = "cai_migratedPasteBackDefaultsV3"
        static let migratedShellTemplatesV2 = "cai_migratedShellTemplatesV2"
        // apiKey moved to Keychain — see KeychainHelper
    }

    // MARK: - Model Provider

    enum ModelProvider: String, CaseIterable, Identifiable {
        case builtIn = "Built-in"
        case apple = "Apple Intelligence"
        case lmstudio = "LM Studio"
        case ollama = "Ollama"
        case anthropic = "Anthropic"
        case openrouter = "OpenRouter"
        case custom = "Custom"

        var id: String { rawValue }

        /// Base URL (without /v1) for each provider
        var defaultURL: String {
            switch self {
            case .builtIn: return "http://127.0.0.1:8690"
            case .apple: return ""  // No HTTP endpoint, uses FoundationModels framework.
            case .lmstudio: return "http://127.0.0.1:1234"
            case .ollama: return "http://127.0.0.1:11434"
            case .anthropic: return "https://api.anthropic.com"
            case .openrouter: return "https://openrouter.ai/api"
            case .custom: return ""
            }
        }
    }

    // MARK: - Maps Provider

    enum MapsProvider: String, CaseIterable, Identifiable {
        case apple = "Apple Maps"
        case google = "Google Maps"

        var id: String { rawValue }
    }

    // MARK: - Appearance

    enum Appearance: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        var id: String { rawValue }
    }

    // MARK: - Published Properties

    /// Base search URL. Query is percent-encoded and appended.
    @Published var searchURL: String {
        didSet { defaults.set(searchURL, forKey: Keys.searchURL) }
    }

    @Published var translationLanguage: String {
        didSet {
            defaults.set(translationLanguage, forKey: Keys.translationLanguage)
            NotificationCenter.default.post(name: .caiInvalidateActionCache, object: nil)
        }
    }

    @Published var modelProvider: ModelProvider {
        didSet {
            defaults.set(modelProvider.rawValue, forKey: Keys.modelProvider)
            // Free MLX model memory (~2 GB for Ministral 3B) when the user switches
            // away from the built-in provider. Without this, the model stays resident
            // even though it's never used by the new provider.
            if oldValue == .builtIn && modelProvider != .builtIn {
                Task { await MLXInference.shared.unload() }
            }
        }
    }

    /// True once a provider has been persisted — the user picked one, or first-launch
    /// onboarding/auto-detect established one. When false (fresh install, or a legacy
    /// user who never had a provider key) auto-detect may probe for a running provider.
    /// When true, auto-detect must be skipped: a provider that is merely unavailable at
    /// launch (Apple Intelligence on macOS < 26, a local server not started yet, an offline
    /// cloud provider) would otherwise be silently reverted to built-in and persisted. See #35.
    var hasExplicitProvider: Bool {
        Self.providerIsExplicit(persistedValue: defaults.object(forKey: Keys.modelProvider))
    }

    /// Pure predicate behind `hasExplicitProvider`, extracted for unit tests (see #35).
    /// "Explicit" means the provider key has been persisted at all — by a user choice or
    /// by first-launch onboarding/auto-detect. Presence is what matters, not the value:
    /// even a persisted `.builtIn` counts, so auto-detect won't re-run and revert it.
    static func providerIsExplicit(persistedValue: Any?) -> Bool {
        persistedValue != nil
    }

    /// Only used when modelProvider == .custom
    @Published var customModelURL: String {
        didSet { defaults.set(customModelURL, forKey: Keys.customModelURL) }
    }

    /// Optional model name override. When set, this is sent in API requests
    /// instead of auto-detecting the first available model. Leave blank to auto-detect.
    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    @Published var mapsProvider: MapsProvider {
        didSet { defaults.set(mapsProvider.rawValue, forKey: Keys.mapsProvider) }
    }

    @Published var shortcuts: [CaiShortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) {
                defaults.set(data, forKey: Keys.shortcuts)
            }
            NotificationCenter.default.post(name: .caiInvalidateActionCache, object: nil)
        }
    }

    @Published var outputDestinations: [OutputDestination] {
        didSet {
            if let data = try? JSONEncoder().encode(outputDestinations) {
                defaults.set(data, forKey: Keys.outputDestinations)
            }
            NotificationCenter.default.post(name: .caiInvalidateActionCache, object: nil)
        }
    }

    /// Slugs of community extensions installed from the curated repo.
    @Published var installedExtensions: Set<String> {
        didSet {
            defaults.set(Array(installedExtensions), forKey: Keys.installedExtensions)
        }
    }

    /// `ActionItem.id` values (e.g. `"reply"`, `"summarize"`) the user has hidden
    /// from the default action list. Hidden actions remain reachable via type-to-filter.
    @Published var hiddenBuiltInActions: Set<String> {
        didSet {
            defaults.set(Array(hiddenBuiltInActions), forKey: Keys.hiddenBuiltInActions)
            NotificationCenter.default.post(name: .caiInvalidateActionCache, object: nil)
        }
    }

    /// Destinations that are enabled (shown in result view footer).
    /// `chainOnly` destinations are excluded — they exist purely as chain
    /// terminal steps and surfacing them in the result view would duplicate
    /// existing affordances (e.g. Enter on a result already copies it).
    var enabledDestinations: [OutputDestination] {
        outputDestinations.filter { $0.isEnabled && $0.isConfigured && !$0.chainOnly }
    }

    /// Destinations enabled AND marked for action list display (direct routing).
    /// Same `chainOnly` exclusion as `enabledDestinations`.
    var actionListDestinations: [OutputDestination] {
        outputDestinations.filter {
            $0.isEnabled && $0.showInActionList && $0.isConfigured && !$0.chainOnly
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    /// When true, a bare Return submits and Shift+Return inserts a newline. Default
    /// false (Cmd+Return submits, plain Return inserts a newline). Cmd+Return always
    /// submits in both modes. Applies to every `MultilineTextEditor` composer — the
    /// Ask AI prompt, follow-ups, custom prompts, and the MCP issue/comment + custom
    /// destination body fields all follow the same rule.
    @Published var pressReturnToSend: Bool {
        didSet {
            defaults.set(pressReturnToSend, forKey: Keys.pressReturnToSend)
        }
    }

    /// The kill switch for agent authoring: "Allow agents to propose actions".
    ///
    /// Default ON, because wiring the `cai-mcp` helper into an agent is itself
    /// the explicit opt-in and nothing an agent proposes can run before the
    /// user approves it here. Off means the app stops looking at the pending
    /// directory entirely and the helper refuses new proposals.
    @Published var allowAgentProposals: Bool {
        didSet {
            defaults.set(allowAgentProposals, forKey: Keys.allowAgentProposals)
            // Takes effect immediately rather than at next launch, so the
            // switch means what its caption says.
            let enabled = allowAgentProposals
            Task { @MainActor in
                if enabled {
                    PendingChangeStore.shared.startIfEnabled()
                } else {
                    PendingChangeStore.shared.stop()
                }
                // Republish, or the switch is a lie to the helper. The flag
                // travels inside the snapshot and the publisher only rewrites
                // it on `caiInvalidateActionCache`, which flipping this does
                // not post. Without this the helper keeps reading the old
                // value: switched off, it accepts proposals and tells the
                // agent they are waiting while the app has stopped watching,
                // so they pile up unseen until the queue caps out; switched
                // back on, it refuses with "the user turned this off" until
                // some unrelated edit happens to fire the notification.
                ActionsSnapshotPublisher.shared.publishNow()
            }
        }
    }

    /// True when upgrading from GGUF to MLX — triggers ModelSetupView for download with progress UI.
    /// Transient (not persisted) — set during init if old `cai_builtInModelPath` key exists.
    var needsMLXMigration: Bool = false

    /// Normalizes a user-entered OpenAI-compatible base URL so callers can
    /// safely append `/v1/...`. Users routinely paste the full base_url ending
    /// in `/v1` (what the OpenAI SDK, LM Studio, and every tutorial hand them)
    /// or a reverse-proxy subpath like `/llama/v1`. Without this we'd build
    /// `.../v1/v1/models` and silently get an empty model list.
    /// See https://github.com/cai-layer/cai/issues/28.
    static func normalizedEndpoint(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") { s.removeLast(3) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Resolved model base URL based on provider selection
    var modelURL: String {
        switch modelProvider {
        case .builtIn:
            return ""  // Uses MLXInference in-process, not HTTP
        case .apple:
            return ""  // Uses FoundationModels framework, not HTTP
        case .lmstudio, .ollama:
            return modelProvider.defaultURL
        case .anthropic:
            return "https://api.anthropic.com"
        case .openrouter:
            return "https://openrouter.ai/api"
        case .custom:
            return Self.normalizedEndpoint(customModelURL)
        }
    }

    /// Anthropic model name (e.g. "claude-sonnet-4-6").
    /// Hardcoded picker in Settings, Anthropic has no /v1/models endpoint.
    @Published var anthropicModelName: String {
        didSet { defaults.set(anthropicModelName, forKey: Keys.anthropicModelName) }
    }

    /// Default Anthropic model ID. Users can override in Settings.
    static let defaultAnthropicModel = "claude-sonnet-4-6"

    /// OpenRouter model slug (e.g. "openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet").
    /// Routed through OpenRouter's OpenAI-compatible chat completions endpoint.
    /// Users pick the slug from the model list at openrouter.ai/models.
    @Published var openRouterModelName: String {
        didSet { defaults.set(openRouterModelName, forKey: Keys.openRouterModelName) }
    }

    /// Default OpenRouter model slug. Cheap and fast, a reasonable starting point.
    static let defaultOpenRouterModel = "openai/gpt-4o-mini"

    /// HuggingFace model ID for the built-in MLX model (e.g., "mlx-community/Ministral-3-3B-Instruct-2512-4bit")
    @Published var builtInModelId: String {
        didSet { defaults.set(builtInModelId, forKey: Keys.builtInModelId) }
    }

    /// Whether the built-in model setup has been completed at least once
    @Published var builtInSetupDone: Bool {
        didSet { defaults.set(builtInSetupDone, forKey: Keys.builtInSetupDone) }
    }

    /// Whether crash reporting is enabled (opt-in, default false)
    @Published var crashReportingEnabled: Bool {
        didSet {
            defaults.set(crashReportingEnabled, forKey: Keys.crashReportingEnabled)
            if crashReportingEnabled {
                CrashReportingService.shared.startIfEnabled()
            } else {
                CrashReportingService.shared.stop()
            }
        }
    }

    /// Whether the one-time crash reporting prompt has been shown
    @Published var crashReportingPromptShown: Bool {
        didSet { defaults.set(crashReportingPromptShown, forKey: Keys.crashReportingPromptShown) }
    }

    /// Optional API key for OpenAI-compatible LLM providers (LM Studio, Ollama, Custom).
    /// Empty string = no auth header sent. Stored in Keychain (encrypted at rest), never logged.
    /// Anthropic uses a separate key — see `anthropicApiKey`.
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                KeychainHelper.delete(forKey: "cai_apiKey")
            } else {
                KeychainHelper.set(apiKey, forKey: "cai_apiKey")
            }
        }
    }

    /// Dedicated API key for Anthropic (Claude API). Separate from `apiKey` to prevent
    /// cross-provider key leakage, Anthropic uses `x-api-key` header, not Bearer.
    @Published var anthropicApiKey: String {
        didSet {
            if anthropicApiKey.isEmpty {
                KeychainHelper.delete(forKey: "cai_anthropicApiKey")
            } else {
                KeychainHelper.set(anthropicApiKey, forKey: "cai_anthropicApiKey")
            }
        }
    }

    /// Dedicated API key for OpenRouter. Kept separate from the shared `apiKey`
    /// so users can configure OpenRouter alongside a local LM Studio / Ollama
    /// server without the keys getting crossed.
    @Published var openRouterApiKey: String {
        didSet {
            if openRouterApiKey.isEmpty {
                KeychainHelper.delete(forKey: "cai_openRouterApiKey")
            } else {
                KeychainHelper.set(openRouterApiKey, forKey: "cai_openRouterApiKey")
            }
        }
    }

    /// Custom hotkey combo stored as dictionary. nil = default (Option+C).
    /// Freeform "About You" context injected into every LLM system prompt.
    /// Max 500 characters. Empty means no injection.
    @Published var aboutYou: String {
        didSet { defaults.set(aboutYou, forKey: Keys.aboutYou) }
    }

    static let aboutYouMaxLength = 500

    /// Clipboard history size presets for the Settings picker.
    static let historySizePresets = [10, 25, 50, 100]

    @Published var clipboardHistorySize: Int {
        didSet { defaults.set(clipboardHistorySize, forKey: Keys.clipboardHistorySize) }
    }

    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Applies the user's appearance preference to the app.
    func applyAppearance() {
        switch appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @Published var hotKeyComboDict: [String: Int]? {
        didSet {
            defaults.set(hotKeyComboDict, forKey: Keys.hotKeyCombo)
            NotificationCenter.default.post(name: .caiHotKeyChanged, object: nil)
        }
    }

    /// Default hotkey: Option+C
    static let defaultKeyCombo = KeyCombo(key: .c, modifiers: [.option])

    /// Resolved key combo — custom if set, otherwise default Option+C
    var keyCombo: KeyCombo {
        get {
            if let dict = hotKeyComboDict {
                // Convert [String: Int] to [String: Any] for KeyCombo
                let anyDict: [String: Any] = dict.mapValues { $0 as Any }
                if let combo = KeyCombo(dictionary: anyDict) {
                    return combo
                }
            }
            return Self.defaultKeyCombo
        }
        set {
            // Convert KeyCombo.dictionary ([String: Any]) to [String: Int] for Codable storage
            let dict = newValue.dictionary
            hotKeyComboDict = dict.compactMapValues { $0 as? Int }
        }
    }

    /// Resets hotkey to default Option+C
    func resetHotKey() {
        hotKeyComboDict = nil
    }

    // MARK: - Common Languages

    static let defaultSearchURL = "https://search.brave.com/search?q="

    static let commonLanguages = [
        "English", "Spanish", "French", "German", "Italian",
        "Portuguese", "Chinese", "Japanese", "Korean", "Arabic",
        "Russian", "Hindi", "Dutch", "Swedish", "Turkish"
    ]

    // MARK: - Init

    private init() {
        self.searchURL = defaults.string(forKey: Keys.searchURL)
            ?? Self.defaultSearchURL

        self.translationLanguage = defaults.string(forKey: Keys.translationLanguage)
            ?? "English"

        let providerRaw = defaults.string(forKey: Keys.modelProvider) ?? ModelProvider.lmstudio.rawValue
        self.modelProvider = ModelProvider(rawValue: providerRaw) ?? .lmstudio

        // Default to empty string so that selecting Custom without a configured URL
        // short-circuits the status check (see LLMService.checkStatus guard on
        // `baseURL.isEmpty`) and avoids noisy CFNetwork "Connection refused" logs.
        // The TextField in Settings shows "http://127.0.0.1:8080" as a placeholder.
        self.customModelURL = defaults.string(forKey: Keys.customModelURL) ?? ""

        self.modelName = defaults.string(forKey: Keys.modelName) ?? ""

        self.builtInModelId = defaults.string(forKey: Keys.builtInModelId) ?? ""
        self.builtInSetupDone = defaults.bool(forKey: Keys.builtInSetupDone)

        self.crashReportingEnabled = defaults.bool(forKey: Keys.crashReportingEnabled)
        self.crashReportingPromptShown = defaults.bool(forKey: Keys.crashReportingPromptShown)

        self.pressReturnToSend = defaults.bool(forKey: Keys.pressReturnToSend)

        // Defaults ON: `bool(forKey:)` is false for an unset key, so read the
        // object first and only fall back to true when nothing is stored.
        self.allowAgentProposals = defaults.object(forKey: Keys.allowAgentProposals) as? Bool ?? true

        self.hotKeyComboDict = defaults.dictionary(forKey: Keys.hotKeyCombo) as? [String: Int]
        self.aboutYou = defaults.string(forKey: Keys.aboutYou) ?? ""

        let savedHistorySize = defaults.integer(forKey: Keys.clipboardHistorySize)
        self.clipboardHistorySize = savedHistorySize > 0 ? savedHistorySize : 50

        let appearanceRaw = defaults.string(forKey: Keys.appearance) ?? Appearance.system.rawValue
        self.appearance = Appearance(rawValue: appearanceRaw) ?? .system

        self.anthropicModelName = defaults.string(forKey: Keys.anthropicModelName)
            ?? Self.defaultAnthropicModel

        self.openRouterModelName = defaults.string(forKey: Keys.openRouterModelName)
            ?? Self.defaultOpenRouterModel

        // API key: read from Keychain, migrate from UserDefaults if needed
        if let keychainKey = KeychainHelper.get(forKey: "cai_apiKey") {
            self.apiKey = keychainKey
        } else if let legacyKey = defaults.string(forKey: "cai_apiKey"), !legacyKey.isEmpty {
            // One-time migration from UserDefaults → Keychain
            KeychainHelper.set(legacyKey, forKey: "cai_apiKey")
            defaults.removeObject(forKey: "cai_apiKey")
            self.apiKey = legacyKey
        } else {
            self.apiKey = ""
        }

        // Anthropic API key: separate Keychain entry
        if let anthropicKey = KeychainHelper.get(forKey: "cai_anthropicApiKey") {
            self.anthropicApiKey = anthropicKey
        } else {
            self.anthropicApiKey = ""
        }

        // OpenRouter API key: separate Keychain entry
        if let openRouterKey = KeychainHelper.get(forKey: "cai_openRouterApiKey") {
            self.openRouterApiKey = openRouterKey
        } else {
            self.openRouterApiKey = ""
        }

        let mapsRaw = defaults.string(forKey: Keys.mapsProvider) ?? MapsProvider.apple.rawValue
        self.mapsProvider = MapsProvider(rawValue: mapsRaw) ?? .apple

        // Load shortcuts into a local var, run the migration on it, then assign
        // to `self.shortcuts` once. Swift's definite-init requires all stored
        // properties to be initialized before any can be read via `self`, so
        // the migration must operate on the local before assigning.
        var loadedShortcuts: [CaiShortcut]
        if let data = defaults.data(forKey: Keys.shortcuts),
           let decoded = try? JSONDecoder().decode([CaiShortcut].self, from: data) {
            loadedShortcuts = decoded
        } else {
            loadedShortcuts = []
        }

        // Narrow shell-template migration: rewrite v1 `'{{result}}'` patterns
        // to v2 `{{result|shell}}` syntax. Single mechanical rewrite, idempotent.
        // Runs once per user behind a one-shot flag. Every rewrite logged so
        // users can audit via Console.app (`subsystem == com.soyasis.cai`).
        // See `_docs/planning/active/SHELL-TODOS.md` "Updates 2026-05-03" for spec.
        if !defaults.bool(forKey: Keys.migratedShellTemplatesV2) {
            let migrationLog = Logger(subsystem: "com.soyasis.cai", category: "migration")
            var rewriteCount = 0
            for i in loadedShortcuts.indices where loadedShortcuts[i].type == .shell {
                let original = loadedShortcuts[i].value
                let rewritten = TemplateEngine.migrateShellTemplate(original)
                if rewritten != original {
                    loadedShortcuts[i].value = rewritten
                    rewriteCount += 1
                    migrationLog.notice(
                        "Shell template migrated for shortcut \(loadedShortcuts[i].name, privacy: .public): \(original, privacy: .public) -> \(rewritten, privacy: .public)"
                    )
                }
            }
            if rewriteCount > 0 {
                // Persist by hand — didSet doesn't fire during init.
                if let data = try? JSONEncoder().encode(loadedShortcuts) {
                    defaults.set(data, forKey: Keys.shortcuts)
                }
                migrationLog.notice("Shell-template migration complete: \(rewriteCount) shortcut(s) rewritten")
            }
            defaults.set(true, forKey: Keys.migratedShellTemplatesV2)
        }

        self.shortcuts = loadedShortcuts

        if let data = defaults.data(forKey: Keys.outputDestinations),
           let decoded = try? JSONDecoder().decode([OutputDestination].self, from: data) {
            // Seed any built-in destinations added after the user's first launch.
            // Existing users loaded `decoded` from UserDefaults, so new entries in
            // `BuiltInDestinations.all` won't appear otherwise.
            let existingIds = Set(decoded.map(\.id))
            let missingBuiltIns = BuiltInDestinations.all.filter { !existingIds.contains($0.id) }
            var working = missingBuiltIns.isEmpty ? decoded : decoded + missingBuiltIns

            // One-shot migration: promote Replace Selection to on-by-default and
            // position 0 (Cmd+1). Runs once per user; after that, their order and
            // enabled state is their own. Intentionally overrides explicit opt-out
            // from the brief window where paste-back shipped as off-by-default.
            var migrationChanged = !missingBuiltIns.isEmpty
            if !defaults.bool(forKey: Keys.migratedPasteBackDefaultsV3) {
                let pasteBackId = BuiltInDestinations.pasteBack.id
                if let idx = working.firstIndex(where: { $0.id == pasteBackId }) {
                    var pasteBack = working.remove(at: idx)
                    pasteBack.isEnabled = true
                    working.insert(pasteBack, at: 0)
                    migrationChanged = true
                }
                defaults.set(true, forKey: Keys.migratedPasteBackDefaultsV3)
            }

            self.outputDestinations = working
            // didSet doesn't fire during init, so persist by hand when a
            // migration mutated the list — otherwise it re-runs every launch.
            if migrationChanged, let data = try? JSONEncoder().encode(working) {
                defaults.set(data, forKey: Keys.outputDestinations)
            }
        } else {
            self.outputDestinations = BuiltInDestinations.all
            // Fresh install — canonical order already matches, just set the flag
            // so the migration doesn't run next launch.
            defaults.set(true, forKey: Keys.migratedPasteBackDefaultsV3)
        }

        let installedSlugs = defaults.stringArray(forKey: Keys.installedExtensions) ?? []
        self.installedExtensions = Set(installedSlugs)

        let hiddenIds = defaults.stringArray(forKey: Keys.hiddenBuiltInActions) ?? []
        self.hiddenBuiltInActions = Set(hiddenIds)

        // Default to true for launch at login — bool(forKey:) returns false when key is absent,
        // so we check if the key has ever been set explicitly.
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        } else {
            self.launchAtLogin = true
            defaults.set(true, forKey: Keys.launchAtLogin)
            updateLaunchAtLogin(true)
        }

        // Snapshot state BEFORE auto-recovery so we can detect genuine migration
        // vs. a user who has already successfully migrated to MLX.
        let hadExplicitMLXId = !builtInModelId.isEmpty
        // Check for non-empty legacy key — empty string would falsely trigger migration.
        let legacyPath = defaults.string(forKey: "cai_builtInModelPath")
        let hadLegacyGGUFKey = !(legacyPath?.isEmpty ?? true)

        // Auto-recover: if model ID is empty but setup was done, use the default model
        if builtInSetupDone && builtInModelId.isEmpty {
            self.builtInModelId = ModelCatalog.defaultModelId
            defaults.set(ModelCatalog.defaultModelId, forKey: Keys.builtInModelId)
            print("🔄 Auto-recovered built-in model ID: \(ModelCatalog.defaultModelId)")
        }

        // GGUF→MLX migration detection: only if user had GGUF AND never set up MLX.
        // If they already have an explicit MLX model ID, they've migrated — clean up the stale key.
        if builtInSetupDone && hadLegacyGGUFKey && !hadExplicitMLXId {
            needsMLXMigration = true
            print("🔄 GGUF→MLX migration detected — will show setup window for download")
        } else if hadLegacyGGUFKey && hadExplicitMLXId {
            // User already migrated via Settings download path — clean up stale GGUF key
            defaults.removeObject(forKey: "cai_builtInModelPath")
            print("🧹 Cleaned up stale GGUF path key (user already on MLX)")
        }

        // One-time migration: move Anthropic key from shared apiKey to dedicated entry
        if modelProvider == .anthropic,
           anthropicApiKey.isEmpty,
           apiKey.hasPrefix("sk-ant-") {
            anthropicApiKey = apiKey
            apiKey = ""
        }
    }

    // MARK: - Chain Resolution

    /// Names of `.action(name:)` chain steps that don't resolve to any local
    /// Cai action OR destination. Used to flag chains imported from extensions
    /// whose dependencies aren't installed yet.
    ///
    /// Apple Shortcuts and inline LLM steps are intentionally not checked:
    /// - `.appleShortcut`: querying Shortcuts.app is async and brittle; let
    ///   the runtime surface a clear error if it's missing
    /// - `.inlineLLM`: always resolvable (only requires LLM configured)
    func unresolvedChainSteps(in next: [ChainStep]) -> [String] {
        // Built-ins are deliberately excluded here: this call feeds the "chain
        // needs: ..." badge on imported extensions, which has always flagged
        // only shortcuts and destinations.
        //
        // Called once per row while the management lists render, and those
        // rebuild on every hover, so the name set is built lazily: an action
        // with no chain steps costs nothing.
        ChainResolution.unresolvedChainStepNames(
            in: next,
            knownNames: Set(shortcuts.map(\.name)).union(outputDestinations.map(\.name))
        )
    }

    // MARK: - CaiActionCore Bridging

    /// Everything an authored action can collide with or chain into, in the
    /// shape `ActionValidator` and the approval sheet expect. Built here so
    /// the validator never reaches for this singleton itself.
    var knownActions: KnownActions {
        KnownActions(
            shortcuts: shortcutSnapshots,
            destinations: destinationSummaries,
            builtInActionNames: BuiltInActionID.allCases.filter(\.isChainable).map(\.displayLabel)
        )
    }

    private var shortcutSnapshots: [ActionSnapshot] {
        shortcuts.map(\.actionSnapshot)
    }

    /// Destination names and kinds, plus the two derived facts capability chips
    /// need. Configs (webhook URLs, headers, AppleScript templates) still
    /// deliberately stay out of the authoring surface — what crosses is a host
    /// and a role, and `DestinationSummary` keeps both out of its Codable shape
    /// so neither reaches `actions-snapshot.json` or an agent.
    private var destinationSummaries: [DestinationSummary] {
        outputDestinations.map { destination in
            let kind: DestinationSummary.Kind
            var networkTarget: String?
            switch destination.type {
            case .applescript: kind = .applescript
            case .webhook(let config):
                kind = .webhook
                networkTarget = Self.webhookHost(config.url)
            case .deeplink(let template):
                kind = .deeplink
                networkTarget = Self.deeplinkScheme(template)
            case .shell: kind = .shell
            case .pasteBack: kind = .pasteBack
            case .clipboardCopy: kind = .clipboardCopy
            }
            return DestinationSummary(
                name: destination.name,
                kind: kind,
                networkTarget: networkTarget,
                builtInRole: Self.builtInRole(for: destination)
            )
        }
    }

    /// Built-in destinations by their fixed UUID, never by display name. A
    /// user-authored destination renamed "Save to Notes" must not borrow the
    /// built-in's chip.
    private static func builtInRole(for destination: OutputDestination) -> BuiltInDestinationRole? {
        guard destination.isBuiltIn else { return nil }
        switch destination.id {
        case BuiltInDestinations.email.id: return .mailDraft
        case BuiltInDestinations.notes.id: return .notes
        case BuiltInDestinations.reminders.id: return .reminders
        case BuiltInDestinations.pasteBack.id: return .replaceSelection
        case BuiltInDestinations.clipboard.id: return .clipboard
        default: return nil
        }
    }

    /// The host of a webhook URL, and nothing else.
    ///
    /// Host-only is the whole point: for a Slack incoming webhook the path is
    /// the credential and the host is public. A templated authority yields nil
    /// rather than a guess — `CapabilityDetector.host(inURLTemplate:)` holds the
    /// same rule for url actions, including the `https://github.com@evil.com/`
    /// userinfo trick that a hand-rolled split gets wrong.
    static func webhookHost(_ url: String) -> String? {
        CapabilityDetector.host(inURLTemplate: url)
    }

    /// A deeplink's scheme, with no host claimed. `obsidian://open?vault=…` is
    /// "opens obsidian://": the host segment of a custom-scheme URL is not a
    /// network destination and vouching for it would be inventing precision.
    static func deeplinkScheme(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.prefix { $0 != ":" }.lowercased()
        guard !scheme.isEmpty, scheme.count < 32, trimmed.dropFirst(scheme.count).hasPrefix("://"),
              scheme.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "+") })
        else { return nil }
        return scheme
    }

    /// Whether an endpoint keeps the selection on this Mac.
    ///
    /// Pure and static so the claim can be table-tested: "Runs on-device AI" is
    /// a privacy statement in Cai's own voice, and the failure that matters is
    /// over-claiming. Parsed with `URLComponents` rather than a substring
    /// search, so `http://127.0.0.1@evil.com/` reads as the host `evil.com`
    /// (loopback in the userinfo is the obvious spoof) and
    /// `http://localhost.evil.com/` is not localhost. An unset endpoint is
    /// unknown, and unknown is not local.
    static func endpointIsOnDevice(_ url: String) -> Bool {
        // `host` may arrive bracketed for IPv6 depending on the SDK, so both
        // spellings count.
        let loopback: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return loopback.contains(host)
    }

    /// The engine the AI capability chip names, and whether Cai can honestly
    /// call it on-device.
    ///
    /// "On-device" is claimed only where it is guaranteed: the built-in MLX
    /// model and Apple Intelligence run in-process with no endpoint at all, and
    /// a configured endpoint counts only when its host is loopback. LM Studio
    /// and Ollama default to localhost but the user can point either at another
    /// machine, and telling someone their selection stayed on their Mac when it
    /// did not is exactly the false reassurance these chips exist to avoid. When
    /// in doubt the chip says "Sends to", which is the safe direction.
    var aiEngine: ActionReviewPresentation.AIEngine {
        switch modelProvider {
        case .builtIn, .apple:
            // In-process, no endpoint at all. The only two that are on-device
            // by construction rather than by configuration.
            return .init(name: modelProvider.rawValue, isOnDevice: true, isInProcess: true)
        default:
            // Everything else has a configurable endpoint, so honesty comes
            // from the endpoint and not from the provider's reputation. An
            // empty one is unconfigured, not local: claiming on-device for a
            // custom provider with no URL set would be an over-claim in exactly
            // the direction these chips exist to prevent.
            return .init(
                name: modelProvider.rawValue,
                isOnDevice: Self.endpointIsOnDevice(modelURL)
            )
        }
    }

    // MARK: - Built-In Model

    /// Returns a display name for the current built-in model ID.
    /// e.g., "mlx-community/Ministral-3-3B-Instruct-2512-4bit" → "Ministral 3B"
    var builtInModelDisplayName: String {
        // Check curated models for a friendly name
        if let curated = ModelCatalog.curatedModels.first(where: { $0.id == builtInModelId }) {
            return curated.name
        }
        // Fallback: extract the last path component of the model ID
        return builtInModelId.components(separatedBy: "/").last ?? builtInModelId
    }

    // MARK: - Provider Auto-Detection

    /// Known provider endpoints to probe, in priority order.
    /// LM Studio first (fastest inference), then Ollama, then common alternatives.
    private static let providerProbes: [(provider: ModelProvider?, url: String)] = [
        (.lmstudio, "http://127.0.0.1:1234"),
        (.ollama,   "http://127.0.0.1:11434"),
        (nil,       "http://127.0.0.1:1337"),   // Jan AI
        (nil,       "http://127.0.0.1:8080"),   // LocalAI / Open WebUI
        (nil,       "http://127.0.0.1:4891"),   // GPT4All
    ]

    /// Probes known provider URLs and selects the first one that responds.
    /// Only call this when `hasExplicitProvider` is false (first launch).
    func autoDetectProvider() async {
        // Respect an explicitly chosen provider. Auto-detect is a first-launch / legacy
        // convenience; once a provider is persisted, a transient unavailability at launch
        // must never silently revert the user to built-in (see #35). Enforced here so no
        // caller can reintroduce the override.
        if hasExplicitProvider {
            print("Provider explicitly set — skipping auto-detect")
            return
        }

        // Apple Intelligence — highest priority, zero setup.
        // Only auto-select on subsequent launches (builtInSetupDone already true).
        // On first launch, the ModelSetupView handles the Apple Intelligence recommendation
        // so the user sees the onboarding and can choose.
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let setupDone = await MainActor.run { self.builtInSetupDone }
            if setupDone && SystemLanguageModel.default.availability == .available {
                await MainActor.run {
                    self.modelProvider = .apple
                    print("Auto-detected Apple Intelligence")
                }
                return
            }
        }
        #endif

        for probe in Self.providerProbes {
            guard let url = URL(string: "\(probe.url)/v1/models") else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 2

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                // Verify server responds 200 AND has at least one model loaded
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]],
                   !models.isEmpty {
                    await MainActor.run {
                        if let knownProvider = probe.provider {
                            self.modelProvider = knownProvider
                            print("Auto-detected provider: \(knownProvider.rawValue)")
                        } else {
                            // Not a built-in provider — use Custom with this URL
                            self.modelProvider = .custom
                            self.customModelURL = probe.url
                            print("Auto-detected custom provider at \(probe.url)")
                        }
                    }
                    return
                }
            } catch {
                continue
            }
        }
        // No external provider found — use built-in MLX if setup was done
        if builtInSetupDone {
            await MainActor.run {
                if builtInModelId.isEmpty {
                    self.builtInModelId = ModelCatalog.defaultModelId
                }
                self.modelProvider = .builtIn
                print("No external provider — using built-in MLX LLM")
            }
            return
        }
        print("No running LLM provider detected")
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                print("Launch at Login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                print("Launch at Login disabled")
            }
        } catch {
            print("Failed to update Launch at Login: \(error)")
        }
    }
}
