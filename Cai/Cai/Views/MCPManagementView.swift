import SwiftUI

/// Unified "MCP" screen: the two directions MCP runs in, under one parent.
///
/// **Client** is Cai reaching out to tools (GitHub, Linear): the existing
/// Connectors screen. **Server** is an agent reaching into Cai to propose
/// actions: the `cai-mcp` helper.
///
/// One row in Settings rather than two, because they are the same protocol and
/// a user looking for "the MCP thing" should find one door. Tabs rather than
/// nesting, because the directions must not blur: the design review's original
/// instruction was to keep author and consume visually distinct, and a labelled
/// tab does that better than a separate section did. See the deviations table in
/// `_docs/planning/active/MCP-AUTHORING-MLP-PLAN.md`.
///
/// The tab labels are short jargon; the subtitle underneath does the explaining,
/// which is how the header earns its keep on both tabs.
///
/// **Server leads, for now.** DESIGN.md gives the dominant slot to the
/// most-edited tab, which taken literally would be Client: connectors hold
/// credentials a user comes back to, while connecting an agent is a one-time
/// job. It is second anyway, because the release that introduces this screen is
/// headlined "create Cai actions from Claude Code" and nearly every visit for a
/// while will be someone wiring an agent up. Revisit once authoring stops being
/// the new thing; the cost today is that a Connectors user lands one click from
/// where they used to arrive.
struct MCPManagementView: View {

    @ObservedObject private var configManager = MCPServerConfigManager.shared
    let onBack: () -> Void

    enum Tab: Hashable {
        case client, server
    }

    @State private var selectedTab: Tab

    /// `initialTab` defaults to Server (the headline for this release), but
    /// the missing-credentials redirect passes `.client`: a user sent here to
    /// enter an API key must land on the form, not on agent setup.
    init(onBack: @escaping () -> Void, initialTab: Tab = .server) {
        self.onBack = onBack
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        ManagementScreen(
            icon: "link",
            title: "MCP",
            subtitle: subtitle,
            tabs: [
                .init(id: .server, label: "Server"),
                .init(id: .client, label: "Client", count: configManager.configuredCount),
            ],
            selection: $selectedTab,
            customTabId: nil,
            onAdd: nil
        ) {
            switch selectedTab {
            case .client:
                ConnectorsSettingsView(onBack: onBack, showsChrome: false)
            case .server:
                ConnectAgentContent()
            }
        }
    }

    private var subtitle: String {
        switch selectedTab {
        case .client:
            return "Tools Cai can use, like GitHub or Linear"
        case .server:
            return "Agents that can propose actions to Cai"
        }
    }
}
