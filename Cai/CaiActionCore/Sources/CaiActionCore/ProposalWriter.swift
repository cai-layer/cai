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

        public var description: String {
            switch self {
            case .waitingForApproval: return "waiting for approval"
            case .refused: return "rejected by Cai"
            }
        }
    }

    public let id: String
    public let state: State
    public let reason: String?

    public init(id: String, state: State, reason: String?) {
        self.id = id
        self.state = state
        self.reason = reason
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
        for file in pending where file.pathExtension == "json" {
            statuses.append(ProposalStatus(
                id: file.deletingPathExtension().lastPathComponent,
                state: .waitingForApproval,
                reason: nil
            ))
        }

        let quarantined = (try? FileManager.default.contentsOfDirectory(
            at: CaiSupportPaths.quarantine(in: root),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in quarantined where file.lastPathComponent.hasSuffix(".rejection.json") {
            let reason = (try? Data(contentsOf: file))
                .flatMap { try? ActionCoding.decoder.decode(QuarantineRecord.self, from: $0) }?
                .reason
            statuses.append(ProposalStatus(
                id: file.lastPathComponent.replacingOccurrences(of: ".rejection.json", with: ""),
                state: .refused,
                reason: reason
            ))
        }

        return statuses.sorted { $0.id < $1.id }
    }
}
