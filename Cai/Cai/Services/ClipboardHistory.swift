import AppKit

/// Tracks clipboard history with pinning support.
/// Polls the system pasteboard for changes and maintains a chronological history.
/// Pinned items persist across relaunches; regular items are in-memory only.
class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    /// Maximum preview length for display in the UI
    static let maxPreviewLength = 60

    /// Maximum number of pinned entries (matches ⌘1-9 range)
    static let maxPinnedEntries = 9

    /// Each history entry stores the full text, timestamp, and pin state
    struct Entry: Identifiable {
        let id: UUID
        let text: String
        let timestamp: Date
        let isPinned: Bool

        /// Truncated preview for UI display, single-line with "..." if needed
        var preview: String {
            let singleLine = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if singleLine.count > ClipboardHistory.maxPreviewLength {
                return String(singleLine.prefix(ClipboardHistory.maxPreviewLength)) + "..."
            }
            return singleLine
        }

        init(text: String, timestamp: Date, isPinned: Bool = false) {
            self.id = UUID()
            self.text = text
            self.timestamp = timestamp
            self.isPinned = isPinned
        }
    }

    /// Codable representation for persisting pinned items only
    private struct PinnedEntry: Codable {
        let text: String
        let timestamp: Date
    }

    @Published private(set) var pinnedEntries: [Entry] = []
    @Published private(set) var regularEntries: [Entry] = []

    /// Combined view: pinned first, then regular (by recency)
    var allEntries: [Entry] {
        pinnedEntries + regularEntries
    }

    /// Dynamic max entries from user settings
    private var maxEntries: Int {
        CaiSettings.shared.clipboardHistorySize
    }

    private var lastChangeCount: Int = 0
    private var pollTimer: Timer?

    // MARK: - Pin Persistence

    private static var pinnedFilePath: URL {
        BuiltInLLM.supportDirectory.appendingPathComponent("pinned-history.json")
    }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        loadPinnedEntries()
        startPolling()
    }

    // MARK: - Polling

    /// Start polling the pasteboard for changes every 0.5s
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    /// Check if the pasteboard has new content
    private func checkForChanges() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = pasteboard.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        addEntry(trimmed)
    }

    /// Manually record a clipboard entry (called from ClipboardService after copy)
    func recordCurrentClipboard() {
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addEntry(trimmed)
    }

    // MARK: - Entry Management

    private func addEntry(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // If text matches a pinned entry, skip — don't duplicate
            if self.pinnedEntries.contains(where: { $0.text == text }) {
                return
            }

            // Remove duplicate from regular entries if exists
            self.regularEntries.removeAll { $0.text == text }

            // Insert at the beginning (most recent first)
            let entry = Entry(text: text, timestamp: Date())
            self.regularEntries.insert(entry, at: 0)

            // Trim to max entries
            if self.regularEntries.count > self.maxEntries {
                self.regularEntries = Array(self.regularEntries.prefix(self.maxEntries))
            }
        }
    }

    /// Copy a history entry back to the clipboard
    func copyEntry(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        lastChangeCount = pasteboard.changeCount  // Don't re-record this as a new entry
    }

    // MARK: - Pinning

    /// Pin an entry to the top of the list. Persists across relaunches.
    func pinEntry(_ entry: Entry) {
        guard !entry.isPinned else { return }
        guard pinnedEntries.count < Self.maxPinnedEntries else { return }

        // Remove from regular entries
        regularEntries.removeAll { $0.text == entry.text }

        // Add to pinned at the top
        let pinned = Entry(text: entry.text, timestamp: entry.timestamp, isPinned: true)
        pinnedEntries.insert(pinned, at: 0)
        savePinnedEntries()
    }

    /// Unpin an entry. Moves back to the regular list.
    func unpinEntry(_ entry: Entry) {
        guard entry.isPinned else { return }

        // Remove from pinned
        pinnedEntries.removeAll { $0.text == entry.text }
        savePinnedEntries()

        // Add back to regular entries at top
        let regular = Entry(text: entry.text, timestamp: entry.timestamp, isPinned: false)
        regularEntries.insert(regular, at: 0)

        // Trim regular if needed
        if regularEntries.count > maxEntries {
            regularEntries = Array(regularEntries.prefix(maxEntries))
        }
    }

    // MARK: - Persistence (pinned items only)

    private func loadPinnedEntries() {
        guard let data = try? Data(contentsOf: Self.pinnedFilePath),
              let decoded = try? JSONDecoder().decode([PinnedEntry].self, from: data) else {
            return
        }
        pinnedEntries = decoded.map {
            Entry(text: $0.text, timestamp: $0.timestamp, isPinned: true)
        }
    }

    private func savePinnedEntries() {
        let codable = pinnedEntries.map { PinnedEntry(text: $0.text, timestamp: $0.timestamp) }
        guard let data = try? JSONEncoder().encode(codable) else { return }
        try? FileManager.default.createDirectory(
            at: BuiltInLLM.supportDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.pinnedFilePath, options: .atomic)
    }
}
