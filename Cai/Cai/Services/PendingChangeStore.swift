import CaiActionCore
import Foundation

// MARK: - Pending proposal

/// A proposal that survived re-validation, paired with the file it came from.
struct PendingProposal: Identifiable, Equatable {
    /// Identity is the file, not the id inside it. That id is a field in a
    /// document any local process can write, so two files can carry the same
    /// one; keying the queue on it makes a single decision drop both entries
    /// while deleting only one file, and the survivor reappears on the next
    /// filesystem event.
    var id: URL { fileURL }
    let changeId: UUID
    let fileURL: URL
    /// When the file landed on disk, per the filesystem. This is what the
    /// queue sorts on: `createdAt` below is a field in the payload, and a
    /// writer that stamps its proposal with 1970 must not jump to the head
    /// of the queue and swap the card the user is reading.
    let arrivedAt: Date
    /// The writer's own timestamp. Display metadata only — never ordering.
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

    /// Equality is the payload, not the file's mtime. A writer re-writing
    /// byte-identical content bumps `arrivedAt`, and if equality noticed, the
    /// sheet's `.onChange(of: proposal)` would wipe the user's acknowledgment
    /// and re-arm Approve over a payload that did not change. The tick belongs
    /// to the bytes the user read, so identity is the file and the bytes.
    static func == (lhs: PendingProposal, rhs: PendingProposal) -> Bool {
        lhs.fileURL == rhs.fileURL && lhs.change == rhs.change && lhs.validated == rhs.validated
    }
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
        // Self-heal if the directory was removed OR replaced underneath us (an
        // uninstaller, a user tidying Application Support, a restore that
        // swaps the directory for a fresh inode). Without this, authoring
        // stays silently dead until the next launch.
        if let watcher, !watcher.isWatchingCurrentDirectory() {
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

        // Bounded per pass: the 50-proposal cap is applied after reading, so
        // without a ceiling here a directory stuffed with thousands of files
        // would be read in full on the main actor before any could be refused.
        let candidates = files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        let examined = candidates.prefix(ActionSchema.maxPendingFilesScanned)
        if candidates.count > examined.count {
            print("PendingChanges: \(candidates.count - examined.count) file(s) beyond the per-scan cap were left for the next pass")
        }

        for file in examined {
            switch load(file, known: known) {
            case .success(let proposal):
                accepted.append(proposal)
            case .failure(let rejection):
                quarantine(file, reason: rejection, change: nil)
            }
        }

        // Oldest first, so a queue that hits the cap keeps the proposals the
        // user has been looking at rather than the newest arrival. Sorted on
        // the file's own modification date, never the payload's `createdAt`:
        // that one is chosen by whoever wrote the file, and a proposal
        // stamped 1970 would otherwise pin itself at the head of the queue,
        // swapping the card under the user's cursor. Two files can still
        // share a timestamp, so the id breaks ties and keeps the head stable
        // between scans.
        accepted.sort {
            $0.arrivedAt == $1.arrivedAt
                ? $0.changeId.uuidString < $1.changeId.uuidString
                : $0.arrivedAt < $1.arrivedAt
        }

        // Everything past the cap is quarantined rather than held invisibly:
        // an agent looping on create_action must hit a wall it can read about.
        var overflowed = 0
        if accepted.count > ActionSchema.maxPendingChanges {
            for overflow in accepted[ActionSchema.maxPendingChanges...] {
                quarantine(
                    overflow.fileURL,
                    reason: .queueFull(max: ActionSchema.maxPendingChanges),
                    change: overflow.validated
                )
                overflowed += 1
            }
            accepted = Array(accepted.prefix(ActionSchema.maxPendingChanges))
        }

        // Counted apart from the overflow above, which also quarantines. An
        // overflowed proposal was perfectly valid and was dropped because the
        // queue was full, so telling the user it was invalid blames their
        // agent for producing garbage it did not produce.
        if quarantinedThisPass - overflowed > 0 {
            ToastQueue.post("Received an invalid action proposal. It was set aside and won't run.", outcome: .problem)
        }
        if overflowed > 0 {
            // Not "until you review some": an overflowed proposal is
            // quarantined and never comes back. Reviewing frees room
            // for the next one, not for this one.
            ToastQueue.post("Too many proposals waiting. The newest were set aside and the agent was told.", outcome: .problem)
        }

        guard accepted != pending else { return }

        // Arrival is passive by design: one toast naming who proposed it, and
        // a dot on the menu bar icon. Nothing takes focus, nothing opens. Only
        // genuinely new proposals announce themselves, so a rescan triggered by
        // an unrelated write stays silent.
        let alreadyQueued = Set(pending.map(\.id))
        let arrivals = accepted.filter { !alreadyQueued.contains($0.id) }
        pending = accepted
        notifyQueueChanged()

        // One announcement per scan. Several arriving at once is one event to
        // the user; several arriving seconds apart are separate events, and
        // `ToastQueue` gives each its full time on screen rather than letting
        // the second cut off the first.
        if let arrival = arrivals.first {
            ToastQueue.post(
                ActionReviewPresentation.arrivalToast(
                    client: arrival.provenance.client,
                    isUpdate: arrival.validated.isUpdate
                ),
                outcome: .arrival
            )
        }
    }

