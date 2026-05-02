import Foundation

// MARK: - Extension Service

/// Fetches community extensions from the curated GitHub repo.
struct ExtensionService {

    private static let baseURL = "https://raw.githubusercontent.com/cai-layer/cai-extensions/master"

    // MARK: - Models

    struct ExtensionEntry: Codable, Identifiable {
        let slug: String
        let name: String
        let description: String
        let author: String
        let version: String
        let icon: String
        let type: String
        let tags: [String]

        var id: String { slug }
    }

    // MARK: - Fetch

    /// Fetches the extension index from the curated repo.
    static func fetchIndex() async throws -> [ExtensionEntry] {
        guard let url = URL(string: "\(baseURL)/index.json") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            #if DEBUG
            print("[ExtensionService] HTTP \(code) for \(url)")
            #endif
            throw URLError(.badServerResponse)
        }

        #if DEBUG
        print("[ExtensionService] Received \(data.count) bytes")
        #endif

        return try JSONDecoder().decode([ExtensionEntry].self, from: data)
    }

    /// Fetches the raw YAML for an extension by slug.
    static func fetchYAML(slug: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/extensions/\(slug)/extension.yaml") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let yaml = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return yaml
    }
}
