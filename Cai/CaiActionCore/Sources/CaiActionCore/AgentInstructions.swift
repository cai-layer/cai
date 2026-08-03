import Foundation

/// What every connected agent is told once, at handshake.
///
/// MCP servers may return an `instructions` string from `initialize`, and
/// clients put it in the model's context before the first tool call. That makes
/// it the only place to say things an agent needs *before* it decides to reach
/// for Cai at all: when authoring an action is the right move, that a proposal
/// is inert until a human approves it, and what to check before proposing
/// something that runs code.
///
/// Deliberately short. This text is resident in the agent's context for the
/// whole session, so per-tool mechanics (fields, templating, chain shapes) stay
/// in the tool descriptions where they are read on demand. Anything that can
/// live in a tool description belongs there, not here. The approval boundary is
/// the one thing said in both places, because an agent may read only one.
///
/// Only the helper serves this, but it lives in the shared package because the
/// helper is an executable that tests cannot import; here it is covered by
/// `AgentInstructionsTests` like every other decision in `CaiActionCore`.
public enum AgentInstructions {

    public static let text = """
        Cai runs actions on whatever the user has selected, anywhere on their Mac, when they \
        press Option+C. You author those actions; they keep working after this conversation \
        ends, without you.

        Reach for this when the user describes something they will want again on arbitrary text: \
        a rewrite they keep asking for, a lookup they keep pasting into a URL, a command they \
        keep running on a filename. One-off work you can just do yourself.

        Nothing you send here takes effect on its own. A proposal waits in Cai until the user \
        approves it, and you cannot approve, run, or delete anything. So after proposing, tell \
        the user it is waiting for them in Cai. There is no notification back to you: call \
        list_actions to see whether they took it. Approval takes human time, so do not wait \
        or poll; check next time the user asks.

        Before proposing an action that runs a shell command, opens a URL with the selection \
        in it, or replaces the selection unseen, check three things: the user asked for exactly \
        this, the value carries no secrets or credentials, and no path reaches outside what \
        they named. Cai flags these actions to the user at approval time.

        Propose one action for one real need. A batch of speculative actions is noise the user \
        has to read and refuse.
        """
}
