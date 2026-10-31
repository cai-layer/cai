import XCTest
@testable import Cai

/// The focus timer's state machine.
final class FocusTimerTests: XCTestCase {

    // MARK: - Transitions (P1)

    /// P1: state machine. A wrong row skips a break, double-counts a session,
    /// or resumes with the wrong time left, and the user stops trusting it.
    func testTransitions() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let config = FocusTimerConfig(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 30)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        func state(_ phase: FocusPhase?, _ clock: FocusTimerState.Clock?, done: Int = 0) -> FocusTimerState {
            FocusTimerState(phase: phase, clock: clock, completedSessions: done)
        }
        let focusRunning = state(.focus, .running(endsAt: at(1500)))

        // (name, from, event, now, expected)
        let cases: [(String, FocusTimerState, FocusTimerEvent, Date, FocusTimerState)] = [
            ("start from idle", .idle, .start, t0, focusRunning),
            ("start while running is ignored", focusRunning, .start, at(60), focusRunning),
            ("tick before the end changes nothing", focusRunning, .tick, at(1499), focusRunning),
            ("focus ends: short break, session counted",
             focusRunning, .tick, at(1500), state(.shortBreak, .running(endsAt: at(1800)), done: 1)),
            ("4th focus ends: long break, counter reset",
             state(.focus, .running(endsAt: at(1500)), done: 3), .tick, at(1500),
             state(.longBreak, .running(endsAt: at(3300)), done: 0)),
            ("break ends: idle, waits for Start Focus, count kept",
             state(.shortBreak, .running(endsAt: at(300)), done: 2), .tick, at(300), state(nil, nil, done: 2)),
            ("pause keeps the time left", focusRunning, .pause, at(500), state(.focus, .paused(remaining: 1000))),
            ("resume restarts the clock from now",
             state(.focus, .paused(remaining: 1000)), .resume, at(9000), state(.focus, .running(endsAt: at(10000)))),
            ("paused does not end on a tick",
             state(.focus, .paused(remaining: 10)), .tick, at(99_999), state(.focus, .paused(remaining: 10))),
            ("restart keeps the phase", state(.shortBreak, .running(endsAt: at(100)), done: 1), .restart, at(50),
             state(.shortBreak, .running(endsAt: at(350)), done: 1)),
            ("skip in focus counts the session",
             focusRunning, .skip, at(10), state(.shortBreak, .running(endsAt: at(310)), done: 1)),
            ("skip a break: the next focus starts, never idle",
             state(.shortBreak, .running(endsAt: at(300)), done: 2), .skip, at(10), state(.focus, .running(endsAt: at(1510)), done: 2)),
            ("skip the long break: focus 1 of a new cycle",
             state(.longBreak, .paused(remaining: 600)), .skip, at(10), state(.focus, .running(endsAt: at(1510)), done: 0)),
            ("asleep through focus and its break: one phase, starting now",
             focusRunning, .tick, at(5000), state(.shortBreak, .running(endsAt: at(5300)), done: 1)),
            ("snooze a short break: 5 more focus minutes, session un-counted",
             state(.shortBreak, .running(endsAt: at(300)), done: 1), .snooze, at(10),
             state(.focus, .running(endsAt: at(310)), done: 0)),
            ("snooze a long break: ending focus again leads to the long break",
             state(.longBreak, .running(endsAt: at(1800)), done: 0), .snooze, at(10),
             state(.focus, .running(endsAt: at(310)), done: 3)),
            ("snooze outside a break is ignored", focusRunning, .snooze, at(10), focusRunning),
            ("restart cycle from session 3 focus: session 1, focus, full length",
             state(.focus, .running(endsAt: at(100)), done: 2), .restartCycle, at(50), state(.focus, .running(endsAt: at(1550)), done: 0)),
            ("restart cycle from idle starts focus", .idle, .restartCycle, t0, focusRunning),
            ("stop clears the session and the cycle count",
             state(.focus, .running(endsAt: at(1500)), done: 2), .stop, at(10), .idle),
            ("stop a paused break", state(.longBreak, .paused(remaining: 600)), .stop, at(10), .idle),
            ("turned off in Settings mid-phase", state(.focus, .paused(remaining: 5), done: 3), .disable, at(0), .idle),
        ]
        for (name, from, event, now, expected) in cases {
            XCTAssertEqual(FocusTimerMachine.next(from, event, now: now, config: config), expected, name)
        }
    }

    // MARK: - Cycle dots (P1)

    /// P1: the dots are the only clue in the pill to where the cycle stands; a
    /// wrong row makes "in session 3" and "on the break after 2" look the same,
    /// or shows the long break as an empty cycle.
    func testCycleDots() {
        func state(_ phase: FocusPhase?, done: Int) -> FocusTimerState {
            FocusTimerState(phase: phase, clock: phase == nil ? nil : .paused(remaining: 60), completedSessions: done)
        }
        let D = FocusTimerState.CycleDot.done, C = FocusTimerState.CycleDot.current, U = FocusTimerState.CycleDot.upcoming
        let cases: [(String, FocusTimerState, [FocusTimerState.CycleDot])] = [
            ("idle, fresh cycle", .idle, [U, U, U, U]),
            ("focus 1", state(.focus, done: 0), [C, U, U, U]),
            ("focus 3", state(.focus, done: 2), [D, D, C, U]),
            ("break after 2", state(.shortBreak, done: 2), [D, D, U, U]),
            ("focus 4", state(.focus, done: 3), [D, D, D, C]),
            ("long break: count already reset, shows all done", state(.longBreak, done: 0), [D, D, D, D]),
            ("idle after a break keeps the count", state(nil, done: 2), [D, D, U, U]),
        ]
        for (name, s, expected) in cases {
            XCTAssertEqual(s.cycleDots, expected, name)
        }
    }
}
