import SwiftUI

/// Shows the result of an action (LLM response, pretty-printed JSON, etc.)
/// inside the floating window, replacing the action list.
/// Press Enter to copy and dismiss (toast shows confirmation).
/// Cmd+1..9 sends result to an output destination.
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

    @State private var result: String = ""
    @State private var isLoading: Bool = true
    @State private var error: String?

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
                            .foregroundColor(.orange)
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
            .frame(maxHeight: 240)

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

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
                if !isLoading && error == nil {
                    KeyboardHint(key: "↵", label: "Copy")
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
                withAnimation {
                    self.error = error.localizedDescription
                    isLoading = false
                }
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
