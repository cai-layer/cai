import SwiftUI

/// The small panel a click on the focus countdown opens: start the cycle
/// over, pause or play, skip, and the 4 cycle dots. Every control also exists
/// as a plain item in the full menu (right-click), which stays the keyboard
/// and VoiceOver path.
struct FocusTimerPill: View {
    let send: (FocusTimerEvent) -> Void
    @State private var state: FocusTimerState

    init(state: FocusTimerState, send: @escaping (FocusTimerEvent) -> Void) {
        self.send = send
        _state = State(initialValue: state)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                // At a fresh start the next ↺ stops the timer, so it says so.
                if state.isFreshCycle(now: Date(), config: FocusTimerController.shared.config) {
                    control("stop.fill", label: "Stop", .restartCycle)
                } else {
                    control("arrow.counterclockwise", label: "Start Over", .restartCycle)
                }
                control(state.isRunning ? "pause.fill" : "play.fill", label: state.isRunning ? "Pause" : "Play",
                        state.isRunning ? .pause : .resume)
                control("forward.end.fill", label: skipLabel, .skip)
            }
            cycleDots
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 8, trailing: 6))
        .onReceive(NotificationCenter.default.publisher(for: .caiFocusTimerChanged)) { _ in
            state = FocusTimerController.shared.state
        }
    }

    private var skipLabel: String {
        guard let phase = state.phase, phase.isBreak else { return "Skip to Break" }
        return "Skip \(phase.title)"
    }

    /// Done solid, current ring, upcoming faint; all the same size, so the
    /// state reads from fill alone (DESIGN.md: never resize to show state).
    private var cycleDots: some View {
        let dots = state.cycleDots
        return HStack(spacing: 7) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                switch dot {
                case .done: Circle().fill(Color.caiTextPrimary)
                case .current: Circle().strokeBorder(Color.caiTextPrimary, lineWidth: 1.5)
                case .upcoming: Circle().fill(Color.caiTextPrimary.opacity(0.22))
                }
            }
            .frame(width: 7, height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dots.filter { $0 == .done }.count) of \(dots.count) focus sessions done")
    }

    private func control(_ symbol: String, label: String, _ event: FocusTimerEvent) -> some View {
        Button { send(event) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.caiTextPrimary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
