import Foundation

/// Ordering rules for the toast pill.
///
/// There is one pill and it lives at one spot on screen, so two things
/// happening close together have to take turns. Before this, the second
/// `showToast` called `hideToast()` and replaced the first mid-sentence, and
/// the first toast's dismiss timer then cut the second one short: a burst of
/// events produced a flicker and one survivor, which is worse than no toast at
/// all because the user knows they missed something.
///
/// Pure and nonisolated, so the ordering is table-tested rather than observed
/// by trying to read a pill that vanishes in a second and a half.
struct ToastQueue: Equatable {

    /// What the pill shows beside the message.
    ///
    /// A toast confirming something the user just did needs no identity: they
    /// are looking at Cai. A toast announcing something they did not ask for
    /// appears over whatever app they were actually using, so it says who is
    /// talking. And a refusal must not wear a success checkmark, which is what
    /// every message used to get.
    enum Icon: String, Equatable {
        /// Something the user asked for worked.
        case success
        /// Something was refused or set aside.
        case warning
        /// Unsolicited news from Cai itself, such as an agent's proposal.
        case cai

        var symbolName: String? {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .cai: return nil  // drawn from CaiLogoShape instead
            }
        }
    }

    struct Request: Equatable {
        let message: String
        let duration: TimeInterval
        let icon: Icon

        init(message: String, duration: TimeInterval = 1.5, icon: Icon = .success) {
            self.message = message
            self.duration = duration
            self.icon = icon
        }
    }

    /// Beyond this, the oldest waiting message is dropped. Four at 1.5s each
    /// is already six seconds of pills trailing behind reality; queueing more
    /// would have the app narrating events the user has moved on from.
    static let maxDepth = 4

    private(set) var pending: [Request] = []

    /// Adds a message unless it repeats what is on screen or what is already
    /// next in line. Returns whether it was accepted.
    ///
    /// Consecutive duplicates are collapsed because the same sentence twice
    /// reads as a rendering glitch, not as two events. Distinct messages all
    /// get their turn.
    @discardableResult
    mutating func enqueue(_ request: Request, showing: String?) -> Bool {
        guard request.message != showing, request.message != pending.last?.message else {
            return false
        }
        pending.append(request)
        if pending.count > Self.maxDepth {
            pending.removeFirst(pending.count - Self.maxDepth)
        }
        return true
    }

    mutating func next() -> Request? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    var isEmpty: Bool { pending.isEmpty }
}
