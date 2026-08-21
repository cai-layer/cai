import SwiftUI

/// The **Connections** screen: the single "what can Cai reach, and what can
/// reach Cai" surface. Three tabs:
///
/// - **Tools** — external tools Cai calls out to (GitHub, Linear): the
///   `ConnectorsSettingsView`. (Internally these are MCP *clients*.)
/// - **Agents** — coding agents that reach into Cai to propose actions: the
///   `cai-mcp` helper. (Internally the MCP *server*.)
/// - **System Access** — the on-demand macOS privacy grants an action may read
///   from (Calendar, Reminders, Contacts), plus read-only status for the
///   grants Cai cannot request (Accessibility, Automation):
///   `NativeAccessSettingsView`.
///
/// One row in Settings rather than three, because to a user they are one
/// question — "who/what has access" — and a person hunting for any of them
/// should find one door. Tabs rather than nesting, because the three must not
/// blur: outbound tools, inbound agents, and OS grants are mechanically
/// different, and a labelled tab keeps them distinct.
///
/// The type keeps its old `MCPManagementView` name (and the file keeps its
/// path) because "MCP" is the accurate internal term for two of the three tabs;
/// the word never renders. See `_docs/architecture/MCP.md` (Cai as a Server)
/// and `_docs/architecture/PERMISSIONS.md` (System Access).
///
/// **Agents leads, for now.** DESIGN.md gives the dominant slot to the
/// most-edited tab, which taken literally would be Tools: connectors hold
/// credentials a user comes back to, while connecting an agent is a one-time
/// job. It is second anyway, because the release that introduces this screen is
/// headlined "create Cai actions from Claude Code" and nearly every visit for a
/// while will be someone wiring an agent up. Revisit once authoring stops being
/// the new thing; the cost today is that a Tools user lands one click from where
/// they used to arrive.
struct MCPManagementView: View {

    @ObservedObject private var configManager = MCPServerConfigManager.shared
    let onBack: () -> Void

    enum Tab: Hashable {
        case tools, agents, systemAccess
    }

    @State private var selectedTab: Tab

    /// `initialTab` defaults to Agents (the headline for this release), but the
    /// missing-credentials redirect passes `.tools`: a user sent here to enter
    /// an API key must land on the connector form, not on agent setup.
    init(onBack: @escaping () -> Void, initialTab: Tab = .agents) {
        self.onBack = onBack
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        ManagementScreen(
            icon: "link",
            title: "Connections",
            subtitle: subtitle,
            tabs: [
                .init(id: .agents, label: "Agents"),
                .init(id: .tools, label: "Tools", count: configManager.configuredCount),
                .init(id: .systemAccess, label: "System Access"),
            ],
            selection: $selectedTab,
            customTabId: nil,
            onAdd: nil
        ) {
            switch selectedTab {
            case .tools:
                ConnectorsSettingsView(onBack: onBack, showsChrome: false)
            case .agents:
                ConnectAgentContent()
            case .systemAccess:
                NativeAccessSettingsView()
            }
        }
    }

    private var subtitle: String {
        switch selectedTab {
        case .tools:
            return "Tools Cai can use, like GitHub or Linear"
        case .agents:
            return "Agents that can propose actions to Cai"
        case .systemAccess:
            // "read" would be a promise the tab breaks: Reminders creates,
            // Calendar adds, Automation sends. "access" covers all five grants.
            return "What Cai can access on your Mac"
        }
    }
}
