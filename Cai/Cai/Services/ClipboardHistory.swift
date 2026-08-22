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

    /// Maximum text length stored per entry (prevents memory bloat from huge clipboard content)
    static let maxTextLength = 10_000

    /// Each history entry stores the full text, timestamp, and pin state
    struct Entry: Identifiable {
        let id: UUID
        let text: String
        let timestamp: Date
        let isPinned: Bool
        let isImage: Bool

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

        init(text: String, timestamp: Date, isPinned: Bool = false, isImage: Bool = false) {
            self.id = UUID()
            self.text = text
            self.timestamp = timestamp
            self.isPinned = isPinned
            self.isImage = isImage
        }
    }

    /// Codable representation for persisting pinned items only
    private struct PinnedEntry: Codable {
        let text: String
        let timestamp: Date
        let isImage: Bool

        enum CodingKeys: String, CodingKey {
            case text, timestamp, isImage
        }

        init(text: String, timestamp: Date, isImage: Bool = false) {
            self.text = text
            self.timestamp = timestamp
            self.isImage = isImage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            isImage = try container.decodeIfPresent(Bool.self, forKey: .isImage) ?? false
        }
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
    /// Guards against a slow pasteboard daemon letting two poll ticks run their
    /// async content reads at the same time. Only mutated on the main thread.
    private var pollInFlight = false
    /// Text just written by `copyEntry` (re-copying a history entry). The poll
    /// suppresses the matching change once instead of re-recording it. Set and
    /// checked on the main thread, so it can't race the poll.
    private var suppressNextCopyText: String?

    // MARK: - Pin Persistence

    private static var pinnedFilePath: URL {
        MLXInference.supportDirectory.appendingPathComponent("pinned-history.json")
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

    /// Check if the pasteboard has new content.
    ///
    /// **Threading:** the timer fires on the main thread; the cheap `changeCount`
    /// probe stays here (it is cached and does not iterate the items array). When
    /// the count moves, the actual content reads (`string(forType:)` / Vision OCR)
    /// run off the main thread on `PasteboardQueue`, so a slow `pboardd` or a huge
    /// clipboard can no longer hang the runloop, and they are serialized against
    /// the ⌥C path and paste-back — a single reader at a time, which is what the
    /// previous "everything on main" workaround was protecting against (two
    /// concurrent readers crashed in `__NSFastEnumerationMutationHandler`).
    private func checkForChanges() {
        let currentCount = NSPasteboard.general.changeCount

        guard currentCount != lastChangeCount, !pollInFlight else { return }
        lastChangeCount = currentCount
        pollInFlight = true

        Task { @MainActor in
            defer { self.pollInFlight = false }

            // One atomic snapshot (file → text → image priority), resolved off-lane.
            let (content, _, isConcealed) = await ClipboardService.shared.readClipboardContent()

            // A history entry we just copied back surfaces here as a change.
            // Read-and-clear on EVERY tick — including concealed ones — so the
            // marker's staleness stays bounded to one pasteboard change; if a
            // concealed copy landed between our write and this tick, holding
            // the marker would silently swallow the next genuine copy of the
            // same text.
            let suppressed = self.suppressNextCopyText
            self.suppressNextCopyText = nil

            // Concealed/transient copies (password managers mark these — see
            // RecentClipsMenuModel.sensitiveTypeIdentifiers) never enter
            // history. Excluded here at capture, not at display, so marked
            // secrets can't reach any surface built on history (⌘0 list,
            // status-item menu). Cooperative only: an unmarked secret (pbcopy,
            // "show password" fields) is indistinguishable from ordinary text.
            guard !isConcealed else { return }

            switch content {
            case .imageText(let ocrText):
                self.addEntry(ocrText, isImage: true)
            case .text(let text):
                // Skip recording when the change is the self-copy we marked.
                guard text != suppressed else { return }
                self.addEntry(text)
            case .empty:
                break
            }
        }
    }

    /// Record a clipboard entry the caller already read (the ⌥C path, from
    /// `ClipboardService.readClipboardContent`). Takes the text AND the
    /// `changeCount` from the same snapshot, so the poll baseline matches the
    /// recorded content and the next poll tick won't re-record it.
    func recordCurrentClipboard(_ text: String, changeCount: Int) {
        lastChangeCount = changeCount
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addEntry(trimmed)
    }

    /// Record an OCR-extracted text entry from a clipboard image.
    func recordImageClipboard(ocrText: String) {
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        guard !ocrText.isEmpty else { return }
        addEntry(ocrText, isImage: true)
    }

    // MARK: - Entry Management

    private func addEntry(_ text: String, isImage: Bool = false) {
        // Clamp text to maxTextLength to prevent memory bloat from huge clipboard content
        let clampedText = text.count > Self.maxTextLength
            ? String(text.prefix(Self.maxTextLength))
            : text

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // If text matches a pinned entry, skip — don't duplicate
            if self.pinnedEntries.contains(where: { $0.text == clampedText }) {
                return
            }

            // Remove duplicate from regular entries if exists
            self.regularEntries.removeAll { $0.text == clampedText }

            // Insert at the beginning (most recent first)
            let entry = Entry(text: clampedText, timestamp: Date(), isImage: isImage)
            self.regularEntries.insert(entry, at: 0)

            // Trim to max entries
            if self.regularEntries.count > self.maxEntries {
                self.regularEntries = Array(self.regularEntries.prefix(self.maxEntries))
            }
        }
    }

    /// Copy a history entry back to the clipboard. Routed through PasteboardQueue
    /// so the write can't race a concurrent read/paste-back. Fire-and-forget, so
    /// the call site stays synchronous.
    func copyEntry(_ entry: Entry) {
        // Mark the text so the poll suppresses this self-copy instead of
        // re-recording it. Set on main (this is called from the UI) and checked
        // on main in `checkForChanges` — race-free, no cross-thread hop.
        //
        // Stored TRIMMED because the poll's read-back comes through
        // `readClipboardContent`, which trims: an entry whose text carries
        // leading/trailing whitespace (image OCR) would otherwise miss the
        // suppression and re-record as a near-duplicate.
        suppressNextCopyText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        PasteboardQueue.shared.write {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(entry.text, forType: .string)
        }
    }

    // MARK: - Pinning

    /// Pin an entry to the top of the list. Persists across relaunches.
    func pinEntry(_ entry: Entry) {
        guard !entry.isPinned else { return }
        guard pinnedEntries.count < Self.maxPinnedEntries else { return }

        // Remove from regular entries
        regularEntries.removeAll { $0.text == entry.text }

        // Add to pinned at the top
        let pinned = Entry(text: entry.text, timestamp: entry.timestamp, isPinned: true, isImage: entry.isImage)
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
        let regular = Entry(text: entry.text, timestamp: entry.timestamp, isPinned: false, isImage: entry.isImage)
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
            Entry(text: $0.text, timestamp: $0.timestamp, isPinned: true, isImage: $0.isImage)
        }
    }

    private func savePinnedEntries() {
        let codable = pinnedEntries.map { PinnedEntry(text: $0.text, timestamp: $0.timestamp, isImage: $0.isImage) }
        guard let data = try? JSONEncoder().encode(codable) else { return }
        try? FileManager.default.createDirectory(
            at: MLXInference.supportDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.pinnedFilePath, options: .atomic)
    }
}
