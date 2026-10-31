import AppKit

extension Notification.Name {
    /// The focus timer changed phase, paused, or ticked. The status item redraws.
    static let caiFocusTimerChanged = Notification.Name("caiFocusTimerChanged")
}

/// Runs the focus timer: feeds events through `FocusTimerMachine` and ticks
/// once a second while a phase is running.
@MainActor
final class FocusTimerController {
    static let shared = FocusTimerController()

    private(set) var state = FocusTimerState.idle
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
    }

    var config: FocusTimerConfig {
        let settings = CaiSettings.shared
        return FocusTimerConfig(
            focusMinutes: settings.focusMinutes,
            shortBreakMinutes: settings.shortBreakMinutes,
            longBreakMinutes: settings.longBreakMinutes
        )
    }

    func send(_ event: FocusTimerEvent, now: Date = Date()) {
        let previous = state
        let next = FocusTimerMachine.next(state, event, now: now, config: config)
        // Ticks that change nothing still redraw: the countdown moved.
        state = next
        announceBreak(from: previous, to: next, event: event)
        chimeIfPhaseRanOut(from: previous, event: event)
        updateTicker()
        NotificationCenter.default.post(name: .caiFocusTimerChanged, object: nil)
    }

    /// A focus session that ran out on its own starts a break with a
    /// notification. A skip doesn't: the user just chose the break. Leaving
    /// a break clears the banner so a stale one can't be snoozed later.
    private func announceBreak(from previous: FocusTimerState, to next: FocusTimerState, event: FocusTimerEvent) {
        if event == .tick, previous.phase == .focus, let phase = next.phase, phase.isBreak {
            let minutes = phase == .longBreak ? config.longBreakMinutes : config.shortBreakMinutes
            FocusBreakNotifier.shared.postBreak(phase, minutes: minutes)
        } else if previous.phase?.isBreak == true, next.phase?.isBreak != true {
            FocusBreakNotifier.shared.removeBreakNotification()
        }
    }

    /// A chime when a phase runs out on its own, like Flow: Glass when focus
    /// ends, Hero when a break ends. Played by Cai rather than by the
    /// notification, so it sounds even with notifications off, and only once.
    /// Skips, restarts and Stop Timer are the user's own doing and stay quiet.
    private func chimeIfPhaseRanOut(from previous: FocusTimerState, event: FocusTimerEvent) {
        guard event == .tick, let ended = previous.phase, state.phase != ended,
              CaiSettings.shared.focusTimerPlaysSound else { return }
        NSSound(named: ended == .focus ? "Glass" : "Hero")?.play()
    }

    private func updateTicker() {
        guard state.isRunning else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
        // .common so the countdown keeps moving while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}
