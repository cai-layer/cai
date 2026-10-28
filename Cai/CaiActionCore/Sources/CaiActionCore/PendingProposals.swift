import Foundation

/// One proposal read back out of the pending directory.
///
/// The helper writes into that directory and, since revisable proposals, also
/// reads from it: an agent revising what it just proposed needs to see the
/// draft it is amending. Everything here is untrusted (any local process can
/// write the directory), so this type carries the bytes as decoded and grants
/// nothing. `ActionValidator` still runs on whatever is written back, in the
/// helper and again in the app.
public struct PendingProposalFile: Equatable, Sendable {
    public let url: URL
    public let change: PendingChange
    /// The file's own modification date, used only to pick the newest of
    /// several candidates. `.distantPast` when the filesystem would not say.
    public let modifiedAt: Date

    public init(url: URL, change: PendingChange, modifiedAt: Date = .distantPast) {
        self.url = url
        self.change = change
        self.modifiedAt = modifiedAt
    }
}

public enum PendingProposals {

    /// Every pending file this process can make sense of.
    ///
    /// Two filters, both deliberate:
    ///
    /// - Undecodable files are skipped. They are still reported by
    ///   `ProposalStatus.all()` (which lists them by filename alone), so the
    ///   agent hears about them; they just cannot be the target of a revision.
    /// - A file whose **name does not match the id inside it** is skipped.
    ///   `ProposalWriter` always names a file by its change id, and the
    ///   revision path depends on that: resolving `A.json` by the payload id
    ///   `B` it happens to carry would write the revision to `B.json` and
    ///   leave `A.json` behind, which is the duplicate card this whole change
    ///   exists to prevent. Nothing legitimate writes a mismatched file.
    public static func all(root: URL = CaiSupportPaths.root) -> [PendingProposalFile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: CaiSupportPaths.pendingChanges(in: root),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
            .prefix(ActionSchema.maxPendingFilesScanned)
            .compactMap { file in
                guard let data = ProposalStatus.boundedRead(file),
                      let change = try? ActionCoding.decoder.decode(PendingChange.self, from: data),
                      nameMatchesPayload(file: file, id: change.id)
                else { return nil }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return PendingProposalFile(url: file, change: change, modifiedAt: modified ?? .distantPast)
            }
    }

    /// Case-insensitive because a `UUID` round-trips uppercase and a file
    /// copied through a case-preserving tool need not.
    static func nameMatchesPayload(file: URL, id: UUID) -> Bool {
        file.deletingPathExtension().lastPathComponent
            .caseInsensitiveCompare(id.uuidString) == .orderedSame
    }
}
