import Foundation

/// Process-wide state and diagnostics for the helper.
enum CaiMCPHelper {

    /// Reported to clients in the MCP handshake.
    ///
    /// Read from the app bundle this helper is embedded in, at
    /// `Cai.app/Contents/Helpers/cai-mcp`, so it always matches the Cai that
    /// shipped it. Not a constant, which drifts the first time the app is
    /// released, and not `MARKETING_VERSION`, which is a stale 1.0 in the
    /// project while the real version lives in the app's Info.plist.
    static let version: String = {
        let helper = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        let appInfoPlist = helper
            .deletingLastPathComponent()   // Helpers
            .deletingLastPathComponent()   // Contents
            .appendingPathComponent("Info.plist")

        guard
            let data = try? Data(contentsOf: appInfoPlist),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String
        else {
            // Running outside a Cai bundle, which is a developer thing to do.
            return "unknown"
        }
        return version
    }()

    /// Client name from the MCP handshake, stamped onto every proposal as
    /// provenance so the approval sheet can say who asked. An actor-isolated
    /// box because the handshake and the tool calls arrive on different tasks.
    private actor ClientBox {
        var name: String?
        func set(_ value: String) { name = value }
    }

    private static let clientBox = ClientBox()

    static func setClientName(_ name: String) async {
        await clientBox.set(name)
    }

    static func clientName() async -> String? {
        await clientBox.name
    }

    /// stderr only. stdout carries JSON-RPC and a stray line there kills the
    /// session.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("cai-mcp: \(message)\n".utf8))
    }
}
