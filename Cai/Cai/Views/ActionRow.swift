import SwiftUI

struct ActionRow: View {
    let action: ActionItem
    let isSelected: Bool
    /// Which model engine the AI chip names. Passed in rather than read from
    /// `CaiSettings.shared`, so the row stays a function of its inputs.
    let engine: ActionReviewPresentation.AIEngine

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.caiPrimary.opacity(0.15) : Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                actionIcon(name: action.icon, isSelected: isSelected)
            }

            // Title + subtitle
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                // Custom actions describe themselves with the same capability
                // chips the approval sheet draws, so what you approved and what
                // you pick weeks later read identically. Built-ins keep their
                // hand-written subtitles: "Create a concise summary" is already
                // a plain statement of purpose and beats a chip row.
                if !action.capabilities.isEmpty {
                    CapabilitySubtitle(capabilities: action.capabilities, engine: engine)
                } else if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Keyboard shortcut badge
            if action.shortcut <= 9 {
                HStack(spacing: 2) {
                    Text("\u{2318}")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(action.shortcut)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.caiSurface.opacity(0.5))
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.caiPrimarySubtle : Color.clear)
        )
        .contentShape(Rectangle())
        // The raw payload is still one hover away for a custom action, where
        // the chips replaced it as the subtitle. Only where there is one to
        // show: an empty `.help("")` on every built-in row is a tooltip that
        // flashes nothing.
        .modifier(OptionalHelp(text: payloadTooltip))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The raw payload, reachable on hover for a custom action where the chips
    /// replaced it as the subtitle. Nil for built-ins, whose subtitle is already
    /// on screen.
    private var payloadTooltip: String? {
        action.capabilities.isEmpty ? nil : action.subtitle
    }

    /// What VoiceOver reads for the row.
    ///
    /// For a custom action this must speak the capabilities, not `subtitle`:
    /// `subtitle` is the raw payload, which the chips deliberately replaced
    /// because `curl -s https://api.git…` answers nothing. Reading it aloud
    /// while sighted users get "Sends to hooks.slack.com" would hand the screen
    /// reader strictly worse information than the screen — the inverse of the
    /// approval sheet, where VoiceOver gets Cai's prose line as well as the
    /// chips.
    private var accessibilityLabel: String {
        let description: String
        if !action.capabilities.isEmpty {
            description = CapabilitySubtitle(
                capabilities: action.capabilities, engine: engine
            ).spokenLabel
        } else {
            description = action.subtitle ?? ""
        }
        let middle = description.isEmpty ? "" : ", \(description)"
        return "\(action.title)\(middle), Command \(action.shortcut)"
    }

    @ViewBuilder
    private func actionIcon(name: String, isSelected: Bool) -> some View {
        let color: Color = isSelected ? .caiPrimary : .caiTextSecondary
        switch name {
        case "github.logo":
            GitHubIcon(color: color)
                .frame(width: 14, height: 14)
        case "linear.logo":
            LinearIcon(color: color)
                .frame(width: 14, height: 14)
        default:
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color)
        }
    }
}
