import AppKit
import CaiActionCore
import Foundation

/// The helper's two questions about the machine it runs on: is Cai there, and
/// what does it currently know.
///
/// Everything else moved into CaiActionCore. What is left needs AppKit or the
/// filesystem, so it could not be tested here anyway.
enum CaiBridge {

    enum BridgeError: Error {
        case noSnapshot

        var reason: String {
            switch self {
            case .noSnapshot:
                return "Cai has not published its actions yet. Ask the user to open Cai once, then try again."
            }
        }
    }

    /// Both bundle IDs, because a developer dogfooding Cai runs the Debug
    /// build and the helper should talk to whichever is actually there.
    ///
    /// Never a process-name check: Debug and Release are both called "Cai",
    /// so matching on the name would report the wrong one as running.
    static let bundleIdentifiers = ["com.soyasis.cai", "com.soyasis.cai.dev"]

    static var isCaiRunning: Bool {
        bundleIdentifiers.contains { identifier in
            !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
        }
    }

    static func snapshot() throws -> ActionsSnapshot {
        guard
            let data = try? Data(contentsOf: CaiSupportPaths.actionsSnapshot()),
            let snapshot = try? ActionCoding.decoder.decode(ActionsSnapshot.self, from: data)
        else {
            throw BridgeError.noSnapshot
        }
        return snapshot
    }

    static func provenance(now: Date = Date()) async -> ActionProvenance {
        ActionProvenance(source: .mcp, client: await CaiMCPHelper.clientName(), authoredAt: now)
    }
}
