import SwiftUI

/// Generic form renderer for MCP-powered actions.
/// Renders any `MCPActionConfig` into a form — text fields, pickers, multiselects —
/// driven entirely by the config. No provider-specific UI code needed.
///
/// Flow: auto-connect if needed → LLM-generate title/body → fetch picker options → user edits → submit.
struct MCPFormView: View {
    let actionConfig: MCPActionConfig
    let clipboardText: String
    let sourceApp: String?
    let contentType: ContentType?
    let onBack: () -> Void
    let onDismiss: () -> Void

    /// Static flag so ActionListWindow can check if a picker dropdown is open
    /// (ESC should close dropdown first, not navigate back).
    static var pickerDropdownOpen = false

    // MARK: - Form State

    /// Current field values, keyed by field id ("title", "body", "repo", etc.)
    @State private var fieldValues: [String: String] = [:]
    /// Selected options for multiselect fields, keyed by field id
    @State private var multiSelectValues: [String: Set<String>] = [:]
    /// Fetched options for picker/multiselect fields, keyed by field id
    @State private var pickerOptions: [String: [MCPPickerOption]] = [:]
    /// Loading states per field
    @State private var fieldLoading: [String: Bool] = [:]
    /// Search text for searchable picker fields (local filter)
    @State private var searchText: [String: String] = [:]
    /// Whether the searchable picker dropdown is expanded
    @State private var searchExpanded: [String: Bool] = [:]
    /// All pre-fetched options for searchable pickers (unfiltered)
    @State private var allPickerOptions: [String: [MCPPickerOption]] = [:]
    /// Tracks last parent value used to fetch dependent fields (avoids redundant fetches)
    @State private var lastDependentParent: [String: String] = [:]

    // MARK: - Triage State

    @State private var triageResults: [MCPTriageResult] = []
    @State private var showTriageExpanded: Bool = false
    @State private var isSearchingDuplicates: Bool = false
    @State private var commentOnIssue: MCPTriageResult?  // Set when user chooses "Add comment"
    @State private var lastTriageKey: String = ""        // Tracks last title+repo combo to avoid redundant searches
    @State private var triageDebounceTask: Task<Void, Never>?  // Cancellable debounce for triage search

    // MARK: - Overall State

    @State private var isConnecting: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var hasSubmitted: Bool = false
    @State private var isGeneratingLLM: Bool = false
    @State private var errorMessage: String?
    @State private var isConnectionError: Bool = false
    @State private var successMessage: String?
    @State private var resultURL: String?

    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()
                .background(Color.caiDivider)

