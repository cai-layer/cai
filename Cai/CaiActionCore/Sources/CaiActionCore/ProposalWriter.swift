import Foundation

/// Writes a proposal into the pending directory.
///
/// Atomic, always: the app watches this directory and reads whatever appears,
/// so a file that becomes visible before it is complete is a proposal the user
/// might be shown half of. `Data.write(options: .atomic)` writes to a temporary
/// file and renames, and rename is atomic on APFS, so the app either sees the
/// whole file or no file.
///
/// 0600 because a proposal carries whatever text the agent put in it, which
/// can include the user's selection.
public enum ProposalWriter {

    public enum WriteError: Error, Equatable {
        case couldNotCreateDirectory(String)
        case couldNotWrite(String)
    }

    /// File name for a change. The change id names the file so a retry with
    /// the same id replaces rather than duplicates.
    public static func fileName(for change: PendingChange) -> String {
        "\(change.id.uuidString).json"
    }

    @discardableResult
    public static func write(_ change: PendingChange, root: URL = CaiSupportPaths.root) throws -> URL {
        let directory = CaiSupportPaths.pendingChanges(in: root)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WriteError.couldNotCreateDirectory(error.localizedDescription)
        }

        let url = directory.appendingPathComponent(fileName(for: change))
        do {
            let data = try ActionCoding.encoder.encode(change)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            throw WriteError.couldNotWrite(error.localizedDescription)
        }
    }

    /// How many proposals are already waiting. The helper checks this before
    /// writing so an agent in a loop is told the queue is full rather than
    /// burying the user.
    public static func pendingCount(root: URL = CaiSupportPaths.root) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: CaiSupportPaths.pendingChanges(in: root),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }
}

/// What became of a proposal, as far as the filesystem can say.
///
/// There is no push channel to the agent by design, so this is how it finds
/// out: it polls `list_actions` and reads these back.
public struct ProposalStatus: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        case waitingForApproval
        case refused
        /// The user read the proposal and said no. Distinct from `refused`,
        /// which is Cai declining to accept it at all: a refusal is worth
        /// fixing and retrying, a decline is an answer.
        case declined

        public var description: String {
            switch self {
            case .waitingForApproval: return "waiting for approval"
            case .refused: return "rejected by Cai"
            case .declined: return "declined by the user — do not re-send it unless they ask"
            }
        }
    }

    public let id: String
    public let state: State
    public let reason: String?
    /// What the proposal is, so an agent with several in flight can tell the
    /// status lines apart: the action name for a create, the target for an
    /// update. `nil` when the file no longer says (older sidecars, unreadable
    /// payloads); the line then carries the id alone.
    public let label: String?
    /// Which connected client sent it. Proposals from every agent share one
    /// queue by design (that is what prevents duplicates); the label is what
    /// keeps an agent from reading another's decline as its own.
    public let client: String?

    public init(id: String, state: State, reason: String?, label: String? = nil, client: String? = nil) {
        self.id = id
        self.state = state
        self.reason = reason
        self.label = label
        self.client = client
    }
}

extension ProposalStatus {

    /// Reads the pending directory and the quarantine beside it.
    ///
    /// An approved or rejected proposal leaves no file behind, so absence is
    /// how an agent learns the user decided; the reason a refusal gives is
    /// what lets it retry correctly rather than resending the same thing.
    public static func all(root: URL = CaiSupportPaths.root) -> [ProposalStatus] {
        var statuses: [ProposalStatus] = []

        let pending = (try? FileManager.default.contentsOfDirectory(
            at: CaiSupportPaths.pendingChanges(in: root),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        for file in pending.filter({ $0.pathExtension == "json" })
            .prefix(ActionSchema.maxPendingFilesScanned) {
            let change = boundedRead(file)
                .flatMap { try? ActionCoding.decoder.decode(PendingChange.self, from: $0) }
            statuses.append(ProposalStatus(
                id: Self.clamp(file.deletingPathExtension().lastPathComponent),
                state: .waitingForApproval,
                reason: nil,
                label: change.map { Self.clamp(Self.label(for: $0)) },
                client: change?.provenance.client.map { Self.clamp($0) }
            ))
        }

        let quarantined = (try? FileManager.default.contentsOfDirectory(
            at: CaiSupportPaths.quarantine(in: root),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in quarantined.filter({ $0.lastPathComponent.hasSuffix(".rejection.json") })
            .prefix(ActionSchema.maxQuarantinedFiles) {
            let record = boundedRead(file)
                .flatMap { try? ActionCoding.decoder.decode(QuarantineRecord.self, from: $0) }
            statuses.append(ProposalStatus(
                id: Self.clamp(file.lastPathComponent.replacingOccurrences(of: ".rejection.json", with: "")),
                state: record?.outcome == .declined ? .declined : .refused,
                reason: (record?.reason).map { Self.clamp($0, limit: 500) },
                label: record?.actionName.map { Self.clamp($0) },
                client: record?.client.map { Self.clamp($0) }
            ))
        }

        return statuses.sorted { $0.id < $1.id }
    }

    /// Reads a file from a directory any local process can write, with the
    /// same guards the app's scanner applies before touching bytes: regular
    /// files only, bounded size. A FIFO or a link to something huge dropped
    /// in the directory must not hang `list_actions`. `nil` means unreadable,
    /// and the status line then carries the filename id alone.
    public static func boundedRead(_ file: URL) -> Data? {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true,
              (values?.fileSize ?? 0) <= ActionSchema.maxPendingFileBytes
        else { return nil }
        return try? Data(contentsOf: file)
    }

    /// One line saying what a still-pending proposal is. Creates carry their
    /// action name; updates name the action they target, which is the id the
    /// agent itself passed to `update_action`.
    static func label(for change: PendingChange) -> String {
        switch change.operation {
        case .create(let draft):
            return draft.name
        case .update(let update):
            return "update to action \(update.targetId.uuidString)"
        }
    }

    /// These strings come out of files any local process can write, and they
    /// go straight into every connected agent's context. A valid name is at
    /// most 60 characters (`ActionValidator`), but validation has not run yet
    /// when a pending file is listed, so the length has to be enforced here.
    /// Control characters (newlines included) go the same way as the length:
    /// every status field is single-line by design, and no legitimate reason
    /// contains a newline (`excerptsAroundDifference` collapses whitespace),
    /// while `unknownField` and date-decode reasons interpolate raw payload
    /// text. A reason carrying `\n\nSYSTEM:` must not reach the agent with
    /// its fake structure intact. Reasons get a wider bound so a legitimate
    /// mismatch excerpt survives whole.
    static func clamp(_ text: String, limit: Int = 80) -> String {
        let cleaned = text.strippingControlCharacters(keepingNewlines: false)
        return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit)) + "…"
    }
}
