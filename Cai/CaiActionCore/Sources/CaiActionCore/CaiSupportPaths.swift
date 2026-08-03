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
/// Lives in CaiActionCore because the `cai-mcp` helper writes into the same
/// directories and must not be able to disagree with the app about where they
/// are: a helper writing to a path the app does not watch is a proposal that
/// silently never arrives.
///
/// Both bundle IDs (Debug `com.soyasis.cai.dev`, Release `com.soyasis.cai`)
/// resolve to the same directory: the app is unsandboxed, so Application
/// Support is not per-bundle. That is why Debug builds ignore the pending
/// directory unless explicitly opted in; see `PendingChangeGate`.
public enum CaiSupportPaths {

    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cai")
    }

    public static func pendingChanges(in root: URL = root) -> URL {
        root.appendingPathComponent("pending-changes")
    }

    public static func quarantine(in root: URL = root) -> URL {
        pendingChanges(in: root).appendingPathComponent("quarantine")
    }

    public static func auditLog(in root: URL = root) -> URL {
        root.appendingPathComponent("action-history.json")
    }

    /// What the app publishes for the helper to read. See `ActionsSnapshot`.
    public static func actionsSnapshot(in root: URL = root) -> URL {
        root.appendingPathComponent("actions-snapshot.json")
    }

    /// Stable path an agent's config points at, so the configuration survives
    /// the app being moved, renamed or updated. Refreshed on every launch.
    public static func helperSymlink(in root: URL = root) -> URL {
        root.appendingPathComponent("bin").appendingPathComponent("cai-mcp")
    }

    /// Creates the pending directories if they don't exist, owner-only.
    ///
    /// 0700 is not a security boundary against local malware (which runs as
    /// the same user), it keeps other accounts on a shared Mac out of the
    /// user's proposals, which can carry the text they had selected.
    @discardableResult
    public static func ensureDirectories(in root: URL = root) -> Bool {
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
