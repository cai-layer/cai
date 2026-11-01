import CaiActionCore
import Foundation

/// Reads the list the `cai-today` skill writes, and keeps what the user did
/// with it. Two folders, so the run can't reach Cai's own files:
///
/// - `Today/` is the skill's, and the run's working folder (where it may
///   write): `items.jsonl`, `candidates.json` and their `.tmp` copies. Cai
///   only reads `items.jsonl`, through `TodayFile.parse`, and reloads it
///   whenever the folder changes.
/// - `TodayState/` is Cai's and the user's, outside the run's reach:
///   `state.json` (done, dismissed and snoozed, keyed on url), `events.jsonl`
///   (a local log of what the user did, for the dogfood metric; it never
///   leaves the Mac), `runs.log` and `priorities.md`, which the skill only reads.
///
/// Debug and Release share this folder (both bundle IDs use the same
/// Application Support path). Nothing here consumes files the way
/// `pending-changes/` does, so two builds can't steal each other's input; the
/// one shared write is `state.json`, where the last writer wins. Released
/// builds have no Today screen yet, so today only one build writes.
@MainActor
final class TodayStore: ObservableObject {
    static let shared = TodayStore()

    enum List: Equatable {
        /// No `items.jsonl` yet: the skill has never run.
        case noFile
        case loaded(TodayFile.Parsed)
    }

    @Published private(set) var list: List = .noFile
    @Published private(set) var state = TodayState()

    /// State before each change, newest last. Undo is restoring a value
    /// (see `TodayState.marking`), so there is no inverse to get wrong.
    private var undoStack: [(state: TodayState, url: URL)] = []
    private var watcher: PendingChangeWatcher?
    private var stateWatcher: PendingChangeWatcher?
    /// False when `state.json` exists but isn't a version this build reads:
    /// changes then stay in memory rather than overwrite a newer file.
    private var stateWritable = true
    /// Modification dates as last read or written here. The watcher fires for
    /// every change in the folder, Cai's own writes included, so a file is
    /// read again only when its date moved.
    private var itemsModified: Date?
    private var stateModified: Date?

    nonisolated static var folder: URL { CaiSupportPaths.root.appendingPathComponent("Today") }
    nonisolated static var stateFolder: URL { CaiSupportPaths.root.appendingPathComponent("TodayState") }
    nonisolated static var prioritiesURL: URL { stateFolder.appendingPathComponent("priorities.md") }
    nonisolated static var runsLogURL: URL { stateFolder.appendingPathComponent("runs.log") }
    /// Cai's files, which lived in `Today/` before `TodayState/` existed.
    nonisolated static let ownedFiles = ["state.json", "events.jsonl", "runs.log", "priorities.md"]
    private var itemsURL: URL { Self.folder.appendingPathComponent("items.jsonl") }
    private var stateURL: URL { Self.stateFolder.appendingPathComponent("state.json") }
    private var eventsURL: URL { Self.stateFolder.appendingPathComponent("events.jsonl") }

    var items: [TodayItem] {
        if case .loaded(let parsed) = list { return parsed.items }
        return []
    }

    /// Called each time the screen opens: loads on first use, and re-attaches
    /// a watcher whose folder was replaced under it.
    func open() {
        if watcher == nil {
            Self.prepareFolders()
            loadState()
        }
        if watcher?.isWatchingCurrentDirectory() != true {
            watcher?.stop()
            watcher = Self.watch(Self.folder) { [weak self] in self?.folderChanged() }
        }
        if stateWatcher?.isWatchingCurrentDirectory() != true {
            stateWatcher?.stop()
            stateWatcher = Self.watch(Self.stateFolder) { [weak self] in self?.folderChanged() }
        }
        reloadItems()
    }

    /// Creates both folders and moves Cai's files out of `Today/` once.
    static func prepareFolders() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        migrate(ownedFiles, from: folder, to: stateFolder)
    }

    /// Moves each named file from `old` to `new`, unless `new` already has
    /// one: the copy in `new` is the live one and is never overwritten.
    nonisolated static func migrate(_ names: [String], from old: URL, to new: URL, fileManager: FileManager = .default) {
        for name in names {
            let source = old.appendingPathComponent(name)
            let destination = new.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func watch(_ directory: URL, onChange: @escaping () -> Void) -> PendingChangeWatcher {
        let watcher = PendingChangeWatcher(directory: directory, onChange: onChange)
        watcher.start()
        return watcher
    }

    /// Reads again whichever file changed. `state.json` can change outside
    /// this process (the other build, or the user deleting it to start over);
    /// reading it back keeps the next action from writing an old state over it.
    private func folderChanged() {
        if Self.modified(stateURL) != stateModified { loadState() }
        if Self.modified(itemsURL) != itemsModified { reloadItems() }
    }

    func reloadItems() {
        itemsModified = Self.modified(itemsURL)
        guard let text = try? String(contentsOf: itemsURL, encoding: .utf8) else {
            list = .noFile
            return
        }
        let parsed = TodayFile.parse(text)
        if list != .loaded(parsed) { list = .loaded(parsed) }
    }

    // MARK: - Changes

    func mark(_ item: TodayItem, _ kind: TodayState.Entry.Kind) {
        change(item, to: state.marking(item, kind, now: Date()), event: kind.event)
    }

    func unsnooze(_ item: TodayItem) {
        change(item, to: state.clearing(item), event: "unsnooze")
    }

    func clearUndo() {
        undoStack.removeAll()
    }

    /// Returns false when there is nothing to undo.
    @discardableResult
    func undo() -> Bool {
        guard let last = undoStack.popLast() else { return false }
        state = last.state
        saveState()
        log("undo", url: last.url)
        return true
    }

    func log(_ event: String, url: URL) {
        let entry: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "url": url.absoluteString,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: eventsURL)
        }
    }

    private func change(_ item: TodayItem, to next: TodayState, event: String) {
        undoStack.append((state, item.url))
        state = next
        saveState()
        log(event, url: item.url)
    }

    // MARK: - state.json

    private func loadState() {
        stateModified = Self.modified(stateURL)
        // Undo steps were taken against the state being replaced.
        undoStack.removeAll()
        guard let data = try? Data(contentsOf: stateURL) else {
            state = TodayState()
            stateWritable = true
            return
        }
        if let decoded = Self.decodeState(data) {
            state = decoded
            stateWritable = true
        } else {
            stateWritable = false
            print("Today: state.json is not a version this build reads; changes stay in memory")
        }
    }

    private func saveState() {
        guard stateWritable, let data = try? Self.encodeState(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
        stateModified = Self.modified(stateURL)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Dates keep the encoder's default (a Double), not ISO 8601: an ISO
    /// string drops the fraction of a second, and an item whose `activity`
    /// has one would then read as newer than the stored copy and come back
    /// after every relaunch.
    nonisolated static func encodeState(_ state: TodayState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    nonisolated static func decodeState(_ data: Data) -> TodayState? {
        guard let state = try? JSONDecoder().decode(TodayState.self, from: data), state.v == 1 else { return nil }
        return state
    }
}

private extension TodayState.Entry.Kind {
    var event: String {
        switch self {
        case .done: return "done"
        case .dismissed: return "dismiss"
        case .snoozed: return "snooze"
        }
    }
}
