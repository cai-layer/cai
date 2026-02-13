import Foundation
import ServiceManagement

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
        static let mapsProvider = "cai_mapsProvider"
        static let launchAtLogin = "cai_launchAtLogin"
        static let shortcuts = "cai_shortcuts"
        static let outputDestinations = "cai_outputDestinations"
    }

    // MARK: - Model Provider

    enum ModelProvider: String, CaseIterable, Identifiable {
        case lmstudio = "LM Studio"
        case ollama = "Ollama"
        case custom = "Custom"

        var id: String { rawValue }

        /// Base URL (without /v1) for each provider
        var defaultURL: String {
            switch self {
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

    /// Resolved model base URL based on provider selection
    var modelURL: String {
        switch modelProvider {
        case .lmstudio, .ollama:
            return modelProvider.defaultURL
        case .custom:
            return customModelURL
        }
    }

    // MARK: - Common Languages

    static let commonLanguages = [
        "English", "Spanish", "French", "German", "Italian",
        "Portuguese", "Chinese", "Japanese", "Korean", "Arabic",
        "Russian", "Hindi", "Dutch", "Swedish", "Turkish"
    ]

    // MARK: - Init

    private init() {
        self.searchURL = defaults.string(forKey: Keys.searchURL)
            ?? "https://search.brave.com/search?q="

        self.translationLanguage = defaults.string(forKey: Keys.translationLanguage)
            ?? "English"

        let providerRaw = defaults.string(forKey: Keys.modelProvider) ?? ModelProvider.lmstudio.rawValue
        self.modelProvider = ModelProvider(rawValue: providerRaw) ?? .lmstudio

        self.customModelURL = defaults.string(forKey: Keys.customModelURL)
            ?? "http://127.0.0.1:8080"

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

        // Default to true for launch at login — bool(forKey:) returns false when key is absent,
        // so we check if the key has ever been set explicitly.
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        } else {
            self.launchAtLogin = true
            defaults.set(true, forKey: Keys.launchAtLogin)
            updateLaunchAtLogin(true)
        }
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
        // No provider found — keep the default (LM Studio)
        print("No running LLM provider detected — defaulting to LM Studio")
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
