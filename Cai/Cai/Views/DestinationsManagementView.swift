import SwiftUI

/// CRUD view for managing output destinations.
/// Built-in destinations (Mail, Notes, Reminders) have enable/disable toggles.
/// Custom destinations support full create/edit/delete with type-specific config.
struct DestinationsManagementView: View {
    @ObservedObject var settings = CaiSettings.shared
    let onBack: () -> Void

    @State private var editingDestinationId: UUID?
    @State private var isAddingNew: Bool = false

    // Form fields
    @State private var formName: String = ""
    @State private var formTypeTag: String = "webhook"
    @State private var formShowInActionList: Bool = false

    // AppleScript
    @State private var formAppleScript: String = ""

    // Webhook
    @State private var formWebhookURL: String = ""
    @State private var formWebhookMethod: String = "POST"
    @State private var formWebhookHeaders: String = "{\"Content-Type\": \"application/json\"}"
    @State private var formWebhookBody: String = ""

    // URL Scheme
    @State private var formURLScheme: String = ""

    // Shell
    @State private var formShellCommand: String = ""

    // Setup fields
    @State private var formSetupFields: [SetupField] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Output Destinations")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)

                Spacer()

                if !isAddingNew && editingDestinationId == nil {
                    Button(action: {
                        resetForm()
                        WindowController.passThrough = true
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isAddingNew = true
                        }
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.caiPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.caiDivider)

            // Content
            ScrollView {
                VStack(spacing: 4) {
                    // Built-in destinations
                    ForEach(settings.outputDestinations.filter { $0.isBuiltIn }) { dest in
                        builtInRow(dest)
                    }

                    if !settings.outputDestinations.filter({ !$0.isBuiltIn }).isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                            .padding(.horizontal, 16)
                    }

                    // Custom destinations
                    ForEach(settings.outputDestinations.filter { !$0.isBuiltIn }) { dest in
                        if editingDestinationId == dest.id {
                            destinationForm(isNew: false, destinationId: dest.id)
                        } else {
                            customRow(dest)
                        }
                    }

                    // Add form
                    if isAddingNew {
                        destinationForm(isNew: true, destinationId: nil)
                    }

                    if settings.outputDestinations.filter({ !$0.isBuiltIn }).isEmpty && !isAddingNew {
                        Text("No custom destinations yet")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 340)

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear {
            WindowController.acceptsFilterInput = false
        }
    }

    // MARK: - Built-in Row

    private func builtInRow(_ dest: OutputDestination) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                Image(systemName: dest.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiPrimary)
            }

            Text(dest.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.caiTextPrimary)

            Spacer()

            Toggle("", isOn: Binding(
                get: { dest.isEnabled },
                set: { newValue in
                    if let index = settings.outputDestinations.firstIndex(where: { $0.id == dest.id }) {
                        settings.outputDestinations[index].isEnabled = newValue
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Custom Row

    private func customRow(_ dest: OutputDestination) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                Image(systemName: dest.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiPrimary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(dest.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(dest.type.label)
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary)
            }

            Spacer()

            if !dest.isConfigured {
                Text("Setup needed")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
            }

            // Edit
            Button(action: {
                loadFormFromDestination(dest)
                WindowController.passThrough = true
                editingDestinationId = dest.id
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            // Delete
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    settings.outputDestinations.removeAll { $0.id == dest.id }
                }
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Form

    private func destinationForm(isNew: Bool, destinationId: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Name
            TextField("Destination name", text: $formName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            // Type picker
            Picker("", selection: $formTypeTag) {
                Text("Webhook").tag("webhook")
                Text("AppleScript").tag("applescript")
                Text("URL Scheme").tag("urlScheme")
                Text("Shell").tag("shell")
            }
            .pickerStyle(.segmented)
            .font(.system(size: 10))

            // Type-specific config
            switch formTypeTag {
            case "applescript":
                appleScriptFields
            case "webhook":
                webhookFields
            case "urlScheme":
                urlSchemeFields
            case "shell":
                shellFields
            default:
                EmptyView()
            }

            // Setup fields
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Setup Fields")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.caiTextSecondary)

                    Spacer()

                    Text("Use {{key}} in templates")
                        .font(.system(size: 9))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                }

                ForEach($formSetupFields) { $field in
                    HStack(spacing: 6) {
                        // Key (template variable name)
                        HStack(spacing: 2) {
                            Text("{{")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.caiTextSecondary.opacity(0.5))
                            TextField("key", text: $field.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 80)
                            Text("}}")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.caiTextSecondary.opacity(0.5))
                        }

                        // Value input
                        if field.isSecret {
                            SecureField("Enter value...", text: $field.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        } else {
                            TextField("Enter value...", text: $field.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }

                        // Secret toggle
                        Button(action: {
                            field.isSecret.toggle()
                        }) {
                            Image(systemName: field.isSecret ? "eye.slash.fill" : "eye")
                                .font(.system(size: 10))
                                .foregroundColor(field.isSecret ? .orange : .caiTextSecondary.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help(field.isSecret ? "Secret field (hidden)" : "Visible field")

                        // Remove
                        Button(action: {
                            formSetupFields.removeAll { $0.id == field.id }
                        }) {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Add setup field button
            Button(action: {
                formSetupFields.append(SetupField(
                    key: ""
                ))
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10))
                    Text("Add Setup Field")
                        .font(.system(size: 10))
                }
                .foregroundColor(.caiPrimary)
            }
            .buttonStyle(.plain)

            // Show in action list toggle
            Toggle("Show in action list", isOn: $formShowInActionList)
                .font(.system(size: 11))

            // Save / Cancel
            HStack {
                Button("Cancel") {
                    cancelForm()
                }
                .font(.system(size: 11))

                Spacer()

                Button(action: {
                    saveForm(isNew: isNew, destinationId: destinationId)
                }) {
                    Text(isNew ? "Add" : "Save")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(formName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.caiSurface.opacity(0.4))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Type-Specific Form Fields

    private var appleScriptFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AppleScript template (use {{result}} for text)")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary)

            TextEditor(text: $formAppleScript)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 80)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.caiSurface.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
                )
        }
    }

    private var webhookFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $formWebhookMethod) {
                    Text("POST").tag("POST")
                    Text("PUT").tag("PUT")
                    Text("PATCH").tag("PATCH")
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                TextField("URL (use {{field}} for setup values)", text: $formWebhookURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            Text("Headers (JSON)")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary)
            TextField("{\"Content-Type\": \"application/json\"}", text: $formWebhookHeaders)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            Text("Body template (use {{result}} for text, {{field}} for setup values)")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary)
            TextEditor(text: $formWebhookBody)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 60)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.caiSurface.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
                )
        }
    }

    private var urlSchemeFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("URL template (use {{result}} for text)")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary)
            TextField("e.g. bear://x-callback-url/create?text={{result}}", text: $formURLScheme)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private var shellFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shell command (stdin receives text, use {{result}} in args)")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary)
            TextEditor(text: $formShellCommand)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 60)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.caiSurface.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Form Helpers

