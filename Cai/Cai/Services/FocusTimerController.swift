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
        let next = FocusTimerMachine.next(state, event, now: now, config: config)
        // Ticks that change nothing still redraw: the countdown moved.
        state = next
        updateTicker()
        NotificationCenter.default.post(name: .caiFocusTimerChanged, object: nil)
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
