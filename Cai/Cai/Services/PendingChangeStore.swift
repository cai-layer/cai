import CaiActionCore
import Foundation

// MARK: - Pending proposal

/// A proposal that survived re-validation, paired with the file it came from.
struct PendingProposal: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let createdAt: Date
    /// What was read off disk. Kept so approval can validate again against the
    /// actions as they are at that moment, not as they were when the file
    /// arrived.
    let change: PendingChange
    let validated: ValidatedChange

    var provenance: ActionProvenance { validated.provenance }
    var tier: ApprovalTier { validated.tier }
    /// Client name from the MCP handshake, or the design spec's fallback.
    var authorName: String { validated.provenance.client ?? "An agent" }
}

// MARK: - Gate

/// Whether this build should process the pending directory at all.
///
/// Debug and Release share `~/Library/Application Support/Cai/`, so with both
/// running during dogfooding a single proposal would raise two approval sheets
/// and land in whichever UserDefaults domain the user happened to click. Debug
/// therefore ignores the directory unless `CAI_MCP_PENDING=1` is set in the run
/// scheme.
///
/// Pure and nonisolated so the whole matrix is table-tested rather than
/// discovered by running two builds side by side.
enum PendingChangeGate {

    static let debugOptInVariable = "CAI_MCP_PENDING"