    private func buildDestinationType() -> DestinationType {
        switch formTypeTag {
        case "applescript":
            return .applescript(template: formAppleScript)
        case "webhook":
            let headers = parseHeaders(formWebhookHeaders)
            return .webhook(WebhookConfig(
                url: formWebhookURL,
                method: formWebhookMethod,
                headers: headers,
                bodyTemplate: formWebhookBody
            ))
        case "urlScheme":
            return .urlScheme(template: formURLScheme)
        case "shell":
            return .shell(command: formShellCommand)
        default:
            return .webhook(WebhookConfig(url: "", bodyTemplate: ""))
        }
    }

    private func parseHeaders(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return ["Content-Type": "application/json"]
        }
        return dict
    }

    private func loadFormFromDestination(_ dest: OutputDestination) {
        formName = dest.name
        formShowInActionList = dest.showInActionList
        formSetupFields = dest.setupFields

        switch dest.type {
        case .applescript(let template):
            formTypeTag = "applescript"
            formAppleScript = template
        case .webhook(let config):
            formTypeTag = "webhook"
            formWebhookURL = config.url
            formWebhookMethod = config.method
            if let data = try? JSONSerialization.data(withJSONObject: config.headers, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                formWebhookHeaders = str
            }
            formWebhookBody = config.bodyTemplate
        case .urlScheme(let template):
            formTypeTag = "urlScheme"
            formURLScheme = template
        case .shell(let command):
            formTypeTag = "shell"
            formShellCommand = command
        }
    }

    private func saveForm(isNew: Bool, destinationId: UUID?) {
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let destType = buildDestinationType()

        if isNew {
            let dest = OutputDestination(
                name: trimmedName,
                icon: iconForTypeTag(formTypeTag),
                type: destType,
                isEnabled: true,
                isBuiltIn: false,
                showInActionList: formShowInActionList,
                setupFields: formSetupFields
            )
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.outputDestinations.append(dest)
            }
        } else if let id = destinationId,
                  let index = settings.outputDestinations.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.outputDestinations[index].name = trimmedName
                settings.outputDestinations[index].icon = iconForTypeTag(formTypeTag)
                settings.outputDestinations[index].type = destType
                settings.outputDestinations[index].showInActionList = formShowInActionList
                settings.outputDestinations[index].setupFields = formSetupFields
            }
        }

        cancelForm()
    }

    private func iconForTypeTag(_ tag: String) -> String {
        switch tag {
        case "webhook": return "arrow.up.right.square"
        case "applescript": return "applescript"
        case "urlScheme": return "link"
        case "shell": return "terminal"
        default: return "arrow.up.right.square"
        }
    }

    private func resetForm() {
        formName = ""
        formTypeTag = "webhook"
        formShowInActionList = false
        formAppleScript = ""
        formWebhookURL = ""
        formWebhookMethod = "POST"
        formWebhookHeaders = "{\"Content-Type\": \"application/json\"}"
        formWebhookBody = ""
        formURLScheme = ""
        formShellCommand = ""
        formSetupFields = []
    }

    private func cancelForm() {
        WindowController.passThrough = false
        withAnimation(.easeInOut(duration: 0.15)) {
            isAddingNew = false
            editingDestinationId = nil
        }
        resetForm()
    }
}
