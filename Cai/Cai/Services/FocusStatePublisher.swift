import CaiActionCore
import Foundation

/// Writes `focus-state.json` for the `cai-mcp` helper's read-only
/// `get_focus_state` tool.
///
/// Called on every timer and Keep Awake notification, including the timer's
/// one-second ticks, but writes only when the snapshot changes: it holds
/// absolute end times, so a tick leaves it identical.
@MainActor
final class FocusStatePublisher {
    static let shared = FocusStatePublisher()

    private var lastWritten: FocusStateSnapshot?
    private let root = CaiSupportPaths.root

    func publish() {
        let settings = CaiSettings.shared
        let timer = FocusTimerController.shared
        let keepAwake = KeepAwakeController.shared.state

        let phase: String? = timer.state.phase.map {
            switch $0 {
            case .focus: return "focus"
            case .shortBreak: return "shortBreak"
            case .longBreak: return "longBreak"
            }
        }
        var endsAt: Date?
        var paused: Double?
        switch timer.state.clock {
        case .running(let end): endsAt = end
        case .paused(let remaining): paused = remaining
        case nil: break
        }
        var keepAwakeEnd: Date?
        if case .on(let startedAt, let duration) = keepAwake, let seconds = duration.seconds {
            keepAwakeEnd = startedAt.addingTimeInterval(seconds)
        }

        let snapshot = FocusStateSnapshot(
            timer: .init(
                enabled: settings.focusTimerEnabled,
                phase: phase,
                endsAt: endsAt,
                pausedRemainingSeconds: paused,
                completedSessions: timer.state.completedSessions,
                focusMinutes: settings.focusMinutes,
                shortBreakMinutes: settings.shortBreakMinutes,
                longBreakMinutes: settings.longBreakMinutes
            ),
            keepAwake: .init(enabled: settings.keepAwakeEnabled, on: keepAwake.isOn, endsAt: keepAwakeEnd)
        )
        guard snapshot != lastWritten else { return }

        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let url = CaiSupportPaths.focusState(in: root)
            try ActionCoding.encoder.encode(snapshot).write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastWritten = snapshot
        } catch {
            print("Focus state: could not publish: \(error.localizedDescription)")
        }
    }
}
