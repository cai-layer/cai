import SwiftUI

/// Shared state for CustomPromptView so the parent can query its phase
/// and route keyboard events correctly.
class CustomPromptState: ObservableObject {
    @Published var phase: CustomPromptPhase = .input
    /// Holds the LLM result so the parent can copy it on Enter.
    @Published var resultText: String = ""

    func reset() {
        phase = .input
        resultText = ""
    }
}

enum CustomPromptPhase {
    case input, result
}

/// Inline view for typing a custom prompt to send to the local LLM.
/// Two phases: (1) text input, (2) result display.
/// Keyboard events are routed by the parent (ActionListWindow).
struct CustomPromptView: View {
    let clipboardText: String
    let sourceApp: String?
    @ObservedObject var state: CustomPromptState
    /// Output destinations shown in result phase.
    var destinations: [OutputDestination] = []
    /// Called when user selects a destination.
    var onSelectDestination: ((OutputDestination, String) -> Void)?

    @State private var prompt: String = ""
    @State private var result: String = ""
    @State private var isLoading: Bool = false
    @State private var error: String?

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

            Divider()
                .background(Color.caiDivider)

            // Content
            if state.phase == .input {
                inputContent
            } else {
                resultContent
            }

            Spacer(minLength: 0)

            // Destination chips — shown in result phase after result loads
            if state.phase == .result && !isLoading && error == nil && !destinations.isEmpty {
                Divider()
                    .background(Color.caiDivider)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Send to")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))

                        ForEach(Array(destinations.enumerated()), id: \.element.id) { index, dest in
                            DestinationChip(
                                destination: dest,
                                shortcut: index + 1,
                                isSelected: false,
                                action: {
                                    onSelectDestination?(dest, result)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack(spacing: 12) {
                KeyboardHint(key: "Esc", label: "Back")
                if state.phase == .input {
                    KeyboardHint(key: "⌘↵", label: "Submit")
                } else if !isLoading && error == nil {
                    KeyboardHint(key: "↵", label: "Copy")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onChange(of: state.phase) { newPhase in
            WindowController.passThrough = (newPhase == .input)
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiCmdEnterPressed)) { _ in
            if state.phase == .input {
                submitPrompt()
            }
        }
    }

    // MARK: - Input Phase

    private var inputContent: some View {
        VStack(spacing: 12) {
            Text("What would you like to do with this content?")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Multiline TextEditor with placeholder
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.caiSurface.opacity(0.6))

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)

                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .foregroundColor(.caiTextPrimary)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(8)
                    .focused($isPromptFocused)

                // Placeholder (TextEditor has no native placeholder)
                if prompt.isEmpty {
                    Text("e.g. Rewrite formally, Extract key points, Convert to bullet list...")
                        .font(.system(size: 13))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 80)
        }
        .padding(16)
        .onAppear {
            WindowController.passThrough = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPromptFocused = true
            }
        }
        .onDisappear {
            WindowController.passThrough = false
        }
    }

    // MARK: - Result Phase

    private var resultContent: some View {
        ScrollView {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else if let error = error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else {
                Text(result)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.caiTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(maxHeight: 240)
    }

    // MARK: - Private

    private func submitPrompt() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            state.phase = .result
            isLoading = true
            error = nil
        }

        let textToProcess = clipboardText
        Task {
            do {
                let output = try await LLMService.shared.customAction(textToProcess, instruction: trimmed, appContext: sourceApp)

                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) {
                        result = output
                        isLoading = false
                    }
                    state.resultText = output
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.error = error.localizedDescription
                        isLoading = false
                    }
                }
            }
        }
    }

}
