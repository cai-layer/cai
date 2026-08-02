import Foundation

/// Process-wide state and diagnostics for the helper.
enum CaiMCPHelper {

    static let version = "1.0.0"

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
