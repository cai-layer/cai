import CaiActionCore
import Foundation
import MCP

/// Adapts MCP tool calls onto `AgentAuthoring`.
///
/// Deliberately thin. Everything that decides anything (what arguments are
/// valid, what the proposal becomes, what the agent is told) lives in
/// CaiActionCore where it is tested; a command-line target has nowhere to hang
/// unit tests, so anything left here is code nobody can verify. What remains
/// is argument re-encoding, error mapping, and file IO.
enum ToolDispatch {

    static func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case Tools.listActions.name:
                return reply(try listActions())
            case Tools.createAction.name:
                return reply(try await createAction(params.arguments))
            case Tools.updateAction.name:
                return reply(try await updateAction(params.arguments))
            default:
                return failure("Unknown tool '\(params.name)'.")
            }
        } catch let rejection as ActionRejection {
            return failure(rejection.reason)
        } catch let preflight as AgentAuthoring.PreflightFailure {
            return failure(preflight.reason)
        } catch let bridge as CaiBridge.BridgeError {
            return failure(bridge.reason)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    // MARK: - Tools

    private static func listActions() throws -> String {
        AgentReply.actionsListing(
            snapshot: try CaiBridge.snapshot(),
            statuses: ProposalStatus.all()
        )
    }

    private static func createAction(_ arguments: [String: Value]?) async throws -> String {
        let snapshot = try preflight()
        let draft = try AgentAuthoring.decodeCreate(arguments: json(arguments))
        let change = AgentAuthoring.createProposal(
            draft: draft,
            provenance: await CaiBridge.provenance(),
            id: UUID(),
            now: Date()
        )
        return try submit(change, known: snapshot.knownActions)
    }

    private static func updateAction(_ arguments: [String: Value]?) async throws -> String {
        let snapshot = try preflight()
        let input = try AgentAuthoring.decodeUpdate(arguments: json(arguments))
        let change = try AgentAuthoring.updateProposal(
            input: input,
            snapshot: snapshot,
            provenance: await CaiBridge.provenance(),
            id: UUID(),
            now: Date()
        )
        return try submit(change, known: snapshot.knownActions)
    }

    // MARK: - Shared

    private static func preflight() throws -> ActionsSnapshot {
        let snapshot = try CaiBridge.snapshot()
        try AgentAuthoring.preflight(
            snapshot: snapshot,
            isCaiRunning: CaiBridge.isCaiRunning,
            pendingCount: ProposalWriter.pendingCount()
        )
        return snapshot
    }

    /// Validated here only so the agent hears about a bad payload now rather
    /// than after the user has been shown a toast. The app runs the same
    /// validator again on what it reads; this verdict grants nothing.
    private static func submit(_ change: PendingChange, known: KnownActions) throws -> String {
        let validated = try ActionValidator.validate(change, known: known)
        try ProposalWriter.write(change)
        return AgentReply.proposalAccepted(validated: validated, actionName: validated.after.name)
    }

    /// MCP hands arguments over as its own `Value` tree; the core speaks JSON.
    private static func json(_ arguments: [String: Value]?) -> Data {
        (try? JSONEncoder().encode(arguments ?? [:])) ?? Data("{}".utf8)
    }

    private static func reply(_ text: String) -> CallTool.Result {
        .init(content: [.text(text)], isError: false)
    }

    private static func failure(_ text: String) -> CallTool.Result {
        .init(content: [.text(text)], isError: true)
    }
}