    private func load(_ file: URL, known: KnownActions) -> Result<PendingProposal, ActionRejection> {
        // Size first: a huge file must not be read into memory just to find out
        // it was never a proposal. `resourceValues` resolves symlinks, which
        // `attributesOfItem` does not: without that, a link to /dev/zero would
        // measure as a few bytes and then never finish being read.
        let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ])
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
            let change = try Self.readChange(from: data)
            let validated = try ActionValidator.validate(change, known: known)
            return .success(PendingProposal(
                changeId: change.id,
                fileURL: file,
                arrivedAt: values?.contentModificationDate ?? change.createdAt,
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

    /// Decodes one pending file, forcing the mcp provenance the pending
    /// directory implies. Shared by the scan and the approve-time re-read so
    /// both judge the same bytes the same way. Whatever the file claims, it
    /// arrived through the pending directory, and that IS the mcp channel:
    /// left as written, a payload carrying `"source": "in-app"` would badge
    /// its action "via Cai" forever, the one provenance label agents must
    /// not be able to award themselves.
    static func readChange(from data: Data) throws -> PendingChange {
        var change = try ActionCoding.decoder.decode(PendingChange.self, from: data)
        if change.provenance.source != .mcp {
            change = PendingChange(
                schemaVersion: change.schemaVersion,
                id: change.id,
                createdAt: change.createdAt,
                provenance: ActionProvenance(
                    source: .mcp,
                    client: change.provenance.client,
                    model: change.provenance.model,
                    authoredAt: change.provenance.authoredAt
                ),
                operation: change.operation
            )
        }
        return change
    }

    // MARK: - Decisions

    /// What happened when the user clicked Approve.
    enum ApprovalOutcome: Equatable {
        case approved
        /// The proposal no longer applies at all; it has been quarantined.
        case refused(ActionRejection)
        /// The action grew a risk the user was never shown. Nothing was
        /// applied; the queue now carries the fresh verdict so the sheet can
        /// re-present it with the callouts and boxes that were missing.
        case needsAcknowledgment([EscalationReason])
        /// The proposal already left the queue (decided elsewhere, or its file
        /// vanished between render and click). Nothing was applied and nothing
        /// was deleted: acting on it would upsert a payload the queue no
        /// longer holds and remove whatever file now sits at its path.
        case stale
        /// The file was rewritten in place between the scan and the click:
        /// the card the user read is not what is on disk. Nothing was decided;
        /// the queue has been re-scanned and re-presents the new bytes. Kept
        /// apart from `stale` because the card does NOT leave the queue, so
        /// the sheet must say why the click did nothing or the user's next
        /// move is to click again on content they never consciously re-read.
        case reloaded
    }

    /// Persists the action and records the change.
    ///
    /// Validation runs again here rather than reusing the verdict from the last
    /// scan, and the interlock is enforced here rather than in the view. Both
    /// for the same reason: the verdict the user saw was computed when the file
    /// arrived, and the world can move underneath it. The user can edit the
    /// action a proposal patches, or approve a shell action that an earlier
    /// proposal in the same queue then chains into. Trusting the displayed
    /// tier would let an action that runs shell be stored without its callout
    /// ever appearing, which is the one failure this surface cannot have.
    @discardableResult
    func approve(_ proposal: PendingProposal, acknowledged: Set<EscalationReason>) -> ApprovalOutcome {
        guard pending.contains(where: { $0.id == proposal.id }) else { return .stale }

        // The file can have been rewritten in place since the scan read it:
        // the helper names the file by change id, so a retry replaces it
        // atomically. Approving the bytes the user read is safe for the user,
        // but `remove` would then delete a revision nobody saw, and the agent
        // polls absence and reads its revision as approved. Any divergence is
        // undecidable: refuse the decision and re-scan, so the sheet
        // re-presents what is actually on disk. `boundedRead` applies the
        // same regular-file and size guards as `load()`: between the scan
        // and the click the path can have been replaced with a FIFO or a
        // link to something huge, and a bare read here would hang the main
        // actor at the exact moment the user clicks Approve.
        guard let data = ProposalStatus.boundedRead(proposal.fileURL),
              let fresh = try? Self.readChange(from: data),
              fresh == proposal.change
        else {
            refresh()
            return .reloaded
        }

        let validated: ValidatedChange
        do {
            validated = try ActionValidator.validate(proposal.change, known: bridge.knownActions())
        } catch let rejection as ActionRejection {
            quarantineOnDecision(proposal, reason: rejection)
            return .refused(rejection)
        } catch {
            let rejection = ActionRejection.malformedJSON(Self.decodeDescription(error))
            quarantineOnDecision(proposal, reason: rejection)
            return .refused(rejection)
        }

        let unacknowledged = validated.escalationReasons.filter { !acknowledged.contains($0) }
        guard unacknowledged.isEmpty else {
            replace(proposal, with: validated)
            return .needsAcknowledgment(validated.escalationReasons)
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
        return .approved
    }

    /// Swaps a queued proposal's verdict for a freshly computed one, so the
    /// sheet redraws against the world as it is now.
    private func replace(_ proposal: PendingProposal, with validated: ValidatedChange) {
        guard let index = pending.firstIndex(where: { $0.id == proposal.id }) else { return }
        pending[index] = PendingProposal(
            changeId: proposal.changeId,
            fileURL: proposal.fileURL,
            arrivedAt: proposal.arrivedAt,
            createdAt: proposal.createdAt,
            change: proposal.change,
            validated: validated
        )
        notifyQueueChanged()
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
        // Filed, not deleted. Absence is how the agent reads "approved", so
        // deleting a rejected proposal made the user's No indistinguishable
        // from a Yes: it would poll, find nothing, and carry on building on an
        // action that was refused. `list_actions` has always promised it would
        // see "rejected by Cai" here.
        moveToQuarantine(
            proposal.fileURL,
            reason: "The user reviewed this and declined it.",
            outcome: .declined,
            actionName: validated.after.name,
            client: validated.provenance.client
        )
        pending.removeAll { $0.id == proposal.id }
        notifyQueueChanged()
        // Not for `remove`'s reason: rejecting changes nothing the rest of the
        // queue was judged against, since only an approval touches
        // `knownActions`. This re-scans because the queue just gained a slot,
        // so anything held back by the cap can come in now.
        refresh()
    }

    /// Quarantine path for a proposal that stopped being applicable while it
    /// sat in the queue. Same handling as a bad file on arrival, so the reason
    /// still reaches the audit log, the toast, and the agent.
    private func quarantineOnDecision(_ proposal: PendingProposal, reason: ActionRejection) {
        quarantinedThisPass = 0
        quarantine(proposal.fileURL, reason: reason, change: proposal.validated)
        if quarantinedThisPass > 0 {
            ToastQueue.post(ActionReviewPresentation.refusedToast, outcome: .problem)
        }
        pending.removeAll { $0.id == proposal.id }
        notifyQueueChanged()
    }

    private func remove(_ proposal: PendingProposal) {
        try? FileManager.default.removeItem(at: proposal.fileURL)
        pending.removeAll { $0.id == proposal.id }
        notifyQueueChanged()
        // Re-validate what is left immediately. A decision changes the world
        // the rest of the queue was judged against: approving a shell action
        // can escalate the next proposal that chains into it, and waiting for
        // the watcher's debounce would show that proposal its stale verdict
        // for long enough to click through.
        refresh()
    }

    // MARK: - Quarantine

    /// Moves a proposal out of the queue without destroying it and writes the
    /// reason next to it, so the agent can read what became of it.
    ///
    /// Shared by refusal and by the user's own Reject: both need the file
    /// filed rather than deleted, and filing it here means the quarantine cap
    /// bounds them together instead of one growing unwatched.
    private func moveToQuarantine(
        _ file: URL,
        reason: String,
        outcome: QuarantineRecord.Outcome,
        actionName: String? = nil,
        client: String? = nil
    ) {
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

        writeRejectionSidecar(
            for: destination, reason: reason, outcome: outcome,
            actionName: actionName, client: client
        )
        pruneQuarantine()
    }

    /// Moves a refused proposal out of the queue without destroying it, writes
    /// the reason next to it, and tells the user once.
    private func quarantine(_ file: URL, reason: ActionRejection, change: ValidatedChange?) {
        moveToQuarantine(
            file, reason: reason.reason, outcome: .refused,
            actionName: change?.after.name,
            client: change?.provenance.client
        )

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

    /// Drops the oldest quarantined proposals (and their sidecars) past the
    /// cap. The queue and the audit log are both bounded; this is the same
    /// discipline for the one directory a misbehaving writer can grow.
    private func pruneQuarantine() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let proposals = files
            .filter { !$0.lastPathComponent.hasSuffix(".rejection.json") }
            .map { url in
                (url: url, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast)
            }
        for url in Self.quarantineOverflow(proposals, cap: ActionSchema.maxQuarantinedFiles) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.deletingPathExtension().appendingPathExtension("rejection.json")
            )
        }
    }

    /// Which quarantined proposals to delete: everything past `cap`, oldest
    /// first. Pure, so the selection is table-tested instead of exercised by
    /// writing hundreds of fixture files.
    static func quarantineOverflow(_ proposals: [(url: URL, modified: Date)], cap: Int) -> [URL] {
        let overflow = proposals.count - cap
        guard overflow > 0 else { return [] }
        return proposals.sorted { $0.modified < $1.modified }.prefix(overflow).map(\.url)
    }

    /// `<uuid>.rejection.json` beside the quarantined file. The original bytes
    /// may not even be JSON, so the reason cannot live inside them; the helper
    /// reads this to answer "what happened to my proposal" in `list_actions`.
    private func writeRejectionSidecar(
        for file: URL,
        reason: String,
        outcome: QuarantineRecord.Outcome,
        actionName: String?,
        client: String?
    ) {
        let sidecar = file.deletingPathExtension().appendingPathExtension("rejection.json")
        let payload = QuarantineRecord(
            schemaVersion: ActionSchema.version,
            rejectedAt: now(),
            reason: reason,
            outcome: outcome,
            actionName: actionName,
            client: client
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
