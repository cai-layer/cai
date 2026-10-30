import Foundation

/// A Pomodoro-style focus timer on the menu bar icon: focus, then a short
/// break, and a long break after every 4th focus session.
enum FocusPhase: Equatable {
    case focus, shortBreak, longBreak

    /// Used in the menu header and the restart / skip item titles.
    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long Break"
        }
    }

    var isBreak: Bool { self != .focus }
}

/// Phase lengths, read from Settings when a phase starts, so an edit made
/// mid-phase applies from the next one.
struct FocusTimerConfig: Equatable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 30
    static let sessionsPerLongBreak = 4

    func seconds(for phase: FocusPhase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak: return TimeInterval(longBreakMinutes * 60)
        }
    }
}

struct FocusTimerState: Equatable {
    enum Clock: Equatable {
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    /// Nil when idle: waiting for "Start Focus".
    var phase: FocusPhase?
    var clock: Clock?
    /// Focus sessions finished since the last long break (0...3).
    var completedSessions = 0

    static let idle = FocusTimerState()

    var isRunning: Bool {
        if case .running = clock { return true }
        return false
    }

    func remaining(now: Date) -> TimeInterval? {
        switch clock {
        case .running(let endsAt): return max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining): return remaining
        case nil: return nil
        }
    }

    /// The countdown next to the logo, e.g. "24:13" or "0:42". Nil when idle.
    func countdown(now: Date) -> String? {
        remaining(now: now).map(Self.format)
    }

    /// The grey status row at the top of the timer section.
    func menuHeader(now: Date, config: FocusTimerConfig) -> String {
        guard let phase, let left = remaining(now: now) else {
            return "Focus: \(Self.format(config.seconds(for: .focus)))"
        }
        if case .paused = clock { return "\(phase.title): Paused at \(Self.format(left))" }
        return "\(phase.title): \(Self.format(left))"
    }

    /// Whole seconds round up, so the display never reads 0:00 while time is left.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum FocusTimerEvent: Equatable {
    case start, pause, resume, restart, skip
    /// The clock moved on (a timer tick, or waking from sleep).
    case tick
    /// The timer was turned off in Settings.
    case disable
}

/// Every transition of the timer, pure so it can be table-tested
/// (see `FocusTimerTests`).
enum FocusTimerMachine {
    static func next(_ state: FocusTimerState, _ event: FocusTimerEvent, now: Date, config: FocusTimerConfig) -> FocusTimerState {
        var s = state
        switch event {
        case .disable:
            return .idle

        case .start:
            guard s.phase == nil else { return s }
            return run(.focus, from: s, now: now, config: config)

        case .pause:
            guard case .running(let endsAt) = s.clock else { return s }
            s.clock = .paused(remaining: max(0, endsAt.timeIntervalSince(now)))
            return s

        case .resume:
            guard case .paused(let remaining) = s.clock else { return s }
            s.clock = .running(endsAt: now.addingTimeInterval(remaining))
            return s

        case .restart:
            guard let phase = s.phase else { return s }
            return run(phase, from: s, now: now, config: config)

        case .skip:
            return phaseEnded(s, now: now, config: config)

        case .tick:
            guard case .running(let endsAt) = s.clock, now >= endsAt else { return s }
            // One phase per tick: a Mac asleep through a focus end and its
            // whole break wakes into that break, starting now, not past it.
            return phaseEnded(s, now: now, config: config)
        }
    }

    private static func phaseEnded(_ state: FocusTimerState, now: Date, config: FocusTimerConfig) -> FocusTimerState {
        switch state.phase {
        case nil:
            return state
        case .focus:
            var s = state
            s.completedSessions += 1
            if s.completedSessions >= FocusTimerConfig.sessionsPerLongBreak {
                s.completedSessions = 0
                return run(.longBreak, from: s, now: now, config: config)
            }
            return run(.shortBreak, from: s, now: now, config: config)
        case .shortBreak, .longBreak:
            // After a break, focus waits for the user rather than starting on its own.
            var s = state
            s.phase = nil
            s.clock = nil
            return s
        }
    }

    private static func run(_ phase: FocusPhase, from state: FocusTimerState, now: Date, config: FocusTimerConfig) -> FocusTimerState {
        var s = state
        s.phase = phase
        s.clock = .running(endsAt: now.addingTimeInterval(config.seconds(for: phase)))
        return s
    }
}
