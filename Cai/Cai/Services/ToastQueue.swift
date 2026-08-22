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
        /// Something went wrong, was refused, or was set aside.
        case warning
        /// Work has started and has not finished.
        case progress
        /// Unsolicited news from Cai itself, such as an agent's proposal.
        case cai

        var symbolName: String? {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            // DESIGN.md's in-progress marker is the ◉; this is its SF Symbol.
            // Static rather than pulsing: the pill is pure AppKit and lives for
            // 1.5s, and the codebase already treats a static marker as the
            // reduced-motion equivalent (see the header "Running" pill).
            case .progress: return "smallcircle.filled.circle"
            case .cai: return nil  // drawn from CaiLogoShape instead
            }
        }

        /// Spoken equivalent of the glyph. The glyph is the only non-text
        /// carrier of the outcome, so without this a VoiceOver user gets the
        /// message and no indication of whether it succeeded — the same
        /// dishonesty the checkmark-on-failure bug was. Wording follows
        /// DESIGN.md's step-indicator labels.
        var accessibilityLabel: String {
            switch self {
            case .success: return "Done"
            case .warning: return "Problem"
            case .progress: return "In progress"
            case .cai: return "From Cai"
            }
        }
    }

    /// What happened, in the vocabulary a call site already knows.
    ///
    /// Posting sites reason about outcomes ("this failed"), not about glyphs,
    /// and the glyph was the part they kept getting wrong — a failure that did
    /// not name its icon used to render a "Failed: …" under a checkmark. Naming
    /// the outcome instead makes the glyph and the dwell fall out of one table,
    /// and `post` makes naming it mandatory.
    ///
    /// One case per distinct *behaviour*. There is deliberately no separate
    /// `failure` and `refusal`: they rendered identically, which meant the
    /// distinction was carried only by a doc comment and was already applied
    /// inconsistently. Whether Cai broke or Cai declined is something the
    /// message text says, in the words the user actually reads. Split them again
    /// the day they need to look different.
    enum Outcome: String, Equatable {
        /// Something the user asked for worked.
        case success
        /// It did not work, or Cai declined to do it, or it was set aside.
        case problem
        /// Work has started and has not finished.
        case progress
        /// Unsolicited news from Cai itself, such as an agent's proposal.
        case arrival
    }

    /// How an `Outcome` is shown: which glyph, and how long it stays.
    struct Presentation: Equatable {
        let icon: Icon
        let duration: TimeInterval
    }

    /// Shortest and longest a pill may stay. The ceiling matters because the
    /// pill cannot be dismissed: an over-long toast is an obstruction the user
    /// has no way to clear.
    static let briefDwell: TimeInterval = 1.5
    static let readableDwell: TimeInterval = 3.5
    static let maxDwell: TimeInterval = 6.0

    /// The single outcome → appearance table. Pure and nonisolated so the
    /// mapping is table-tested rather than eyeballed on a pill that vanishes in
    /// a second and a half. The one invariant worth stating out loud: nothing
    /// but `.success` may map to the checkmark, because a checkmark over a
    /// failure is a lie the user acts on.
    ///
    /// The axis that sets the dwell is "does the user have to READ this to know
    /// what happened" — not merely whether they triggered it.
    ///
    /// A success and a progress message both answer an action the user just
    /// took, and the answer is the one they expected, so the pill is an
    /// acknowledgement rather than information: brief 1.5s, however long the
    /// text is. (A progress pill is also superseded by its own terminal toast
    /// moments later; holding it longer would only stack the two.)
    ///
    /// A problem and an arrival both carry something the user does not already
    /// know, so both get read time — including a problem the user provoked
    /// themselves. "An action is already running" answers a keypress, but the
    /// answer is that their action did NOT run, and the reason is only in the
    /// words. Same for an arrival, which lands unsolicited over whatever app
    /// they were working in and has to survive the shift in attention before
    /// the reading even starts.
    ///
    /// For those, dwell scales with length, because the copy on this channel
    /// ranges from five words ("An action is already running") to fifteen
    /// ("This proposal changed since you read it. Nothing was decided; review
    /// the new version."), and one flat number cannot serve both. ~0.3s per
    /// word approximates a 200wpm glance-read, plus a second to notice the pill
    /// at all, floored at `readableDwell` and capped at `maxDwell`.
    static func presentation(for outcome: Outcome, message: String = "") -> Presentation {
        let icon: Icon
        switch outcome {
        case .success: icon = .success
        case .problem: icon = .warning
        case .progress: icon = .progress
        case .arrival: icon = .cai
        }

        switch outcome {
        case .success, .progress:
            return Presentation(icon: icon, duration: briefDwell)
        case .problem, .arrival:
            break
        }
        let words = message.split(whereSeparator: \.isWhitespace).count
        let readingTime = 1.0 + 0.3 * Double(words)
        return Presentation(
            icon: icon,
            duration: min(max(readableDwell, readingTime), maxDwell)
        )
    }

    /// The sanctioned way to raise a toast.
    ///
    /// `outcome` has NO default, which is the whole point: the bug this file
    /// exists to prevent was a `userInfo` dictionary where forgetting a key
    /// silently produced a success checkmark on a failure. Here, forgetting it
    /// is a compile error. Prefer this over posting `.caiShowToast` by hand.
    ///
    /// Pass `isActionResult: true` when `message` is the action's OWN OUTPUT
    /// rather than a Cai status message — see the observer in
    /// `WindowController` for why that distinction matters.
    static func post(_ message: String, outcome: Outcome, isActionResult: Bool = false) {
        var userInfo: [String: Any] = [
            "message": message,
            "outcome": outcome.rawValue,
        ]
        if isActionResult {
            userInfo["isActionResult"] = true
        }
        NotificationCenter.default.post(name: .caiShowToast, object: nil, userInfo: userInfo)
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

    /// Beyond this, the oldest waiting message is dropped, because a queue
    /// deeper than this has the app narrating events the user has moved on
    /// from.
    ///
    /// Note the interaction with `presentation(for:)`: at four deep this is six
    /// seconds of successes but up to `4 * maxDwell` of problems, since anything
    /// the user did not watch happen dwells 3.5s or longer. Consecutive
    /// duplicates already collapse, so the bad case needs four DISTINCT
    /// failures in a row — rare enough to accept, and the alternative (dropping
    /// newer failures) loses the message that is actually current.
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
