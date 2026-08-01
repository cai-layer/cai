import Foundation

/// Where Cai keeps the files the authoring pipeline hands back and forth.
///
/// ```
/// ~/Library/Application Support/Cai/
/// ├── pending-changes/            proposals waiting for approval (0700)
/// │   └── quarantine/             proposals the app refused, kept for the agent to read
/// └── action-history.json         audit log with full before/after
/// ```
///
/// Both bundle IDs (Debug `com.soyasis.cai.dev`, Release `com.soyasis.cai`)
/// resolve to the same directory: the app is unsandboxed, so Application
/// Support is not per-bundle. That is why Debug builds ignore the pending
/// directory unless explicitly opted in; see `PendingChangeGate`.
enum CaiSupportPaths {

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cai")
    }

    static func pendingChanges(in root: URL = root) -> URL {
        root.appendingPathComponent("pending-changes")
    }

    static func quarantine(in root: URL = root) -> URL {
        pendingChanges(in: root).appendingPathComponent("quarantine")
    }

    static func auditLog(in root: URL = root) -> URL {
        root.appendingPathComponent("action-history.json")
    }

    /// Creates the pending directories if they don't exist, owner-only.
    ///
    /// 0700 is not a security boundary against local malware (which runs as
    /// the same user), it keeps other accounts on a shared Mac out of the
    /// user's proposals, which can carry the text they had selected.
    @discardableResult
    static func ensureDirectories(in root: URL = root) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: quarantine(in: root),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            print("PendingChanges: could not create \(quarantine(in: root).path): \(error.localizedDescription)")
            return false
        }
    }
}
