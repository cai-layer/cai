import Foundation

/// What the app publishes about the menu bar focus timer and Keep Awake, for
/// the helper's read-only `get_focus_state` tool.
///
/// Absolute times only (`endsAt`), never "seconds left": the file is
/// rewritten when something changes, not on every tick, so the reader works
/// out the time left itself.
public struct FocusStateSnapshot: Codable, Equatable {
    public struct Timer: Codable, Equatable {
        public var enabled: Bool
        /// "focus", "shortBreak" or "longBreak"; nil when idle.
        public var phase: String?
        public var endsAt: Date?
        public var pausedRemainingSeconds: Double?
        public var completedSessions: Int
        public var focusMinutes: Int
        public var shortBreakMinutes: Int
        public var longBreakMinutes: Int

        public init(enabled: Bool, phase: String?, endsAt: Date?, pausedRemainingSeconds: Double?,
                    completedSessions: Int, focusMinutes: Int, shortBreakMinutes: Int, longBreakMinutes: Int) {
            self.enabled = enabled
            self.phase = phase
            self.endsAt = endsAt
            self.pausedRemainingSeconds = pausedRemainingSeconds
            self.completedSessions = completedSessions
            self.focusMinutes = focusMinutes
            self.shortBreakMinutes = shortBreakMinutes
            self.longBreakMinutes = longBreakMinutes
        }
    }

    public struct KeepAwake: Codable, Equatable {
        public var enabled: Bool
        public var on: Bool
        /// Nil while on means no limit.
        public var endsAt: Date?

        public init(enabled: Bool, on: Bool, endsAt: Date?) {
            self.enabled = enabled
            self.on = on
            self.endsAt = endsAt
        }
    }

    public var timer: Timer
    public var keepAwake: KeepAwake

    public init(timer: Timer, keepAwake: KeepAwake) {
        self.timer = timer
        self.keepAwake = keepAwake
    }

    /// The tool's answer: plain sentences an agent can relay or act on.
    public func agentReply(now: Date) -> String {
        [timerLine(now: now), keepAwakeLine(now: now),
         "This is read-only: the user starts, pauses and skips from the Cai menu bar icon."]
            .joined(separator: "\n")
    }

    private func timerLine(now: Date) -> String {
        let t = timer
        guard t.enabled else { return "Focus timer: turned off in Cai Settings." }
        let lengths = "Lengths: focus \(t.focusMinutes) min, short break \(t.shortBreakMinutes) min, long break \(t.longBreakMinutes) min after every 4th session."
        let sessions = "\(t.completedSessions) of 4 focus sessions done before the long break."
        guard let phase = t.phase else {
            return "Focus timer: idle, waiting for the user to start a focus session. \(sessions) \(lengths)"
        }
        // Never echo the stored string: the file is outside the app's control,
        // and anything it says lands in the agent's context.
        let name = ["focus": "focus session", "shortBreak": "short break", "longBreak": "long break"][phase] ?? "unknown phase"
        if let paused = t.pausedRemainingSeconds {
            return "Focus timer: \(name), paused with \(Self.minutes(paused)) left. \(sessions) \(lengths)"
        }
        guard let endsAt = t.endsAt else { return "Focus timer: \(name). \(sessions) \(lengths)" }
        let left = endsAt.timeIntervalSince(now)
        if left <= 0 { return "Focus timer: the \(name) has just ended. \(sessions) \(lengths)" }
        return "Focus timer: \(name), \(Self.minutes(left)) left. \(sessions) \(lengths)"
    }

    private func keepAwakeLine(now: Date) -> String {
        let k = keepAwake
        guard k.enabled else { return "Keep Awake: turned off in Cai Settings." }
        guard k.on else { return "Keep Awake: off; the Mac can sleep as usual." }
        guard let endsAt = k.endsAt else { return "Keep Awake: on, with no time limit." }
        return "Keep Awake: on, \(Self.minutes(max(0, endsAt.timeIntervalSince(now)))) left."
    }

    /// Whole minutes, rounded up, so "0 min" never appears while time is left.
    private static func minutes(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        return m == 1 ? "1 min" : "\(m) min"
    }
}