    static func isProcessingEnabled(
        isDebugBuild: Bool,
        environment: [String: String],
        allowAgentProposals: Bool
    ) -> Bool {
        // The kill switch wins in every build: off means the app does not look
        // at the directory, not even to quarantine.
        guard allowAgentProposals else { return false }
        guard isDebugBuild else { return true }
        return environment[debugOptInVariable] == "1"
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Bridge to the app's action store

/// The store's window onto `CaiSettings`, as closures.
///
/// Injected rather than reached for, so the tests below run against fixtures
/// instead of the user's real shortcuts (same pattern as
/// `ChainExecutor.Resolver`).
struct ActionStoreBridge {
    var knownActions: @MainActor () -> KnownActions
    var upsert: @MainActor (ActionSnapshot, ActionProvenance) -> Void

    @MainActor
    static var live: ActionStoreBridge {
        ActionStoreBridge(
            knownActions: { CaiSettings.shared.knownActions },
            upsert: { snapshot, provenance in
                let shortcut = CaiShortcut(snapshot: snapshot, provenance: provenance)
                var shortcuts = CaiSettings.shared.shortcuts
                if let index = shortcuts.firstIndex(where: { $0.id == snapshot.id }) {
                    shortcuts[index] = shortcut
                } else {
                    shortcuts.append(shortcut)
                }
                CaiSettings.shared.shortcuts = shortcuts
            }
        )
    }
}

// MARK: - Store

/// Reads agent proposals off disk, re-validates every one of them, and applies
/// the ones the user approves.
///
/// **The app never trusts the helper.** The helper validates before writing so
/// an agent gets a fast, specific error, but the bytes in the pending directory
/// are just bytes any local process can write. Everything here runs the same
/// `ActionValidator` again on what it actually read.
///
/// **Nothing is dropped silently.** A proposal the app refuses moves to
/// `quarantine/` next to a `.rejection.json` naming the reason, raises a toast,
/// and gets an audit line. The agent finds the reason through `list_actions`
/// (PR 3) instead of watching its proposal vanish.
@MainActor
final class PendingChangeStore: ObservableObject {

    static let shared = PendingChangeStore()

    /// Proposals waiting for the user, oldest first (the approval queue is one
    /// at a time and first in, first reviewed).
    @Published private(set) var pending: [PendingProposal] = []

    private let root: URL
    private let bridge: ActionStoreBridge
    private let history: ActionHistoryLog
    private var watcher: PendingChangeWatcher?
    private let now: () -> Date
    /// Quarantines during the current `refresh()`, so a burst of bad files
    /// raises one toast rather than one per file.
    private var quarantinedThisPass = 0

    init(
        root: URL = CaiSupportPaths.root,
        bridge: ActionStoreBridge? = nil,
        history: ActionHistoryLog? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.bridge = bridge ?? .live
        self.history = history ?? ActionHistoryLog(fileURL: CaiSupportPaths.auditLog(in: root))
        self.now = now
    }

    private var pendingDirectory: URL { CaiSupportPaths.pendingChanges(in: root) }
    private var quarantineDirectory: URL { CaiSupportPaths.quarantine(in: root) }

    // MARK: - Lifecycle

    /// Creates the directories, does a first scan, and starts watching.
    /// A no-op when the gate is closed, so a Debug build stays out of the way
    /// of the Release build the user actually runs.
    func startIfEnabled(
        allowAgentProposals: Bool = CaiSettings.shared.allowAgentProposals,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard PendingChangeGate.isProcessingEnabled(
            isDebugBuild: PendingChangeGate.isDebugBuild,
            environment: environment,
            allowAgentProposals: allowAgentProposals
        ) else {
            stop()
            return
        }

        CaiSupportPaths.ensureDirectories(in: root)
        refresh()

        guard watcher == nil else { return }
        restartWatcher()
    }

    private func restartWatcher() {
        watcher?.stop()
        let watcher = PendingChangeWatcher(directory: pendingDirectory) { [weak self] in
            self?.refresh()
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        if !pending.isEmpty {
            pending = []
            notifyQueueChanged()
        }
    }

    // MARK: - Ingestion

    /// Re-reads the pending directory. Cheap enough to run on every filesystem
    /// event: the cap is 50 small files.
    func refresh() {
        // Self-heal if the directory was removed underneath us (an uninstaller,
        // a user tidying Application Support). Without this, authoring would
        // stay silently dead until the next launch.
        if watcher != nil, !FileManager.default.fileExists(atPath: pendingDirectory.path) {
            CaiSupportPaths.ensureDirectories(in: root)
            restartWatcher()
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let known = bridge.knownActions()
        var accepted: [PendingProposal] = []
        // Counted rather than announced one by one: a burst of bad files must
        // raise one toast, not a stack of them.
        quarantinedThisPass = 0

        // Oldest first, so a queue that hits the cap keeps the proposals the
        // user has been looking at rather than the newest arrival.
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            switch load(file, known: known) {
            case .success(let proposal):
                accepted.append(proposal)
            case .failure(let rejection):
                quarantine(file, reason: rejection, change: nil)
            }
        }

        accepted.sort { $0.createdAt < $1.createdAt }

        // Everything past the cap is quarantined rather than held invisibly:
        // an agent looping on create_action must hit a wall it can read about.
        if accepted.count > ActionSchema.maxPendingChanges {
            for overflow in accepted[ActionSchema.maxPendingChanges...] {
                quarantine(
                    overflow.fileURL,
                    reason: .queueFull(max: ActionSchema.maxPendingChanges),
                    change: overflow.validated
                )
            }
            accepted = Array(accepted.prefix(ActionSchema.maxPendingChanges))
        }

        if quarantinedThisPass > 0 {
            NotificationCenter.default.post(
                name: .caiShowToast,
                object: nil,
                userInfo: ["message": "Received an invalid action proposal. It was set aside and won't run."]
            )
        }

        guard accepted != pending else { return }
        pending = accepted
        notifyQueueChanged()
    }

    private func load(_ file: URL, known: KnownActions) -> Result<PendingProposal, ActionRejection> {
        // Size first: a huge file must not be read into memory just to find out
        // it was never a proposal. `resourceValues` resolves symlinks, which
        // `attributesOfItem` does not: without that, a link to /dev/zero would
        // measure as a few bytes and then never finish being read.
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            return .failure(.malformedJSON("only regular files are read from the pending directory"))
        }
        guard (values?.fileSize ?? 0) <= ActionSchema.maxPendingFileBytes else {
            return .failure(.malformedJSON("the file is larger than \(ActionSchema.maxPendingFileBytes) bytes"))
        }
        guard let data = try? Data(contentsOf: file) else {
            return .failure(.malformedJSON("the file could not be read"))
        }
        do {
            let change = try ActionCoding.decoder.decode(PendingChange.self, from: data)
            let validated = try ActionValidator.validate(change, known: known)
            return .success(PendingProposal(
                id: change.id,
                fileURL: file,
                createdAt: change.createdAt,
                change: change,
                validated: validated
            ))
        } catch let rejection as ActionRejection {
            return .failure(rejection)
        } catch {
            return .failure(.malformedJSON(Self.decodeDescription(error)))
        }
    }

    // MARK: - Decisions

    /// Persists the action and records the change. The approval sheet is the
    /// security boundary; by the time this runs the user has read the payload.
    ///
    /// Validation runs again here rather than reusing the verdict from the last
    /// scan. The user can edit the very action a proposal patches while the
    /// proposal sits in the queue, and applying a patch built against the older
    /// value would overwrite that edit: exactly the clobber the expected-value
    /// check exists to prevent. Returns false when the proposal no longer
    /// applies; it is quarantined with its reason, same as on arrival.
    @discardableResult
    func approve(_ proposal: PendingProposal) -> Bool {
        let validated: ValidatedChange
        do {
            validated = try ActionValidator.validate(proposal.change, known: bridge.knownActions())
        } catch let rejection as ActionRejection {
            quarantineOnDecision(proposal, reason: rejection)
            return false
        } catch {
            quarantineOnDecision(proposal, reason: .malformedJSON(Self.decodeDescription(error)))
            return false
        }

        bridge.upsert(validated.after, validated.provenance)
        history.append(ActionAuditEntry(
            timestamp: now(),
            changeId: validated.changeId,
            operation: validated.isUpdate ? "update" : "create",
            outcome: .approved,
            actionId: validated.after.id,
            actionName: validated.after.name,
            provenance: validated.provenance,
            before: validated.before,
            after: validated.after,
            reason: nil
        ))
        remove(proposal)
        return true
    }

    func reject(_ proposal: PendingProposal) {
        let validated = proposal.validated
        history.append(ActionAuditEntry(
            timestamp: now(),
            changeId: validated.changeId,
            operation: validated.isUpdate ? "update" : "create",
            outcome: .rejected,
            actionId: validated.before?.id,
            actionName: validated.after.name,
            provenance: validated.provenance,
            before: validated.before,
            after: validated.after,
            reason: nil
        ))
        remove(proposal)
    }

    /// Quarantine path for a proposal that stopped being applicable while it
    /// sat in the queue. Same handling as a bad file on arrival, so the reason
    /// still reaches the audit log, the toast, and the agent.
    private func quarantineOnDecision(_ proposal: PendingProposal, reason: ActionRejection) {
        quarantinedThisPass = 0
        quarantine(proposal.fileURL, reason: reason, change: proposal.validated)
        if quarantinedThisPass > 0 {
            NotificationCenter.default.post(
                name: .caiShowToast,
                object: nil,
                userInfo: ["message": "Received an invalid action proposal. It was set aside and won't run."]
            )
        }
        pending.removeAll { $0.id == proposal.id }
        notifyQueueChanged()
    }

    private func remove(_ proposal: PendingProposal) {
        try? FileManager.default.removeItem(at: proposal.fileURL)
        pending.removeAll { $0.id == proposal.id }
        notifyQueueChanged()
    }

    // MARK: - Quarantine

    /// Moves a refused proposal out of the queue without destroying it, writes
    /// the reason next to it, and tells the user once.
    private func quarantine(_ file: URL, reason: ActionRejection, change: ValidatedChange?) {
        CaiSupportPaths.ensureDirectories(in: root)
        let destination = quarantineDirectory.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            // If it cannot be moved it must not stay in the queue, or the same
            // bad file re-quarantines on every filesystem event.
            print("PendingChanges: could not quarantine \(file.lastPathComponent): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: file)
        }

        writeRejectionSidecar(for: destination, reason: reason)

        history.append(ActionAuditEntry(
            timestamp: now(),
            changeId: change?.changeId ?? UUID(),
            operation: change.map { $0.isUpdate ? "update" : "create" } ?? "unknown",
            outcome: .quarantined,
            actionId: change?.after.id,
            actionName: change?.after.name ?? file.deletingPathExtension().lastPathComponent,
            provenance: change?.provenance,
            before: change?.before,
            after: change?.after,
            reason: reason.reason
        ))

        quarantinedThisPass += 1
    }

    /// `<uuid>.rejection.json` beside the quarantined file. The original bytes
    /// may not even be JSON, so the reason cannot live inside them; the helper
    /// reads this to answer "what happened to my proposal" in `list_actions`.
    private func writeRejectionSidecar(for file: URL, reason: ActionRejection) {
        let sidecar = file.deletingPathExtension().appendingPathExtension("rejection.json")
        let payload = QuarantineRecord(
            schemaVersion: ActionSchema.version,
            rejectedAt: now(),
            reason: reason.reason
        )
        guard let data = try? ActionCoding.encoder.encode(payload) else { return }
        try? data.write(to: sidecar, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
    }

    private func notifyQueueChanged() {
        NotificationCenter.default.post(name: .caiPendingChangesChanged, object: nil)
    }

    /// `DecodingError`'s own description is a multi-line debug dump. Agents get
    /// one legible line instead.
    private static func decodeDescription(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, _):
            return "missing field '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "wrong type for '\(path)'"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "unreadable payload"
        }
    }
}

/// Written beside a quarantined proposal so the reason survives the app quitting.
struct QuarantineRecord: Codable, Equatable {
    let schemaVersion: Int
    let rejectedAt: Date
    let reason: String
}
