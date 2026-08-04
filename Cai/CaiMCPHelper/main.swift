import CaiActionCore
import Foundation
import MCP

/// `cai-mcp`: the stdio bridge between a coding agent and Cai.
///
/// Runs as a child process of whatever agent spawned it (Claude Code, Cursor,
/// any stdio MCP client), speaks JSON-RPC over stdin and stdout, and hands
/// proposed actions to Cai by writing files. There is no socket and no port,
/// so no website and no other process on the network can reach it.
///
/// It validates with the same `ActionValidator` the app uses, purely so an
/// agent gets an immediate, specific error instead of silence. That validation
/// grants nothing: the app re-validates every byte it reads and never trusts
/// this process.
///
/// **stdout belongs to the protocol.** Anything printed there corrupts the
/// JSON-RPC stream and the client disconnects, so every diagnostic goes to
/// stderr.
let server = Server(
    name: "cai",
    version: CaiMCPHelper.version,
    instructions: AgentInstructions.text,
    capabilities: .init(tools: .init(listChanged: false))
)

let transport = StdioTransport()

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: Tools.all)
}

await server.withMethodHandler(CallTool.self) { params in
    await ToolDispatch.call(params)
}

try await server.start(transport: transport) { clientInfo, _ in
    CaiMCPHelper.log("connected to \(clientInfo.name) \(clientInfo.version)")
    await CaiMCPHelper.setClientName(clientInfo.name)
}

await server.waitUntilCompleted()
