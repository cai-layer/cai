import SwiftUI

/// Shared state for CustomPromptView so the parent can persist the prompt text
/// across view recreations (e.g., window resume cache).
class CustomPromptState: ObservableObject {
    @Published var promptText: String = ""

    func reset() {
        promptText = ""
    }
}

/// Input-only view for typing a custom prompt.
/// On submit (Cmd+Enter), calls `onSubmit` with the instruction text.
/// The parent (ActionListWindow) handles the LLM call and shows ResultView.
struct CustomPromptView: View {
    let clipboardText: String
    let sourceApp: String?
    @ObservedObject var state: CustomPromptState
    let onSubmit: (String) -> Void

    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Custom Action")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.caiTextPrimary)

                    if clipboardText.isEmpty {
                        Text("Ask anything")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary)
                    } else {
                        Text(clipboardText)
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.caiDivider)

            // Input content
            VStack(spacing: 12) {
                Text(clipboardText.isEmpty ? "What would you like to ask?" : "What would you like to do with this content?")
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Multiline TextEditor with placeholder
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.caiSurface.opacity(0.6))

                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)

                    TextEditor(text: $state.promptText)
                        .font(.system(size: 13))
                        .foregroundColor(.caiTextPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(8)
                        .focused($isPromptFocused)

                    // Placeholder (TextEditor has no native placeholder)
                    if state.promptText.isEmpty {
                        Text(clipboardText.isEmpty
                            ? "e.g. What's the population of Paris?, Calculate 15% tip on $85..."
                            : "e.g. Rewrite formally, Extract key points, Convert to bullet list...")
                            .font(.system(size: 13))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 80)
            }
            .padding(16)

            Spacer(minLength: 0)

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack(spacing: 12) {
                KeyboardHint(key: "Esc", label: "Back")
                KeyboardHint(key: "⌘↵", label: "Submit")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear {
            WindowController.passThrough = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPromptFocused = true
            }
        }
        .onDisappear {
            WindowController.passThrough = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiCmdEnterPressed)) { _ in
            let trimmed = state.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onSubmit(trimmed)
        }
    }
}
