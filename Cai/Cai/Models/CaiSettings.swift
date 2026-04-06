import AppKit
import Foundation
import HotKey
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
        static let installedExtensions = "cai_installedExtensions"
        static let appearance = "cai_appearance"
        // apiKey moved to Keychain — see KeychainHelper
    }

    // MARK: - Model Provider

    enum ModelProvider: String, CaseIterable, Identifiable {
        case builtIn = "Built-in"
        case apple = "Apple Intelligence"
        case lmstudio = "LM Studio"
        case ollama = "Ollama"
        case custom = "Custom"

        var id: String { rawValue }

        /// Base URL (without /v1) for each provider
        var defaultURL: String {
            switch self {
            case .builtIn: return "http://127.0.0.1:8690"
            case .apple: return ""  // No HTTP endpoint — uses FoundationModels framework
            case .lmstudio: return "http://127.0.0.1:1234"
            case .ollama: return "http://127.0.0.1:11434"
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
        didSet { defaults.set(translationLanguage, forKey: Keys.translationLanguage) }
    }

    @Published var modelProvider: ModelProvider {
        didSet { defaults.set(modelProvider.rawValue, forKey: Keys.modelProvider) }
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
        }
    }

    @Published var outputDestinations: [OutputDestination] {
        didSet {
            if let data = try? JSONEncoder().encode(outputDestinations) {
                defaults.set(data, forKey: Keys.outputDestinations)
            }
        }
    }

    /// Slugs of community extensions installed from the curated repo.
    @Published var installedExtensions: Set<String> {
        didSet {
            defaults.set(Array(installedExtensions), forKey: Keys.installedExtensions)
        }
    }

    /// Destinations that are enabled (shown in result view footer)
    var enabledDestinations: [OutputDestination] {
        outputDestinations.filter { $0.isEnabled && $0.isConfigured }
    }

    /// Destinations enabled AND marked for action list display (direct routing)
    var actionListDestinations: [OutputDestination] {
        outputDestinations.filter { $0.isEnabled && $0.showInActionList && $0.isConfigured }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    /// True when upgrading from GGUF to MLX — triggers ModelSetupView for download with progress UI.
    /// Transient (not persisted) — set during init if old `cai_builtInModelPath` key exists.
    var needsMLXMigration: Bool = false

    /// Resolved model base URL based on provider selection
    var modelURL: String {
        switch modelProvider {
        case .builtIn:
            return ""  // Uses MLXInference in-process, not HTTP
        case .apple:
            return ""  // Uses FoundationModels framework, not HTTP
        case .lmstudio, .ollama:
            return modelProvider.defaultURL
        case .custom:
            return customModelURL
        }
    }

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

    /// Optional API key for authenticated LLM providers (cloud APIs, LM Studio with auth).
    /// Empty string = no auth header sent. Stored in Keychain (encrypted at rest), never logged.
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                KeychainHelper.delete(forKey: "cai_apiKey")
            } else {
                KeychainHelper.set(apiKey, forKey: "cai_apiKey")
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

        self.customModelURL = defaults.string(forKey: Keys.customModelURL)
            ?? "http://127.0.0.1:8080"

        self.modelName = defaults.string(forKey: Keys.modelName) ?? ""

        self.builtInModelId = defaults.string(forKey: Keys.builtInModelId) ?? ""
        self.builtInSetupDone = defaults.bool(forKey: Keys.builtInSetupDone)

        self.crashReportingEnabled = defaults.bool(forKey: Keys.crashReportingEnabled)
        self.crashReportingPromptShown = defaults.bool(forKey: Keys.crashReportingPromptShown)

        self.hotKeyComboDict = defaults.dictionary(forKey: Keys.hotKeyCombo) as? [String: Int]
        self.aboutYou = defaults.string(forKey: Keys.aboutYou) ?? ""

        let savedHistorySize = defaults.integer(forKey: Keys.clipboardHistorySize)
        self.clipboardHistorySize = savedHistorySize > 0 ? savedHistorySize : 50

        let appearanceRaw = defaults.string(forKey: Keys.appearance) ?? Appearance.system.rawValue
        self.appearance = Appearance(rawValue: appearanceRaw) ?? .system

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

        let mapsRaw = defaults.string(forKey: Keys.mapsProvider) ?? MapsProvider.apple.rawValue
        self.mapsProvider = MapsProvider(rawValue: mapsRaw) ?? .apple

        if let data = defaults.data(forKey: Keys.shortcuts),
           let decoded = try? JSONDecoder().decode([CaiShortcut].self, from: data) {
            self.shortcuts = decoded
        } else {
            self.shortcuts = []
        }

        if let data = defaults.data(forKey: Keys.outputDestinations),
           let decoded = try? JSONDecoder().decode([OutputDestination].self, from: data) {
            self.outputDestinations = decoded
        } else {
            self.outputDestinations = BuiltInDestinations.all
        }

        let installedSlugs = defaults.stringArray(forKey: Keys.installedExtensions) ?? []
        self.installedExtensions = Set(installedSlugs)

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
