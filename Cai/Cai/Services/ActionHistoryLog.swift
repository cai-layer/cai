import CaiActionCore
import Foundation

/// One line of the authoring audit trail.
///
/// Carries the FULL before and after values, not a summary. That is the point:
/// until there is a revert UI, this file is what lets a user (or a bug report)
/// reconstruct by hand exactly what an approved change did to an action.
///
/// The payloads are the user's own action definitions, held locally with the
/// same 0600 discipline as the pending files, and never uploaded anywhere
/// (CAI-07 is about leaking user text into logs and crash reports; this log is
/// a local, deliberate record the user can delete).
struct ActionAuditEntry: Codable, Equatable {

    enum Outcome: String, Codable {
        case approved
        case rejected
        case quarantined
    }

    let timestamp: Date
    /// Id of the proposal, which is also the created action's id.
    let changeId: UUID
    /// "create" or "update".
    let operation: String
    let outcome: Outcome
    let actionId: UUID?
    let actionName: String
    let provenance: ActionProvenance?
    let before: ActionSnapshot?
    let after: ActionSnapshot?
    /// Rejection reason, for quarantined proposals.
    let reason: String?
}

/// Append-only audit log at `~/Library/Application Support/Cai/action-history.json`.
///
/// Writes run on a private serial queue: an entry can carry two 10K payloads,
/// and rewriting the file is not something the approve button should wait on.
/// The queue also gives ordering for free, so reads (`entries()`, which hops
/// onto the same queue) always see every append issued before them.
final class ActionHistoryLog {

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.soyasis.cai.audit")

    init(fileURL: URL = CaiSupportPaths.auditLog()) {
        self.fileURL = fileURL
    }

    func append(_ entry: ActionAuditEntry) {
        queue.async { [fileURL] in
            var entries: [ActionAuditEntry]
            switch Self.load(from: fileURL) {
            case .some(let existing):
                entries = existing
            case .none:
                // Unreadable: keep the bytes rather than overwrite them.
                Self.preserveCorruptLog(at: fileURL)
                entries = []
            }
            entries.append(entry)
            // Oldest out first. The log is a revert aid, not an archive.
            if entries.count > ActionSchema.maxAuditEntries {
                entries.removeFirst(entries.count - ActionSchema.maxAuditEntries)
            }
            guard let data = try? ActionCoding.encoder.encode(entries) else { return }
            do {
                try data.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                print("AuditLog: could not write \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Everything on disk. Synchronizes with pending appends. An unreadable
    /// log reads as empty; it never throws, because no caller can do anything
    /// useful with the failure.
    func entries() -> [ActionAuditEntry] {
        queue.sync { Self.load(from: fileURL) ?? [] }
    }

    /// `nil` means the file exists but could not be decoded. A missing file is
    /// an empty log, which is the normal first-run state.
    private static func load(from fileURL: URL) -> [ActionAuditEntry]? {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try? ActionCoding.decoder.decode([ActionAuditEntry].self, from: data)
    }

    /// Moves an unreadable log aside before it gets overwritten. History is
    /// the only revert path that exists today, so losing it silently to one
    /// bad byte would be worse than the corruption itself.
    private static func preserveCorruptLog(at fileURL: URL) {
        let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        print("AuditLog: could not read \(fileURL.lastPathComponent); kept a copy at \(backup.lastPathComponent)")
    }
}
