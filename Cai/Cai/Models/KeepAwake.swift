import Foundation

/// How long Keep Awake holds the Mac awake once started.
enum KeepAwakeDuration: Equatable {
    case indefinitely
    case minutes(Int)

    /// The "Keep Awake For" submenu, in order.
    static let presets: [KeepAwakeDuration] = [
        .indefinitely, .minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(300),
    ]

    static let `default`: KeepAwakeDuration = .minutes(30)

    /// Persisted as whole minutes, 0 meaning indefinitely.
    init(storedMinutes: Int) {
        self = storedMinutes > 0 ? .minutes(storedMinutes) : .indefinitely
    }

    var storedMinutes: Int {
        switch self {
        case .indefinitely: return 0
        case .minutes(let m): return m
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .indefinitely: return nil
        case .minutes(let m): return TimeInterval(m * 60)
        }
    }

    var menuTitle: String {
        switch self {
        case .indefinitely: return "Indefinitely"
        case .minutes(let m) where m % 60 == 0:
            let h = m / 60
            return h == 1 ? "1 Hour" : "\(h) Hours"
        case .minutes(let m): return "\(m) Minutes"
        }
    }
}

enum KeepAwakeState: Equatable {
    case off
    case on(startedAt: Date, duration: KeepAwakeDuration)

    var isOn: Bool { self != .off }

    /// Share of the duration still left, clamped to 0...1 (1 = just started).
    /// Nil when off or indefinite: there is no curtain to draw.
    func remainingFraction(now: Date) -> Double? {
        guard case .on(let startedAt, let duration) = self, let total = duration.seconds, total > 0 else {
            return nil
        }
        let left = total - now.timeIntervalSince(startedAt)
        return min(1, max(0, left / total))
    }

    func isExpired(now: Date) -> Bool {
        remainingFraction(now: now) == 0
    }

    /// The grey status row at the top of the Keep Awake section.
    ///
    /// Minutes round up, so the last minute reads "1 min left", never "0 min
    /// left" while the Mac is still being held awake.
    func menuHeader(now: Date) -> String? {
        guard case .on(let startedAt, let duration) = self else { return nil }
        guard let total = duration.seconds else { return "Keep Awake: No limit" }
        let left = min(total, max(0, total - now.timeIntervalSince(startedAt)))
        let minutes = max(1, Int((left / 60).rounded(.up)))
        if minutes < 60 { return "Keep Awake: \(minutes) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "Keep Awake: \(h) h left" : "Keep Awake: \(h) h \(m) min left"
    }
}

/// Pure decisions behind the status item, kept out of AppKit glue so they can
/// be table-tested (see `KeepAwakeTests`).
enum KeepAwakePolicy {
    enum ClickAction: Equatable {
        case openSettings
        case start(KeepAwakeDuration)
        case stop
        /// A click on the focus countdown: open the restart / pause / skip
        /// pill under it.
        case showTimerPill
    }

    /// What a one-finger click on the status item does. On the countdown it
    /// belongs to the timer; on the logo it is Keep Awake, or Settings when
    /// Keep Awake is disabled (the default), exactly as before.
    static func clickAction(onCountdown: Bool, keepAwakeEnabled: Bool, isOn: Bool, lastDuration: KeepAwakeDuration) -> ClickAction {
        if onCountdown { return .showTimerPill }
        guard keepAwakeEnabled else { return .openSettings }
        return isOn ? .stop : .start(lastDuration)
    }

    /// Whether a click at `x` (in the status button's coordinates) landed on
    /// the countdown rather than the logo. The countdown starts where the
    /// image ends; a keyboard press has no location and counts as the logo.
    static func clickIsOnCountdown(x: CGFloat?, imageWidth: CGFloat, hasCountdown: Bool) -> Bool {
        guard hasCountdown, let x else { return false }
        return x > imageWidth
    }

    /// Whether a power-source change should end Keep Awake: only on battery,
    /// only below the threshold (strictly), only when the setting is on.
    static func shouldStopForBattery(onBattery: Bool, percent: Int, thresholdEnabled: Bool, threshold: Int) -> Bool {
        thresholdEnabled && onBattery && percent < threshold
    }

    /// How often the curtain is redrawn: when it has moved about half a pixel
    /// at 2x on a 14pt logo (56 steps), between 1 s and 60 s. A 5 h run does
    /// not need a redraw every second.
    static func redrawInterval(for duration: KeepAwakeDuration) -> TimeInterval? {
        guard let total = duration.seconds else { return nil }
        return min(60, max(1, total / 56))
    }
}
