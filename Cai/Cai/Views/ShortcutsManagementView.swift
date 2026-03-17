import SwiftUI

/// Management screen for creating, editing, and deleting custom shortcuts.
/// Follows the same layout pattern as ClipboardHistoryView: header, scrollable
/// list, footer with keyboard hints.
struct ShortcutsManagementView: View {
    @ObservedObject var settings = CaiSettings.shared
    let onBack: () -> Void

    @State private var editingShortcutId: UUID?
    @State private var isAddingNew: Bool = false

    // Form fields
    @State private var formName: String = ""
    @State private var formType: CaiShortcut.ShortcutType = .prompt
    @State private var formValue: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Custom Actions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.caiTextPrimary)

                    Text(settings.shortcuts.isEmpty
                         ? "Type to filter actions when Cai is open"
                         : "\(settings.shortcuts.count) custom action\(settings.shortcuts.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.caiDivider)

            // Content
            ScrollView {
                VStack(spacing: 8) {
                    if settings.shortcuts.isEmpty && !isAddingNew {
                        emptyState
                    } else {
                        // Existing shortcuts
                        ForEach(settings.shortcuts) { shortcut in
                            if editingShortcutId == shortcut.id {
                                shortcutForm(isNew: false, shortcutId: shortcut.id)
                            } else {
                                shortcutRow(shortcut)
                            }
                        }

                        // Add new form
                        if isAddingNew {
                            shortcutForm(isNew: true, shortcutId: nil)
                        }
                    }

                    // Add button (when not already adding)
                    if !isAddingNew && editingShortcutId == nil {
                        Button(action: {
                            formName = ""
                            formType = .prompt
                            formValue = ""
                            isAddingNew = true
                            WindowController.passThrough = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Add Action")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.caiPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.caiPrimary.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }

            Spacer(minLength: 0)

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack(spacing: 12) {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 28))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text("No custom actions yet")
                .font(.system(size: 13))
                .foregroundColor(.caiTextSecondary)
            Text("Create custom actions for prompts you use often\nor URLs you search frequently")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }

    // MARK: - Shortcut Row

    private func shortcutRow(_ shortcut: CaiShortcut) -> some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                Image(systemName: shortcut.type.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
            }

            // Name + value preview
            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(shortcut.value)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Share as extension
            Button(action: {
                shareShortcutAsExtension(shortcut)
            }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                    .padding(4)
            }
            .buttonStyle(.plain)

            // Edit button
            Button(action: {
                formName = shortcut.name
                formType = shortcut.type
                formValue = shortcut.value
                editingShortcutId = shortcut.id
                WindowController.passThrough = true
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                    .padding(4)
            }
            .buttonStyle(.plain)

            // Delete button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    settings.shortcuts.removeAll { $0.id == shortcut.id }
                }
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Shortcut Form (Add / Edit)

    private func shortcutForm(isNew: Bool, shortcutId: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                TextField("e.g. Email Reply, Reddit", text: $formName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            // Type picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Type")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                Picker("", selection: $formType) {
                    ForEach(CaiShortcut.ShortcutType.allCases, id: \.self) { type in
                        Text(type.label).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Value field
            VStack(alignment: .leading, spacing: 4) {
                let fieldLabel: String = {
                    switch formType {
                    case .prompt: return "Prompt"
                    case .url: return "URL Template"
                    case .shell: return "Shell Command"
                    }
                }()
                Text(fieldLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                let useMonospaced = formType == .url || formType == .shell
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $formValue)
                        .font(.system(size: 12, design: useMonospaced ? .monospaced : .default))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                    if formValue.isEmpty {
                        Text(formType.placeholder)
                            .font(.system(size: 12, design: useMonospaced ? .monospaced : .default))
                            .foregroundColor(.caiTextSecondary.opacity(0.4))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 60, maxHeight: 140)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
                if formType == .url {
                    Text("Use %s where clipboard text should be inserted")
                        .font(.system(size: 10))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                } else if formType == .shell {
                    Text("Use {{result}} where clipboard text should be inserted. Text is also passed via stdin.")
                        .font(.system(size: 10))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                }

                // Code execution warning
                if formType == .shell {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text("This action will execute code on your machine. Only use commands you understand and trust.")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(6)
                }
            }

            // Save / Cancel buttons
            HStack(spacing: 8) {
                Button("Cancel") {
                    cancelForm()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)

                Spacer()

                Button(action: {
                    saveForm(isNew: isNew, shortcutId: shortcutId)
                }) {
                    Text(isNew ? "Add" : "Save")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(formName.isEmpty || formValue.isEmpty
                                      ? Color.caiPrimary.opacity(0.4)
                                      : Color.caiPrimary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(formName.isEmpty || formValue.isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.caiSurface.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.caiDivider.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
    }

    // MARK: - Form Helpers

    private func saveForm(isNew: Bool, shortcutId: UUID?) {
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = formValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedValue.isEmpty else { return }

        if isNew {
            let shortcut = CaiShortcut(name: trimmedName, type: formType, value: trimmedValue)
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.shortcuts.append(shortcut)
            }
        } else if let id = shortcutId,
                  let index = settings.shortcuts.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.shortcuts[index].name = trimmedName
                settings.shortcuts[index].type = formType
                settings.shortcuts[index].value = trimmedValue
            }
        }

        cancelForm()
    }

    private func cancelForm() {
        WindowController.passThrough = false
        withAnimation(.easeInOut(duration: 0.15)) {
            isAddingNew = false
            editingShortcutId = nil
        }
        formName = ""
        formType = .prompt
        formValue = ""
    }

    // MARK: - Share as Extension

    private func shareShortcutAsExtension(_ shortcut: CaiShortcut) {
        let slug = shortcut.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        var yaml = """
            # cai-extension
            name: \(shortcut.name)
            description: \(shortcut.name)
            author: your-github-username
            version: "1.0"
            tags: []
            icon: \(shortcut.type.icon)
            type: \(shortcut.type.rawValue)\n
            """

        switch shortcut.type {
        case .prompt:
            let indented = shortcut.value.components(separatedBy: "\n")
                .map { "  \($0)" }.joined(separator: "\n")
            yaml += "prompt: |\n\(indented)\n"
        case .url:
            yaml += "url: \"\(shortcut.value)\"\n"
        case .shell:
            let indented = shortcut.value.components(separatedBy: "\n")
                .map { "  \($0)" }.joined(separator: "\n")
            yaml += "command: |\n\(indented)\n"
        }

        SystemActions.copyToClipboard(yaml)

        if let url = URL(string: "https://github.com/clipboard-ai/cai-extensions") {
            NSWorkspace.shared.open(url)
        }

        NotificationCenter.default.post(
            name: .caiShowToast,
            object: nil,
            userInfo: ["message": "Extension YAML copied"]
        )
    }
}
