import Foundation

/// Turns a raw action-failure message into actionable permission guidance.
///
/// Agent-authored actions reach macOS privacy domains through the intact chain
/// (`Cai.app → Process(/bin/zsh) → osascript/JXA`). When TCC denies one, the
/// failure surfaces as opaque shell/AppleScript text: `-1743`, `-2700`, a
/// framework "not authorized" string, or a "Full Disk Access" mention. The user
/// can't act on that. This maps the message to the exact System Settings pane so
/// the runtime surface (`ResultView`) can offer a one-tap "Open Settings" button
/// instead of echoing a code.
///
/// It is a pure, `nonisolated` value type on purpose — matched in
/// `TCCRemediationTests`, not only in the live app. The detector is deliberately
/// conservative: it fires only on signatures we recognise, so a normal command
/// failure never misleads the user toward a permission pane.
enum TCCRemediation {

    /// A macOS privacy domain plus the deep link to its System Settings pane.
    /// Single source of truth for these URLs across the app.
    struct Domain: Equatable {
        let key: Key
        let label: String
        let settingsURL: URL

        enum Key: String, Equatable {
            case appleEvents
            case calendars
            case reminders
            case contacts
            case accessibility
            /// Detect-and-guide ONLY. FDA has no usage-description key and no
            /// request API — Cai can never prompt for it, so we only ever point
            /// the user at the pane. Never wire this to a request call.
            case fullDiskAccess
        }

        init(key: Key, label: String, settingsPath: String) {
            self.key = key
            self.label = label
            self.settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPath)")!
        }

        static let appleEvents = Domain(key: .appleEvents, label: "Automation", settingsPath: "Privacy_Automation")
        static let calendars = Domain(key: .calendars, label: "Calendar", settingsPath: "Privacy_Calendars")
        static let reminders = Domain(key: .reminders, label: "Reminders", settingsPath: "Privacy_Reminders")
        static let contacts = Domain(key: .contacts, label: "Contacts", settingsPath: "Privacy_Contacts")
        static let accessibility = Domain(key: .accessibility, label: "Accessibility", settingsPath: "Privacy_Accessibility")
        static let fullDiskAccess = Domain(key: .fullDiskAccess, label: "Full Disk Access", settingsPath: "Privacy_AllFiles")

        /// Bridges a `NativeAccessManager.Domain` to its remediation domain so
        /// the two never drift apart on the pane URL.
        init(_ domain: NativeAccessManager.Domain) {
            switch domain {
            case .calendars: self = .calendars
            case .contacts: self = .contacts
            }
        }
    }

    /// The guidance to show for a detected denial: which pane, and a ready
    /// user-facing sentence.
    struct Guidance: Equatable {
        let domain: Domain
        var settingsURL: URL { domain.settingsURL }

        /// One line the UI can show verbatim. States that Cai was blocked and
        /// where to fix it — never claims a domain is grantable when it isn't.
        var message: String {
            if domain.key == .fullDiskAccess {
                return "This action needs Full Disk Access. Grant Cai in System Settings \u{2192} Privacy & Security \u{2192} Full Disk Access, then run it again."
            }
            return "This action needs \(domain.label) access. Open System Settings \u{2192} Privacy & Security \u{2192} \(domain.label) and enable Cai, then run it again."
        }

        var buttonLabel: String { "Open \(domain.label) Settings" }
    }

    /// Detects a TCC denial in an error message and returns matching guidance,
    /// or `nil` when the failure doesn't look permission-related.
    ///
    /// Ordering matters: the most specific domain keywords are checked before
    /// the generic Apple Events codes, so a Calendar denial that also carries a
    /// `-1743` doesn't get mislabelled as generic Automation.
    nonisolated static func detect(in message: String) -> Guidance? {
        let lower = message.lowercased()

        // Full Disk Access — detect-only. The canonical macOS phrasings plus the
        // sandbox "operation not permitted" seen when a protected path is read.
        if lower.contains("full disk access") {
            return Guidance(domain: .fullDiskAccess)
        }

        // Domain-specific first.
        if mentionsDenial(lower, subject: "calendar") {
            return Guidance(domain: .calendars)
        }
        if mentionsDenial(lower, subject: "reminder") {
            return Guidance(domain: .reminders)
        }
        if mentionsDenial(lower, subject: "contact") {
            return Guidance(domain: .contacts)
        }

        // Generic Apple Events / Automation denial. -1743 is the canonical
        // "not authorized to send Apple events"; -2700 is a generic script error
        // but pairs with the same not-permitted language when TCC is the cause.
        if lower.contains("-1743")
            || lower.contains("not authorized to send apple events")
            || lower.contains("not authorised to send apple events")
            || lower.contains("not allowed to send apple events")
            || (lower.contains("apple event") && lower.contains("not permitted")) {
            return Guidance(domain: .appleEvents)
        }

        return nil
    }

    /// True when the message names `subject` (e.g. "calendar") *and* carries a
    /// denial phrase. Requiring both keeps an innocent mention of "calendar" in
    /// normal output from tripping the permission UI.
    private nonisolated static func mentionsDenial(_ lower: String, subject: String) -> Bool {
        guard lower.contains(subject) else { return false }
        // The exact phrasing agent JXA/osascript scripts throw, e.g.
        // "No Calendar access. Grant it in System Settings … (-2700)".
        if lower.contains("no \(subject) access") { return true }
        let denialPhrases = [
            "denied", "not authorized", "not authorised", "no access",
            "access denied", "not permitted", "not determined",
            // Remediation-flavoured wording + the generic AppleScript codes a
            // TCC-denied EventKit/Contacts call surfaces through osascript.
            "grant it", "grant access", "-1743", "-2700"
        ]
        return denialPhrases.contains { lower.contains($0) }
    }
}
