import Foundation

// MARK: - MCP Action Config Registry

/// Registry of MCP action configs for known providers.
/// Hardcoded for GitHub and Linear. Future: data-driven via JSON or MCP tool schemas.
class MCPActionConfigRegistry {

    static let shared = MCPActionConfigRegistry()

    private init() {}

    // MARK: - Available Actions

    /// Returns MCP action configs for all enabled servers.
    var availableActions: [MCPActionConfig] {
        var actions: [MCPActionConfig] = []
        for config in MCPServerConfigManager.shared.serverConfigs where config.isEnabled {
            // Show actions regardless of API key — if key is missing,
            // clicking the action navigates to Connectors setup instead.
            let configs = actionConfigs(for: config)
            actions.append(contentsOf: configs)
        }
        return actions
    }

    // MARK: - Action Config Dispatch

    /// Returns action configs for a given server based on its provider type.
    /// Hardcoded for known providers (GitHub, Linear). No actions for custom servers yet.
    /// Future: move to JSON file or derive from MCP tool schemas.
    func actionConfigs(for server: MCPServerConfig) -> [MCPActionConfig] {
        switch server.providerType {
        case .github:
            return [Self.githubCreateIssue(serverConfigId: server.id)]
        case .linear:
            return [Self.linearCreateIssue(serverConfigId: server.id)]
        case .custom:
            return []
        }
    }

    // MARK: - Shared Prompts

    /// Shared LLM system prompt for ticket creation (used by GitHub + Linear).
    private static let ticketCreationSystemPrompt = """
        Create a ticket from the user's text. Classify as bug, feature, or task.
        Output EXACTLY in this format — no markdown fences, no extra text:

        TITLE: <specific, actionable title under 80 chars>

        <2-4 sentence description. For bugs: what fails, where, and likely cause. \
        For features: what and why. For tasks: scope and acceptance criteria.>

        Example input: "TypeError: Cannot read property 'map' of undefined at Dashboard.jsx:156"
        Example output:
        TITLE: TypeError in Dashboard.jsx when data array is undefined

        A TypeError occurs at Dashboard.jsx:156 when calling .map() on an undefined value. \
        Likely caused by missing data initialization or a failed API response returning null \
        instead of an empty array. Add a null check or default to [] before mapping.
        """

    // MARK: - GitHub Action Configs

    static func githubCreateIssue(serverConfigId: UUID) -> MCPActionConfig {
        MCPActionConfig(
            id: "github_create_issue_\(serverConfigId.uuidString)",
            serverConfigId: serverConfigId,
            displayName: "Create GitHub Issue",
            icon: "github.logo",
            confirmLabel: "Create Issue",
            llmPrompt: MCPLLMPrompt(
                systemPrompt: ticketCreationSystemPrompt,
                titleField: "title",
                bodyField: "body"
            ),
            fields: [
                MCPFieldConfig(id: "repo", label: "Repository", type: .searchablePicker, source: .mcpPrefetch(
                    contextTool: "get_me",
                    contextPath: "login",
                    orgsTool: "get_teams",
                    searchTool: "search_repositories",
                    queryParam: "query"
                ), required: true),
                MCPFieldConfig(id: "title", label: "Title", type: .text, source: .llm, required: true),
                MCPFieldConfig(id: "body", label: "Description", type: .textarea, source: .llm, required: true),
                MCPFieldConfig(id: "labels", label: "Labels", type: .multiselect, source: .mcpDependentOn(
                    parentField: "repo",
                    toolName: "list_label",
                    argumentMapping: ["owner": "{{parent:owner}}", "repo": "{{parent:name}}"]
                ), pickerIdKey: "name"),  // GitHub expects label names, not node IDs
            ],
            submitTool: "issue_write",
            submitMapping: [
                "owner": "{{repo:owner}}",   // Splits "owner/repo" → "owner"
                "repo": "{{repo:name}}",     // Splits "owner/repo" → "repo"
                "title": "{{title}}",
                "body": "{{body}}",
                "labels": "{{labels}}",
            ],
            staticArguments: ["method": "create"],
            triageConfig: MCPTriageConfig(
                searchTool: "search_issues",
                queryField: "title",
                scopeField: "repo",
                commentTool: "add_issue_comment",
                commentMapping: [
                    "owner": "{{repo:owner}}",
                    "repo": "{{repo:name}}",
                    "issue_number": "{{issue_id}}"
                ],
                maxResults: 3
            )
        )
    }

    // MARK: - Linear Action Configs

    static func linearCreateIssue(serverConfigId: UUID) -> MCPActionConfig {
        MCPActionConfig(
            id: "linear_create_issue_\(serverConfigId.uuidString)",
            serverConfigId: serverConfigId,
            displayName: "Create Linear Issue",
            icon: "linear.logo",
            confirmLabel: "Create Issue",
            llmPrompt: MCPLLMPrompt(
                systemPrompt: ticketCreationSystemPrompt,
                titleField: "title",
                bodyField: "body"
            ),
            fields: [
                MCPFieldConfig(id: "title", label: "Title", type: .text, source: .llm, required: true),
                MCPFieldConfig(id: "body", label: "Description", type: .textarea, source: .llm, required: true),
                MCPFieldConfig(id: "team", label: "Team", type: .picker, source: .mcp(toolName: "list_teams"), required: true),
                MCPFieldConfig(id: "project", label: "Project", type: .picker, source: .mcpDependentOn(
                    parentField: "team",
                    toolName: "list_projects",
                    argumentMapping: ["team": "{{parent}}"]
                )),
                MCPFieldConfig(id: "priority", label: "Priority", type: .picker, source: .staticOptions([
                    MCPPickerOption(id: "0", label: "No priority"),
                    MCPPickerOption(id: "1", label: "Urgent"),
                    MCPPickerOption(id: "2", label: "High"),
                    MCPPickerOption(id: "3", label: "Medium"),
                    MCPPickerOption(id: "4", label: "Low"),
                ])),
                MCPFieldConfig(id: "labels", label: "Labels", type: .multiselect, source: .mcpDependentOn(
                    parentField: "team",
                    toolName: "list_issue_labels",
                    argumentMapping: ["team": "{{parent}}"]
                )),
                MCPFieldConfig(id: "assignee", label: "Assignee", type: .picker, source: .mcp(toolName: "list_users")),
            ],
            submitTool: "save_issue",
            submitMapping: [
                "team": "{{team}}",
                "project": "{{project}}",
                "title": "{{title}}",
                "description": "{{body}}",
                "priority": "{{priority}}",
                "labels": "{{labels}}",
                "assignee": "{{assignee}}",
            ],
            // No triage for Linear — their MCP doesn't expose issue search.
            // list_issues returns all issues (no query filtering), so results are irrelevant.
            triageConfig: nil
        )
    }
}
