import SwiftUI

/// Popover content for editing the directive of a `.inlineLLM` chain step.
///
/// Anchored under the chip row by SwiftUI `.popover` (one per editor, not
/// per chip — per-chip popovers were creating N NSPopover instances and
/// the first open was noticeably slow).
///
/// **Design:**
/// - Multi-line `TextField(axis: .vertical)` (NOT `TextEditor`) — the
///   former doesn't intercept ⌘⏎ at the responder chain, so the SwiftUI
///   `keyboardShortcut(.return, modifiers: .command)` on Done actually
///   fires. With TextEditor, ⌘⏎ was being eaten by NSTextView before
///   SwiftUI saw it.
/// - Footer with Cancel + Done. ⌘⏎ commits, Esc cancels.
/// - Empty directive on commit → parent removes the chip (handled in the
///   chip editor's `commitLLMEdit`).
struct LLMEditPopover: View {
    @Binding var directive: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiPrimary)
                Text("LLM directive")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)
                Spacer()
            }

            // `MultilineTextEditor` (NSTextView wrapper) — gives us a real
            // multi-line editor where plain Return inserts a newline AND
            // ⌘⏎ forwards to the Done button's keyboard shortcut.
            // `TextField(axis: .vertical)` swallows Return on macOS;
            // `TextEditor` swallows ⌘⏎. We need both.
            // Popover uses larger min/max (3-6 lines) since it's a
            // dedicated editor not competing for form real-estate.
            // ⌘⏎ commits / Esc cancels via direct callbacks (more reliable
            // than SwiftUI's keyboardShortcut chain through NSTextView).
            let editor = MultilineTextEditor(
                text: $directive,
                placeholder: "e.g. summarize as 3 bullets, no preamble, plain text",
                minLines: 3,
                maxLines: 6,
                autoFocus: true,
                onCommit: onCommit,
                onCancel: onCancel
            )
            editor
                .frame(width: 320)
                .formFieldShell()

            Text("Applied to the chain pipe value.")
                .font(.system(size: 9))
                .foregroundColor(.caiTextSecondary.opacity(0.6))

            HStack(spacing: 8) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                Spacer()
                Button(action: onCommit) {
                    Text("Done")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? Color.caiPrimaryFill.opacity(0.4)
                                      : Color.caiPrimaryFill)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }
}
