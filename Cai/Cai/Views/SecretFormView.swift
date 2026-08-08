import CaiActionCore
import SwiftUI

/// Add or replace one secret. Write-only from the first keystroke: the value
/// field is a `SecureField` with no reveal — tokens are pasted, not typed, and
/// the error-catching job belongs to the live character count.
struct SecretFormView: View {
    /// Non-nil = Replace Value… for this name; the name field is locked.
    let replacingName: String?
    let existingNames: Set<String>
    /// `(name, replacedExisting)` on success.
    let onSaved: (String, Bool) -> Void
    let onCancel: () -> Void
    let onImportInstead: () -> Void

    @State private var name: String = ""
    @State private var value: String = ""
    @State private var strippedLineBreaks = false
    @State private var saveFailure: String?
    @FocusState private var focus: Field?
    private enum Field { case name, value }

    init(
        replacingName: String?,
        existingNames: Set<String>,
        onSaved: @escaping (String, Bool) -> Void,
        onCancel: @escaping () -> Void,
        onImportInstead: @escaping () -> Void
    ) {
        self.replacingName = replacingName
        self.existingNames = existingNames
        self.onSaved = onSaved
        self.onCancel = onCancel
        self.onImportInstead = onImportInstead
        _name = State(initialValue: replacingName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameSection
            valueSection

            if let saveFailure {
                Text(saveFailure)
                    .font(.system(size: 11))
                    .foregroundColor(.caiError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons

            if replacingName == nil {
                Button(action: onImportInstead) {
                    Text("Import from your shell instead…")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focus = replacingName == nil ? .name : .value }
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)

            HStack(spacing: 2) {
                // The reference syntax teaches itself at naming time — the
                // destination form's {{ }} grammar.
                Text("{{secrets.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.caiTextSecondary.opacity(0.5))
                TextField("NOTION_API_TOKEN", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .focused($focus, equals: .name)
                    .disabled(replacingName != nil)
                    .accessibilityLabel("Secret name")
                Text("}}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.caiTextSecondary.opacity(0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focus == .name ? Color.caiPrimary.opacity(0.5) : Color.caiDivider.opacity(0.5),
                        lineWidth: focus == .name ? 1 : 0.5
                    )
            )

            if let problem = nameProblem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundColor(.caiError)
                    .accessibilityLabel(problem)
            } else if collides {
                Text("\(name) already exists. Saving replaces its value.")
                    .font(.system(size: 11))
                    .foregroundColor(.caiError)
            }
        }
    }

    /// Live validation, only once the user has typed something — an empty
    /// field is not yet a mistake.
    private var nameProblem: String? {
        guard replacingName == nil, !name.isEmpty else { return nil }
        return SecretReference.nameRejection(name)
    }

    private var collides: Bool {
        replacingName == nil && existingNames.contains(name)
    }

    // MARK: - Value

    private var valueSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Value")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)

            SecureField("Paste the token", text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($focus, equals: .value)
                .accessibilityLabel("Secret value, hidden")
                .onChange(of: value) { _, new in
                    if new.contains(where: \.isNewline) {
                        value = new.filter { !$0.isNewline }
                        strippedLineBreaks = true
                    }
                }
                .onSubmit { save() }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            focus == .value ? Color.caiPrimary.opacity(0.5) : Color.caiDivider.opacity(0.5),
                            lineWidth: focus == .value ? 1 : 0.5
                        )
                )

            HStack(spacing: 8) {
                Text("\(value.count) characters")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .monospacedDigit()
                    .accessibilityLabel("\(value.count) characters entered")
                if strippedLineBreaks {
                    Text("Line breaks removed")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Save

    private var canSave: Bool {
        let effective = replacingName ?? name
        return SecretReference.isValidName(effective)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)

            Button(action: save) {
                Text(saveLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.caiPrimary.opacity(canSave ? 1 : 0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
    }

    private var saveLabel: String {
        (replacingName != nil || collides) ? "Replace" : "Save"
    }

    private func save() {
        guard canSave else { return }
        let effective = replacingName ?? name
        let replaced = replacingName != nil || collides

        switch SecretStore.save(value, name: effective) {
        case .saved, .replaced:
            onSaved(effective, replaced)
        case .invalidName(let why):
            saveFailure = why
        case .keychainFailed(let status):
            saveFailure = "Couldn't save to the Keychain (error \(status))."
        }
    }
}