            if isConnecting {
                connectingView
            } else if let success = successMessage {
                successView(success)
            } else {
                formContent
            }
        }
        .task {
            await initialize()
        }
        .onAppear {
            WindowController.passThrough = true
        }
        .onDisappear {
            WindowController.passThrough = false
            Self.pickerDropdownOpen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiMCPFormSubmit)) { _ in
            Task { await submit() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiEscPressed)) { _ in
            // If a picker dropdown is open, close it instead of letting ActionListWindow navigate back
            if closeAnyOpenDropdown() {
                return
            }
        }
        .onChange(of: searchExpanded) { newValue in
            Self.pickerDropdownOpen = newValue.values.contains(true)
        }
        .onChange(of: fieldValues) { newValues in
            // Fetch options for fields that depend on a parent field value
            for field in actionConfig.fields {
                guard case .mcpDependentOn(let parentField, _, _) = field.source else { continue }
                let parentValue = newValues[parentField] ?? ""
                let lastParent = lastDependentParent[field.id] ?? ""
                // Only re-fetch when parent actually changed to a non-empty value
                if !parentValue.isEmpty && parentValue != lastParent {
                    lastDependentParent[field.id] = parentValue
                    Task { await fetchDependentOptions(for: field) }
                }
            }

            // Triage: search for duplicates when title AND scope (repo/team) are both available
            if let triageConfig = actionConfig.triageConfig {
                let title = newValues[triageConfig.queryField] ?? ""
                let scopeValue = triageConfig.scopeField.flatMap { newValues[$0] } ?? ""
                // Only search when we have both a title and a scope (scoped search)
                // Re-trigger when either changes
                let triageKey = "\(title)|\(scopeValue)"
                if !title.isEmpty && !scopeValue.isEmpty && triageKey != lastTriageKey {
                    lastTriageKey = triageKey
                    // Debounce: cancel previous search, wait 500ms before firing
                    triageDebounceTask?.cancel()
                    let currentConfig = triageConfig
                    let currentTitle = title
                    triageDebounceTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        await searchForDuplicates(query: currentTitle, triageConfig: currentConfig)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            connectorIcon(name: actionConfig.icon)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(actionConfig.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)

                Text(clipboardText)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Connecting…")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    // MARK: - Success

    private func successView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.caiTextPrimary)
                .multilineTextAlignment(.center)

            if let url = resultURL, let link = URL(string: url) {
                Button(action: {
                    NSWorkspace.shared.open(link)
                    // Close Cai after opening the link
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                    }
                }) {
                    Text("View ticket ↗")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.caiPrimary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }

            Spacer()

            KeyboardHint(key: "↩", label: "Dismiss")
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .onAppear {
            // Success screen has no text editors — disable passThrough so Enter dismisses
            WindowController.passThrough = false
        }
    }

    // MARK: - Form Content

    private var formContent: some View {
        VStack(spacing: 0) {
            ZStack {
                // Click-outside overlay — dismiss any open dropdown
                if searchExpanded.values.contains(true) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeAnyOpenDropdown() }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            if let error = errorMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.system(size: 11))
                                        .foregroundColor(.red)
                                    if isConnectionError {
                                        Spacer()
                                        Button("Retry") {
                                            errorMessage = nil
                                            isConnectionError = false
                                            Task { await initialize() }
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.caiPrimary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.red.opacity(0.08))
                                .cornerRadius(6)
                                .id("formError")
                            }

                            ForEach(actionConfig.fields) { field in
                                fieldView(for: field)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: errorMessage) { newError in
                        if newError != nil {
                            withAnimation {
                                proxy.scrollTo("formError", anchor: .top)
                            }
                        }
                    }
                }
            }

            Divider()
                .background(Color.caiDivider)

            footerView
        }
    }

    // MARK: - Field Rendering

    @ViewBuilder
    private func fieldView(for field: MCPFieldConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)

                if field.required {
                    Text("*")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                }

                if fieldLoading[field.id] == true {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
            }

            switch field.type {
            case .text:
                textField(for: field)
            case .textarea:
                textAreaField(for: field)
            case .picker:
                pickerField(for: field)
            case .multiselect:
                multiselectField(for: field)
            case .searchablePicker:
                searchablePickerField(for: field)
            }

            // Triage hint — shown below the title field when similar issues are found
            if field.id == actionConfig.triageConfig?.queryField {
                triageHintView
            }
        }
    }

    // MARK: - Triage Hint

    @ViewBuilder
    private var triageHintView: some View {
        if isSearchingDuplicates {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 10, height: 10)
                Text("Checking for similar issues…")
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
            }
        } else if !triageResults.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // Collapsed hint row
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showTriageExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("\(triageResults.count) similar issue\(triageResults.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                        Image(systemName: showTriageExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Expanded results
                if showTriageExpanded {
                    VStack(spacing: 0) {
                        ForEach(triageResults) { result in
                            triageResultRow(result)
                            if result.id != triageResults.last?.id {
                                Divider().opacity(0.2).padding(.horizontal, 8)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.caiSurface.opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.caiDivider.opacity(0.3), lineWidth: 0.5)
                    )
                }
            }
        }
    }

    private func triageResultRow(_ result: MCPTriageResult) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let url = result.url {
                    Text(url)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.caiTextSecondary.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // View in browser
            if let url = result.url, let link = URL(string: url) {
                Button(action: {
                    NSWorkspace.shared.open(link)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onDismiss() }
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundColor(.caiPrimary)
                }
                .buttonStyle(.plain)
            }

            // Add comment (only if commentTool is configured)
            if actionConfig.triageConfig?.commentTool != nil {
                Button(action: {
                    commentOnIssue = result
                }) {
                    Text("Comment")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(commentOnIssue?.id == result.id ? .white : .caiPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(commentOnIssue?.id == result.id ? Color.caiPrimary : Color.caiPrimary.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func textField(for field: MCPFieldConfig) -> some View {
        let binding = Binding<String>(
            get: { fieldValues[field.id] ?? "" },
            set: { fieldValues[field.id] = $0 }
        )
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.caiSurface.opacity(0.6))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
            TextField(field.label, text: binding)
                .font(.system(size: 13))
                .foregroundColor(.caiTextPrimary)
                .textFieldStyle(.plain)
                .padding(8)
                .focused($focusedField, equals: field.id)
        }
        .frame(height: 32)
    }

    private func textAreaField(for field: MCPFieldConfig) -> some View {
        let binding = Binding<String>(
            get: { fieldValues[field.id] ?? "" },
            set: { fieldValues[field.id] = $0 }
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.caiSurface.opacity(0.6))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
            TextEditor(text: binding)
                .font(.system(size: 13))
                .foregroundColor(.caiTextPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(8)
                .focused($focusedField, equals: field.id)
        }
        .frame(minHeight: 80, maxHeight: 120)
    }

    private func pickerField(for field: MCPFieldConfig) -> some View {
        let options = pickerOptions[field.id] ?? []
        let binding = Binding<String>(
            get: { fieldValues[field.id] ?? "" },
            set: { fieldValues[field.id] = $0 }
        )
        return Group {
            if options.isEmpty && fieldLoading[field.id] != true {
                Text("No options available")
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                Picker("", selection: binding) {
                    Text("Select…").tag("")
                    ForEach(options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func multiselectField(for field: MCPFieldConfig) -> some View {
        let options = pickerOptions[field.id] ?? []
        let selected = multiSelectValues[field.id] ?? []
        // Check if this field depends on a parent and whether the parent has a value
        let parentEmpty: Bool = {
            if case .mcpDependentOn(let parentField, _, _) = field.source {
                return (fieldValues[parentField] ?? "").isEmpty
            }
            return false
        }()

        return Group {
            if options.isEmpty && fieldLoading[field.id] != true {
                let hint: String = {
                    if parentEmpty, case .mcpDependentOn(let parentField, _, _) = field.source {
                        let parentLabel = actionConfig.fields.first(where: { $0.id == parentField })?.label ?? parentField
                        return "Select a \(parentLabel.lowercased()) first"
                    }
                    return "No options available"
                }()
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                // Horizontally wrapping chips
                FlowLayout(spacing: 6) {
                    ForEach(options) { option in
                        let isSelected = selected.contains(option.id)
                        Button(action: {
                            toggleMultiSelect(field: field.id, optionId: option.id)
                        }) {
                            Text(option.label)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? .white : .caiTextPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(isSelected ? Color.caiPrimary : Color.caiSurface.opacity(0.8))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(isSelected ? Color.clear : Color.caiDivider.opacity(0.5), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func searchablePickerField(for field: MCPFieldConfig) -> some View {
        let allOptions = allPickerOptions[field.id] ?? []
        let isExpanded = searchExpanded[field.id] == true
        let currentValue = fieldValues[field.id] ?? ""
        let query = (searchText[field.id] ?? "").lowercased()

        // Local filter — instant, no MCP calls
        let filteredOptions = query.isEmpty ? allOptions : allOptions.filter {
            $0.label.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }

        return VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.caiSurface.opacity(0.6))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)

                if isExpanded {
                    TextField("Filter repositories…", text: Binding(
                        get: { searchText[field.id] ?? "" },
                        set: { searchText[field.id] = $0 }
                    ))
                    .font(.system(size: 13))
                    .foregroundColor(.caiTextPrimary)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .focused($focusedField, equals: field.id)
                } else {
                    HStack {
                        Text(currentValue.isEmpty ? "Select repository…" : currentValue)
                            .font(.system(size: 13))
                            .foregroundColor(currentValue.isEmpty ? .caiTextSecondary : .caiTextPrimary)
                        Spacer()
                        if fieldLoading[field.id] == true {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(.caiTextSecondary)
                        }
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchExpanded[field.id] = true
                        searchText[field.id] = ""
                        focusedField = field.id
                    }
                }
            }
            .frame(height: 32)

            // Dropdown results
            if isExpanded {
                VStack(spacing: 0) {
                    if fieldLoading[field.id] == true && allOptions.isEmpty {
                        HStack {
                            ProgressView().scaleEffect(0.5)
                            Text("Loading repositories…")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary)
                        }
                        .padding(8)
                    } else if filteredOptions.isEmpty {
                        Text(query.isEmpty ? "No repositories found" : "No match for \"\(searchText[field.id] ?? "")\"")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary)
                            .padding(8)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(filteredOptions) { option in
                                    Button(action: {
                                        fieldValues[field.id] = option.id
                                        searchExpanded[field.id] = false
                                        saveLastUsed(field: field.id, value: option.id)
                                    }) {
                                        HStack {
                                            Text(option.label)
                                                .font(.system(size: 12))
                                                .foregroundColor(.caiTextPrimary)
                                            Spacer()
                                            if option.id == currentValue {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.caiPrimary)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(option.id == currentValue ? Color.caiPrimary.opacity(0.1) : Color.clear)
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.caiSurface)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
                )
            }
        }
    }

    /// Pre-fetches all options for searchable picker fields (runs in parallel with LLM generation).
    /// Flow: get_me → username, get_teams → org names, then search user + each org in parallel.
    private func prefetchSearchableOptions(serverConfig: MCPServerConfig) async {
        for field in actionConfig.fields where field.type == .searchablePicker {
            guard case .mcpPrefetch(let contextTool, let contextPath, let orgsTool, let searchTool, let queryParam) = field.source else { continue }

            await MainActor.run { fieldLoading[field.id] = true }
            let serverId = serverConfig.id

            do {
                // Step 1: Get username
                let contextResponse = try await MCPClientService.shared.callTool(
                    serverConfigId: serverId,
                    toolName: contextTool,
                    arguments: [:]
                )
                let username = Self.extractJSONValue(from: contextResponse, key: contextPath) ?? ""


                // Step 2: Discover orgs via get_teams (optional — fails gracefully)
                var orgNames: Set<String> = []
                if let orgsTool = orgsTool {
                    do {
                        let teamsResponse = try await MCPClientService.shared.callTool(
                            serverConfigId: serverId,
                            toolName: orgsTool,
                            arguments: [:]
                        )
                        // Extract org names from teams response (array of objects with "org" or "organization" field)
                        orgNames = Self.extractOrgNames(from: teamsResponse)

                    } catch {
                        // Silently continue — orgs won't appear in repo search but user repos still work
                    }
                }

                // Step 3: Build queries — user:xxx + org:xxx for each org
                var queries = ["user:\(username)"]
                for org in orgNames {
                    queries.append("org:\(org)")
                }

                // Step 4: Run all queries in parallel and merge results
                var allOptions: [MCPPickerOption] = []
                var seenIds: Set<String> = []

                // Use callTool directly (not fetchOptions) — the cache keys by toolName only,
                // which breaks when the same tool is called with different arguments (user: vs org:).
                await withTaskGroup(of: [MCPPickerOption].self) { group in
                    for query in queries {
                        group.addTask {
                            do {
                                let response = try await MCPClientService.shared.callTool(
                                    serverConfigId: serverId,
                                    toolName: searchTool,
                                    arguments: [queryParam: query]
                                )
                                let options = MCPClientService.shared.parsePickerOptions(from: response, toolName: searchTool)
                                return options
                            } catch {
                                return []
                            }
                        }
                    }

                    for await options in group {
                        for option in options where !seenIds.contains(option.id) {
                            seenIds.insert(option.id)
                            allOptions.append(option)
                        }
                    }
                }

                allOptions.sort { $0.label.lowercased() < $1.label.lowercased() }


                await MainActor.run {
                    allPickerOptions[field.id] = allOptions
                    fieldLoading[field.id] = false
                }
            } catch {
                await MainActor.run { fieldLoading[field.id] = false }
            }
        }
    }

    /// Extracts unique organization names from a get_teams MCP response.
    /// Handles both array-of-teams and nested formats.
    static func extractOrgNames(from response: String) -> Set<String> {
        var orgs: Set<String> = []
        guard let data = response.data(using: .utf8) else { return orgs }

        // Try as JSON array of team objects
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for team in array {
                if let org = team["org"] as? String { orgs.insert(org) }
                else if let org = team["organization"] as? String { orgs.insert(org) }
                else if let orgObj = team["organization"] as? [String: Any],
                        let login = orgObj["login"] as? String { orgs.insert(login) }
                else if let org = team["org"] as? [String: Any],
                        let login = org["login"] as? String { orgs.insert(login) }
            }
        }
        // Try as top-level object with teams array
        else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let teams = json["teams"] as? [[String: Any]] {
                for team in teams {
                    if let org = team["org"] as? String { orgs.insert(org) }
                    else if let orgObj = team["organization"] as? [String: Any],
                            let login = orgObj["login"] as? String { orgs.insert(login) }
                }
            }
        }

        // Also try to find org names via regex as fallback (e.g., "org":"clipboard-ai")
        if orgs.isEmpty {
            let pattern = "\"(?:org|organization)\"\\s*:\\s*\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(in: response, range: NSRange(response.startIndex..., in: response))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: response) {
                        orgs.insert(String(response[range]))
                    }
                }
            }
        }

        return orgs
    }

    // MARK: - Dependent Field Fetching

    /// Fetches options for a field that depends on another field's value (e.g., labels after repo selection).
    private func fetchDependentOptions(for field: MCPFieldConfig) async {
        guard case .mcpDependentOn(let parentField, let toolName, let argumentMapping) = field.source else { return }
        let parentValue = fieldValues[parentField] ?? ""
        guard !parentValue.isEmpty else { return }

        await MainActor.run {
            fieldLoading[field.id] = true
            // Clear previous options and selections when parent changes
            pickerOptions[field.id] = []
            fieldValues[field.id] = ""
            // Only clear multiselect state for multiselect fields (avoids making pickers look like arrays)
            if field.type == .multiselect {
                multiSelectValues[field.id] = []
            } else {
                multiSelectValues.removeValue(forKey: field.id)
            }
        }

        // Resolve argument mapping — supports {{parent:owner}} and {{parent:name}} for "owner/repo" splitting
        var arguments: [String: Any] = [:]
        for (param, template) in argumentMapping {
            let resolved: String
            if template.contains("{{parent:owner}}") {
                let parts = parentValue.split(separator: "/", maxSplits: 1)
                resolved = parts.count >= 1 ? String(parts[0]) : parentValue
            } else if template.contains("{{parent:name}}") {
                let parts = parentValue.split(separator: "/", maxSplits: 1)
                resolved = parts.count >= 2 ? String(parts[1]) : parentValue
            } else if template.contains("{{parent}}") {
                resolved = parentValue
            } else {
                resolved = template
            }
            arguments[param] = resolved
        }

        do {
            // Bypass cache — dependent fields have dynamic arguments (e.g., different repo → different labels)
            let response = try await MCPClientService.shared.callTool(
                serverConfigId: actionConfig.serverConfigId,
                toolName: toolName,
                arguments: arguments
            )
            let options = MCPClientService.shared.parsePickerOptions(from: response, toolName: toolName, idKey: field.pickerIdKey)
            await MainActor.run {
                pickerOptions[field.id] = options
                fieldLoading[field.id] = false
            }
        } catch {
            await MainActor.run { fieldLoading[field.id] = false }
        }
    }

    // MARK: - Dropdown Dismiss

    /// Closes any open searchable picker dropdown. Returns true if one was closed.
    @discardableResult
    private func closeAnyOpenDropdown() -> Bool {
        for field in actionConfig.fields where field.type == .searchablePicker {
            if searchExpanded[field.id] == true {
                searchExpanded[field.id] = false
                Self.pickerDropdownOpen = false
                return true
            }
        }
        return false
    }

    // MARK: - Last Used Persistence

    private static func lastUsedKey(actionId: String, fieldId: String) -> String {
        "mcp_lastUsed_\(actionId)_\(fieldId)"
    }

    private func saveLastUsed(field: String, value: String) {
        let key = Self.lastUsedKey(actionId: actionConfig.id, fieldId: field)
        UserDefaults.standard.set(value, forKey: key)
    }

    private func loadLastUsed(field: String) -> String? {
        let key = Self.lastUsedKey(actionId: actionConfig.id, fieldId: field)
        return UserDefaults.standard.string(forKey: key)
    }

    private func toggleMultiSelect(field: String, optionId: String) {
        var current = multiSelectValues[field] ?? []
        if current.contains(optionId) {
            current.remove(optionId)
        } else {
            current.insert(optionId)
        }
        multiSelectValues[field] = current
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if isSubmitting {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Submitting…")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
            } else if commentOnIssue != nil {
                Button(action: { commentOnIssue = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                        Text("Cancel comment mode")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.caiTextSecondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 12) {
                KeyboardHint(key: "Esc", label: "Back")
                KeyboardHint(key: "⌘↩", label: commentOnIssue != nil ? "Add Comment" : actionConfig.confirmLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Initialization

    private func initialize() async {
        // Step 1: Ensure MCP server is connected
        guard let serverConfig = MCPConfigManager.shared.serverConfigs.first(where: { $0.id == actionConfig.serverConfigId }) else {
            errorMessage = "Server configuration not found"
            return
        }

        let status = await MCPClientService.shared.status(for: serverConfig.id)
        if !status.isConnected {
            await MainActor.run { isConnecting = true }
            do {
                try await MCPClientService.shared.ensureConnected(config: serverConfig)
            } catch {
                await MainActor.run {
                    isConnecting = false
                    errorMessage = error.localizedDescription
                    isConnectionError = true
                }
                return
            }
            await MainActor.run { isConnecting = false }
        }

        // Step 2: Load last-used values for searchable picker fields
        for field in actionConfig.fields where field.type == .searchablePicker {
            if let lastUsed = loadLastUsed(field: field.id) {
                await MainActor.run { fieldValues[field.id] = lastUsed }
            }
        }

        // Step 3: Run LLM generation + searchable picker prefetch + regular picker fetch IN PARALLEL
        await withTaskGroup(of: Void.self) { group in
            // LLM generation
            if let llmPrompt = actionConfig.llmPrompt {
                group.addTask { await generateLLMFields(prompt: llmPrompt) }
            }

            // Prefetch searchable picker repos (parallel with LLM)
            group.addTask { await prefetchSearchableOptions(serverConfig: serverConfig) }

            // Regular picker/multiselect options
            group.addTask { await fetchPickerOptions(serverConfig: serverConfig) }

            await group.waitForAll()
        }

        // Focus first text field
        if let firstTextField = actionConfig.fields.first(where: { $0.type == .text }) {
            await MainActor.run { focusedField = firstTextField.id }
        }
    }

    /// Content-type hint prepended to LLM system prompt for smarter ticket generation.
    private var contentTypeHint: String {
        guard let type = contentType else { return "" }
        switch type {
        case .url:
            return "The clipboard contains a URL. Reference it in the description.\n\n"
        case .json:
            return "The clipboard contains JSON/API data. Pretty-print relevant parts in the description.\n\n"
        case .address:
            return "The clipboard contains a physical address.\n\n"
        case .meeting:
            return "The clipboard contains meeting/calendar details.\n\n"
        case .image:
            return "The clipboard contains OCR text extracted from an image.\n\n"
        case .caiExtension, .word, .shortText, .longText, .empty:
            return ""
        }
    }

    private func generateLLMFields(prompt: MCPLLMPrompt) async {
        await MainActor.run {
            isGeneratingLLM = true
            fieldLoading[prompt.titleField] = true
            if let bodyField = prompt.bodyField {
                fieldLoading[bodyField] = true
            }
        }

        do {
            let systemPrompt = contentTypeHint + prompt.systemPrompt
            let messages = [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: clipboardText)
            ]
            let response = try await LLMService.shared.generateWithMessages(messages)

            // Parse "TITLE: ...\n\n<body>" format
            let (title, body) = parseLLMResponse(response)

            await MainActor.run {
                fieldValues[prompt.titleField] = title
                if let bodyField = prompt.bodyField {
                    fieldValues[bodyField] = body
                }
                isGeneratingLLM = false
                fieldLoading[prompt.titleField] = false
                if let bodyField = prompt.bodyField {
                    fieldLoading[bodyField] = false
                }
            }

            // Triage search is triggered via onChange(of: fieldValues) once both
            // title and repo are available — not here, to avoid searching across all repos.
        } catch {
            await MainActor.run {
                isGeneratingLLM = false
                fieldLoading[prompt.titleField] = false
                if let bodyField = prompt.bodyField {
                    fieldLoading[bodyField] = false
                }
                // Don't block the form — user can type manually
                errorMessage = "AI generation failed — type manually"
            }
        }
    }

    private func parseLLMResponse(_ response: String) -> (title: String, body: String) {
        var trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown fences that small models commonly produce
        trimmed = trimmed.replacingOccurrences(of: "```", with: "")
        // Strip bold/italic markdown from TITLE prefix ("**TITLE:**" → "TITLE:")
        trimmed = trimmed.replacingOccurrences(of: "**TITLE:**", with: "TITLE:")
        trimmed = trimmed.replacingOccurrences(of: "**TITLE**:", with: "TITLE:")
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)

        var title: String
        var body: String

        // Try "TITLE: <title>\n\n<body>" format
        if trimmed.hasPrefix("TITLE:") {
            let afterTitle = trimmed.dropFirst("TITLE:".count).trimmingCharacters(in: .whitespaces)
            if let range = afterTitle.range(of: "\n\n") {
                title = String(afterTitle[afterTitle.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                body = String(afterTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // No body separator — everything is title
                title = afterTitle
                body = ""
            }
        } else {
            // Fallback: first line = title, rest = body
            let lines = trimmed.components(separatedBy: "\n")
            title = lines.first ?? trimmed
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Enforce title length limit — truncate gracefully at word boundary
        let maxTitleLength = 200
        if title.count > maxTitleLength {
            let truncated = String(title.prefix(maxTitleLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                title = String(truncated[..<lastSpace])
            } else {
                title = truncated
            }
        }

        return (title, body)
    }

    private func fetchPickerOptions(serverConfig: MCPServerConfig) async {
        // Fetch options for all picker/multiselect fields in parallel
        await withTaskGroup(of: (String, [MCPPickerOption]).self) { group in
            for field in actionConfig.fields {
                // searchablePicker fields search on-demand — skip them here
                guard (field.type == .picker || field.type == .multiselect) && field.type != .searchablePicker else { continue }

                let fieldId = field.id

                switch field.source {
                case .staticOptions(let options):
                    // Static options — no MCP call needed
                    group.addTask { (fieldId, options) }

                case .mcp(let toolName):
                    await MainActor.run { fieldLoading[fieldId] = true }
                    group.addTask {
                        do {
                            let options = try await MCPClientService.shared.fetchOptions(
                                serverConfigId: serverConfig.id,
                                toolName: toolName,
                                arguments: [:]
                            )
                            return (fieldId, options)
                        } catch {
                            return (fieldId, [])
                        }
                    }

                default:
                    continue
                }
            }

            for await (fieldId, options) in group {
                await MainActor.run {
                    pickerOptions[fieldId] = options
                    fieldLoading[fieldId] = false
                }
            }
        }
    }

    /// Extracts a value from a JSON string by key (top-level only).
    static func extractJSONValue(from jsonText: String, key: String) -> String? {
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] else { return nil }
        if let str = value as? String { return str }
        if let num = value as? Int { return String(num) }
        return nil
    }

    // MARK: - Triage Search

    /// Searches for similar/duplicate issues using the triage config.
    private func searchForDuplicates(query: String, triageConfig: MCPTriageConfig) async {
        await MainActor.run { isSearchingDuplicates = true }

        do {
            // Build search arguments — provider-aware via config
            var arguments: [String: Any] = [:]
            let config = MCPConfigManager.shared.serverConfigs.first(where: { $0.id == actionConfig.serverConfigId })

            if config?.providerType == .github {
                // GitHub: search syntax with repo: and is:issue qualifiers
                let repo = fieldValues["repo"] ?? ""
                guard !repo.isEmpty else {
                    await MainActor.run { isSearchingDuplicates = false }
                    return
                }
                arguments["query"] = "\(query) repo:\(repo) is:issue"
            } else {
                // Linear and others: use query param + extra arguments from config
                arguments["query"] = query
                // Resolve searchArgumentMapping (e.g., "teamId": "{{scope}}" → actual team ID)
                let scopeValue = triageConfig.scopeField.flatMap { fieldValues[$0] } ?? ""
                for (param, template) in triageConfig.searchArgumentMapping {
                    arguments[param] = template.replacingOccurrences(of: "{{scope}}", with: scopeValue)
                }
            }

            let response = try await MCPClientService.shared.callTool(
                serverConfigId: actionConfig.serverConfigId,
                toolName: triageConfig.searchTool,
                arguments: arguments
            )

            // Parse results
            let results = parseTriageResults(from: response, maxResults: triageConfig.maxResults)

            await MainActor.run {
                triageResults = results
                isSearchingDuplicates = false
            }
        } catch {
            await MainActor.run { isSearchingDuplicates = false }
        }
    }

    /// Parses search results into triage results (title, URL, ID).
    private func parseTriageResults(from response: String, maxResults: Int) -> [MCPTriageResult] {
        guard let data = response.data(using: .utf8) else { return [] }

        // Parse JSON — search results are typically an array or wrapped in an object
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var items: [[String: Any]] = []

        if let array = json as? [[String: Any]] {
            items = array
        } else if let dict = json as? [String: Any] {
            // Unwrap common wrappers: "items", "issues", "nodes"
            for key in ["items", "issues", "nodes", "data"] {
                if let nested = dict[key] as? [[String: Any]] {
                    items = nested
                    break
                }
            }
            // Fallback: find first array value
            if items.isEmpty {
                for (_, value) in dict {
                    if let nested = value as? [[String: Any]] {
                        items = nested
                        break
                    }
                }
            }
        }

        return Array(items.prefix(maxResults).compactMap { obj -> MCPTriageResult? in
            let title = (obj["title"] as? String) ?? ""
            guard !title.isEmpty else { return nil }

            let id = (obj["number"] as? Int).map(String.init)
                ?? (obj["identifier"] as? String)  // Linear uses "identifier" (e.g., "ENG-123")
                ?? (obj["id"] as? String)
                ?? (obj["id"] as? Int).map(String.init)
                ?? title

            let url = (obj["html_url"] as? String)
                ?? (obj["url"] as? String)

            return MCPTriageResult(id: id, title: title, url: url)
        })
    }

    // MARK: - Submit

    func submit() async {
        guard !isSubmitting && !hasSubmitted else { return }

        // Validate required fields
        for field in actionConfig.fields where field.required {
            let value: String
            if field.type == .multiselect {
                let selected = multiSelectValues[field.id] ?? []
                value = selected.isEmpty ? "" : "has_value"
            } else {
                value = fieldValues[field.id] ?? ""
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run {
                    errorMessage = "\(field.label) is required"
                }
                return
            }
        }

        await MainActor.run {
            isSubmitting = true
            hasSubmitted = true
            errorMessage = nil
        }

        // Build tool arguments from submitMapping
        var arguments: [String: Any] = [:]

        // Static arguments first (e.g., "method": "create")
        for (key, value) in actionConfig.staticArguments {
            arguments[key] = value
        }

        // Dynamic arguments from field values
        for (toolParam, template) in actionConfig.submitMapping {
            let resolved = resolveTemplate(template)
            // Skip empty optional values
            guard !resolved.isEmpty else { continue }

            if isArrayField(template) {
                // Multiselect fields → always send as array (even single selection)
                let items = resolved.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                arguments[toolParam] = items
            } else if let intVal = Int(resolved), isNumericField(template) {
                // Numeric fields (e.g., priority 0-4) → send as Int, not String
                arguments[toolParam] = intVal
            } else {
                arguments[toolParam] = resolved
            }
        }

        // Comment flow — if user chose "Add comment" on a triage result
        if let issue = commentOnIssue,
           let triageConfig = actionConfig.triageConfig,
           let commentTool = triageConfig.commentTool {
            do {
                var commentArgs: [String: Any] = [:]
                // Resolve comment mapping (e.g., owner, repo, issue_number)
                for (param, template) in triageConfig.commentMapping {
                    if template == "{{issue_id}}" {
                        commentArgs[param] = issue.id
                    } else {
                        commentArgs[param] = resolveTemplate(template)
                    }
                }
                // Add the body — use the generated body field or clipboard text
                let body = fieldValues[actionConfig.llmPrompt?.bodyField ?? "body"] ?? clipboardText
                commentArgs["body"] = body

                let result = try await MCPClientService.shared.callTool(
                    serverConfigId: actionConfig.serverConfigId,
                    toolName: commentTool,
                    arguments: commentArgs
                )

                let extractedURL = issue.url ?? Self.extractURL(from: result)

                await MainActor.run {
                    isSubmitting = false
                    resultURL = extractedURL
                    successMessage = "Comment added to #\(issue.id)"
                    WindowController.passThrough = false
                }

                if let url = extractedURL {
                    SystemActions.copyToClipboard(url)
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    hasSubmitted = false
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        do {
            let result = try await MCPClientService.shared.callTool(
                serverConfigId: actionConfig.serverConfigId,
                toolName: actionConfig.submitTool,
                arguments: arguments
            )

            // Check for error indicators in response (some servers don't set isError)
            if let errorMsg = Self.extractErrorMessage(from: result) {
                await MainActor.run {
                    isSubmitting = false
                    hasSubmitted = false  // Allow retry
                    errorMessage = errorMsg
                }
                return
            }

            // Extract URL from response (GitHub returns JSON with html_url, or plain URL)
            let extractedURL = Self.extractURL(from: result)

            await MainActor.run {
                isSubmitting = false
                resultURL = extractedURL
                successMessage = "Created successfully"
                // Disable passThrough immediately so Enter key dismisses
                WindowController.passThrough = false
                CrashReportingService.shared.addBreadcrumb(
                    category: "mcp",
                    message: "Tool call succeeded: \(actionConfig.submitTool)"
                )
            }

            // Copy result URL (or full response) to clipboard
            if let url = extractedURL {
                SystemActions.copyToClipboard(url)
            } else if !result.isEmpty {
                SystemActions.copyToClipboard(result)
            }
        } catch {
            await MainActor.run {
                isSubmitting = false
                hasSubmitted = false  // Allow retry
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Resolves a template like "{{title}}", "{{labels}}", or "{{repo:owner}}" from field values.
    /// Supports `:owner` / `:name` suffixes to split slash-separated values (e.g., "owner/repo").
    private func resolveTemplate(_ template: String) -> String {
        var result = template
        let pattern = "\\{\\{([^}]+)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))

        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: template) else { continue }
            let key = String(template[range])
            let replacement: String

            // Handle {{field:owner}} and {{field:name}} for "owner/repo" splitting
            if key.contains(":") {
                let parts = key.split(separator: ":", maxSplits: 1)
                let fieldId = String(parts[0])
                let accessor = String(parts[1])
                let rawValue = fieldValues[fieldId] ?? ""
                let slashParts = rawValue.split(separator: "/", maxSplits: 1)

                switch accessor {
                case "owner":
                    replacement = slashParts.count >= 1 ? String(slashParts[0]) : rawValue
                case "name":
                    replacement = slashParts.count >= 2 ? String(slashParts[1]) : rawValue
                default:
                    replacement = rawValue
                }
            }
            // Check multiselect
            else if let selected = multiSelectValues[key], !selected.isEmpty {
                replacement = selected.sorted().joined(separator: ",")
            } else {
                replacement = fieldValues[key] ?? ""
            }

            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        return result
    }

    /// Checks MCP response for error indicators (e.g., GitHub returns {"message": "Not Found"}).
    /// Returns a user-friendly error message if detected, nil if the response looks successful.
    static func extractErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // GitHub API error pattern: {"message": "Not Found", "status": "404"}
        if let message = json["message"] as? String {
            let status: String? = (json["status"] as? String) ?? (json["status"] as? Int).map { "\($0)" }
            let lowerMsg = message.lowercased()
            if lowerMsg.contains("not found") || lowerMsg.contains("forbidden") ||
               lowerMsg.contains("unauthorized") || lowerMsg.contains("error") ||
               lowerMsg.contains("denied") || lowerMsg.contains("permission") {
                return status != nil ? "\(message) (\(status!))" : message
            }
        }

        // Generic error field
        if let error = json["error"] as? String {
            return error
        }

        return nil
    }

    /// Extracts a URL from MCP tool response text.
    /// Tries JSON parsing first (html_url, url fields), then regex fallback.
    static func extractURL(from text: String) -> String? {
        // Try JSON — GitHub MCP returns {"html_url": "https://...", ...}
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Prefer html_url (GitHub), then url
            if let url = json["html_url"] as? String { return url }
            if let url = json["url"] as? String, url.hasPrefix("https://") { return url }
        }

        // Regex fallback — find first HTTPS URL in text
        let pattern = "https://[^\\s\"',\\]\\)>]+"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return String(text[range])
        }

        return nil
    }

    /// Checks if a template references a multiselect field (which produces comma-separated values).
    private func isArrayField(_ template: String) -> Bool {
        let pattern = "\\{\\{([^}]+)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)),
              let range = Range(match.range(at: 1), in: template) else { return false }
        let key = String(template[range])
        return multiSelectValues[key] != nil
    }

    /// Checks if a template field uses static numeric options (e.g., priority 0-4).
    private func isNumericField(_ template: String) -> Bool {
        let pattern = "\\{\\{([^}]+)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)),
              let range = Range(match.range(at: 1), in: template) else { return false }
        let key = String(template[range])
        // Check if this field uses staticOptions with numeric IDs
        guard let field = actionConfig.fields.first(where: { $0.id == key }),
              case .staticOptions(let options) = field.source else { return false }
        return options.allSatisfy { Int($0.id) != nil }
    }
}

// MARK: - Flow Layout

/// Simple horizontal flow layout for chips/tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Connector Icon Helper

extension MCPFormView {
    @ViewBuilder
    private func connectorIcon(name: String) -> some View {
        switch name {
        case "github.logo":
            GitHubIcon(color: .caiPrimary)
        case "linear.logo":
            LinearIcon(color: .caiPrimary)
        default:
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)
        }
    }
}
