import CaiActionCore
import SwiftUI

/// A row's one-line answer to "what does this action actually do".
///
/// The recall surface. This feature started from a founder forgetting what one
/// of his own actions did weeks later, and the row subtitle it replaced was the
/// raw payload truncated middle — `curl -s https://api.git…jq -r '.[].title'`,
/// which answers nothing. These are the same chips the approval sheet draws,
/// from the same pure detector, so the thing you approved and the thing you
/// revisit describe themselves identically.
///
/// One line, never wrapped: this sits in a 42/56pt row. Eliding is therefore
/// unavoidable and is made honest by `Capability.sortOrder`, which puts every
/// open-ended capability first — so "Runs a shell command" is never the chip
/// that loses its slot, and a compact row can be trusted not to have hidden the
/// unbounded part. The "+N" says how much was left out; the full set is on the
/// approval sheet and in the editor.
struct CapabilitySubtitle: View {

    let capabilities: [Capability]
    let engine: ActionReviewPresentation.AIEngine
    /// Capabilities this surface already states another way, so the chip would
    /// be the same fact twice in one row.
    var excluding: (Capability) -> Bool = { _ in false }

    var body: some View {
        let compact = ActionReviewPresentation.compactCapabilities(
            capabilities, excluding: excluding
        )
        let chips = ActionReviewPresentation.chips(for: compact.shown, engine: engine)

        HStack(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                if index > 0 {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary.opacity(0.4))
                }

                HStack(spacing: 3) {
                    Text(chip.label)
                    // A secret name keeps the identifier treatment here too,
                    // monospaced at this row's own 11pt.
                    if let identifier = chip.identifier {
                        Text(identifier)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }

            if let overflow = ActionReviewPresentation.compactOverflowLabel(hidden: compact.hidden) {
                Text(overflow)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// VoiceOver gets the whole set, not the compact three: the elision is a
    /// width constraint, and a screen reader has no width problem.
    private var spokenLabel: String {
        let labels = ActionReviewPresentation.chips(for: capabilities, engine: engine).map { chip in
            chip.identifier.map { "\(chip.label) \($0)" } ?? chip.label
        }
        guard !labels.isEmpty else { return "" }
        var spoken = labels.joined(separator: ", ")
        if let tail = ActionReviewPresentation.capabilityTail(for: capabilities) {
            spoken += ", " + tail
        }
        return spoken
    }
}
