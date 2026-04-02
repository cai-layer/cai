import SwiftUI

/// Shows the result of an action (LLM response, pretty-printed JSON, etc.)
/// inside the floating window, replacing the action list.
/// Press Enter to copy and dismiss (toast shows confirmation).
/// Cmd+1..9 sends result to an output destination.
/// Tab opens inline follow-up input (LLM actions only).
/// ESC returns to the action list (handled by parent).
struct ResultView: View {
    let title: String
    let onBack: () -> Void
    /// Called when the result is ready so the parent can copy on Enter.
    var onResult: ((String) -> Void)?
    /// Output destinations shown as chips after the result.
    var destinations: [OutputDestination] = []
    /// Called when the user selects a destination.
    var onSelectDestination: ((OutputDestination, String) -> Void)?
    /// Whether follow-up is available for this result (true for LLM actions).
    var isFollowUpEnabled: Bool = false
    /// Binding to parent's state controlling follow-up input visibility.
    @Binding var showFollowUpInput: Bool
    /// Binding to parent's follow-up text.
    @Binding var followUpText: String

    @State private var result: String = ""
    @State private var isLoading: Bool = true
    @State private var error: String?

    @FocusState private var isFollowUpFocused: Bool

    /// Async generator that produces the result string.
    let generator: () async throws -> String

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.caiDivider)

            // Content area
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
                            .foregroundColor(.caiError)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.caiTextSecondary)
                            .multilineTextAlignment(.center)
                        Text("Check Settings \u{2192} Model Provider")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Error: \(error)")
                } else {
                    Text(markdownAttributedString(from: result))
                        .font(.system(size: 13))
                        .foregroundColor(.caiTextPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(maxHeight: showFollowUpInput ? 160 : 240)

            Spacer(minLength: 0)

            // Destination chips — shown after result loads
            if !isLoading && error == nil && !destinations.isEmpty {
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

            // Follow-up input — shown when user presses Tab on a result
            if showFollowUpInput {
                Divider()
                    .background(Color.caiDivider)

                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.caiSurface.opacity(0.6))

                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)

                        TextEditor(text: $followUpText)
                            .font(.system(size: 13))
                            .foregroundColor(.caiTextPrimary)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(8)
                            .focused($isFollowUpFocused)

                        // Placeholder (TextEditor has no native placeholder)
                        if followUpText.isEmpty {
                            Text("Ask a follow-up question...")
                                .font(.system(size: 13))
                                .foregroundColor(.caiTextSecondary.opacity(0.5))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 60)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
                if !isLoading && error == nil {
                    if showFollowUpInput {
                        KeyboardHint(key: "\u{2318}\u{21B5}", label: "Submit")
                    } else {
                        if isFollowUpEnabled {
                            KeyboardHint(key: "\u{21E5}", label: "Follow up")
                        }
                        KeyboardHint(key: "\u{21B5}", label: "Copy")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task {
            do {
                let output = try await generator()
                withAnimation(.easeOut(duration: 0.2)) {
                    result = output
                    isLoading = false
                }
                onResult?(output)
            } catch {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
        .onChange(of: showFollowUpInput) { showing in
            if showing {
                WindowController.passThrough = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isFollowUpFocused = true
                }
            } else {
                WindowController.passThrough = false
                isFollowUpFocused = false
            }
        }
    }

    /// Parses a markdown string into an AttributedString for rich rendering.
    /// Falls back to plain text if markdown parsing fails.
    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            var attributed = try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            // Ensure our default font and color are applied
            attributed.font = .system(size: 13)
            attributed.foregroundColor = .caiTextPrimary
            return attributed
        } catch {
            return AttributedString(text)
        }
    }
}
