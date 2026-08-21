import AppKit
import Contacts
import EventKit

/// Owns Cai's on-demand macOS privacy (TCC) grants for the domains an action
/// can legitimately reach through the intact responsibility chain
/// (`Cai.app → Process(/bin/zsh) → osascript/JXA`): **Calendar**, **Reminders**
/// and **Contacts**, via the Apple-signed EventKit / Contacts frameworks.
///
/// Grants Cai can only *report on* — Accessibility and Automation — live in
/// `SystemDomain` and are never requested from here.
///
/// Posture "B — Shortcuts-modeled, chain-intact" (see
/// `_docs/architecture/PERMISSIONS.md`). Because Cai is non-sandboxed and stays
/// the TCC *responsible process*, the only thing standing between an
/// agent-authored EventKit action and a working OS prompt is (a) a usage string
/// in Info.plist and (b) a live `requestAccess` call. A usage string alone never
/// prompts, and calling `requestAccess` with the string missing *crashes* the
/// process — so this manager is the single gate that fires the request, and the
/// Connections screen's "System Access" tab is where the user pre-grants from
/// inside Cai.
///
/// **Never Full Disk Access.** FDA has no usage-description key and no request
/// API; it is detect-and-guide only (`TCCRemediation`). Nothing here requests it.
///
/// Decision logic (status→state, the macOS-version request branch, and what a
/// toggle tap should do) is pulled out into pure, `nonisolated static` functions
/// so it is table-tested (`NativeAccessTests`) instead of only exercised in the
/// live app against real system state.
@MainActor
final class NativeAccessManager: ObservableObject {
    static let shared = NativeAccessManager()

    /// A macOS privacy domain Cai can request on demand — the *grantable*
    /// half of System Access. Every case here must have (a) an Info.plist usage
    /// string and (b) a real request API, because `handleToggle` fires a live OS
    /// prompt. Domains Cai can only report on live in `SystemDomain`.
    ///
    /// Calendar and Reminders are both EventKit and share one hardened-runtime
    /// entitlement (`com.apple.security.personal-information.calendars`); there
    /// is no separate reminders entitlement key. See `PERMISSIONS.md`.
    enum Domain: String, CaseIterable, Identifiable {
        case calendars
        // Reminders sits next to Calendar: same framework, same entitlement.
        case reminders
        case contacts

        var id: String { rawValue }

        /// Row label in the Connections screen's "System Access" tab.
        var title: String {
            switch self {
            case .calendars: return "Calendar"
            case .reminders: return "Reminders"
            case .contacts: return "Contacts"
            }
        }

        /// SF Symbol for the row's leading icon.
        var icon: String {
            switch self {
            case .calendars: return "calendar"
            case .reminders: return "checklist"
            case .contacts: return "person.crop.circle"
            }
        }

        /// One-line, benefit-first subtitle (fills the row's scope/status slot).
        var subtitle: String {
            switch self {
            case .calendars: return "Read events and add new ones"
            case .reminders: return "Read and create reminders"
            case .contacts: return "Look up people you mention"
            }
        }

        /// The exact System Settings → Privacy pane for this domain, used both
        /// by the "re-enable in System Settings" flow when access is denied and
        /// by runtime remediation. Single-sourced with `TCCRemediation`.
        var settingsURL: URL { TCCRemediation.Domain(self).settingsURL }
    }

    /// A macOS grant Cai can **report on but never request** — the read-only
    /// half of System Access. Kept separate from `Domain` on purpose: `request`,
    /// `state(for:)` and `refreshAll()` switch exhaustively over `Domain`, so
    /// folding these in behind an `isRequestable` flag would push unreachable
    /// branches into all three and let a future call site ask for a grant that
    /// has no request API.
    ///
    /// - **Accessibility** has no request API beyond the AX prompt onboarding
    ///   already owns (`PermissionsManager`); a second door here would re-prompt
    ///   users who have answered.
    /// - **Automation** (Apple Events) is granted per *(source, target)* pair and
    ///   prompts on first use through the destination path. There is no
    ///   app-level status to read: the only non-prompting API
    ///   (`AEDeterminePermissionToAutomateTarget`) needs a specific *running*
    ///   target, and the only other source of truth is TCC.db, which would need
    ///   Full Disk Access — a hard never. So this row makes **no status claim**;
    ///   its subtitle states the per-app truth instead.
    enum SystemDomain: String, CaseIterable, Identifiable {
        case accessibility
        case automation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .automation: return "Automation"
            }
        }

        var icon: String {
            switch self {
            case .accessibility: return "accessibility"
            case .automation: return "gearshape.2"
            }
        }

        var subtitle: String {
            switch self {
            case .accessibility: return "Lets Cai read your selection when you press \u{2325}C"
            case .automation: return "macOS asks per app the first time an action targets it"
            }
        }

        var settingsURL: URL {
            switch self {
            case .accessibility: return TCCRemediation.Domain.accessibility.settingsURL
            case .automation: return TCCRemediation.Domain.appleEvents.settingsURL
            }
        }

        /// Trailing status text, or `nil` when Cai cannot honestly claim one.
        /// Automation returns `nil` so the status slot stays **empty** rather
        /// than showing a word in the position where "Granted" appears — a
        /// string there reads as a state Cai verified, which for a per-app grant
        /// would be a lie by layout.
        nonisolated func statusText(accessibilityGranted: Bool) -> String? {
            switch self {
            case .accessibility: return accessibilityGranted ? "Granted" : "Not granted"
            case .automation: return nil
            }
        }
    }

    /// UI-facing tri(+1)-state for a domain, derived from the framework's raw
    /// authorization status. This is what the toggle and its affordance read —
    /// never the raw `EKAuthorizationStatus` / `CNAuthorizationStatus`.
    enum AccessState: Equatable {
        /// Never asked. Flipping the toggle fires the real OS prompt.
        case notDetermined
        /// Granted (full access). Toggle reads ON.
        case authorized
        /// User said no. Toggle reads OFF; flipping deep-links System Settings
        /// (macOS gives no API to re-request once denied).
        case denied
        /// Blocked by MDM / parental controls. Same UX as denied.
        case restricted

        var isOn: Bool { self == .authorized }
    }

    /// What flipping a domain's toggle should do, given its current state.
    enum ToggleIntent: Equatable {
        /// Fire the live OS prompt (`requestAccess`).
        case request
        /// Nothing to request — open the System Settings pane instead
        /// (already granted → user wants to revoke; or denied → re-enable).
        case openSettings
    }

    /// Which EventKit request API to use for a given macOS major version.
    enum EventKitRequestStrategy: Equatable {
        /// macOS 14+: `requestFullAccessToEvents()`.
        case fullAccess
        /// macOS 13: legacy `requestAccess(to: .event)`.
        case legacy
    }

    @Published private(set) var calendars: AccessState = .notDetermined
    @Published private(set) var reminders: AccessState = .notDetermined
    @Published private(set) var contacts: AccessState = .notDetermined

    // `var`, and deliberately recreated before every request. An EKEventStore /
    // CNContactStore instance binds to the authorization state it was created
    // under: once it has seen an answer, `requestFullAccess*` short-circuits and
    // returns WITHOUT ever contacting tccd — no prompt, no log entry, and the
    // toggle silently snaps back. Indistinguishable from a missing entitlement.
    //
    // This bites real users, not just a `tccutil reset` test loop: Calendar and
    // Reminders share one store, so granting Calendar and then flipping
    // Reminders reuses a store that is already "answered" and the second prompt
    // never appears. See `refreshedEventStore()`.
    private var eventStore = EKEventStore()
    private var contactStore = CNContactStore()

    private init() {
        refreshAll()
    }

    // MARK: - Pure decision logic (unit-tested)

    /// Maps EventKit's raw status to our UI state. `.writeOnly` (macOS 14+) is
    /// treated as `.denied`: Cai's Calendar benefit promises *reading* events,
    /// which write-only access can't satisfy, so the toggle should read OFF and
    /// guide the user to grant full access.
    nonisolated static func state(from status: EKAuthorizationStatus) -> AccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        case .authorized: return .authorized  // legacy (pre-14) "granted"
        case .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    /// Maps Contacts' raw status to our UI state.
    nonisolated static func state(from status: CNAuthorizationStatus) -> AccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default:
            // `.limited` (macOS 15+) and any future case: partial/unknown grants
            // aren't the full access Cai's usage string asks for → treat as
            // denied so the toggle guides to System Settings rather than lying ON.
            return .denied
        }
    }

    /// The EventKit request path for a macOS major version. macOS 14 split
    /// calendar access into full/write-only; 13 has only the legacy request.
    nonisolated static func eventKitRequestStrategy(macOSMajorVersion: Int) -> EventKitRequestStrategy {
        macOSMajorVersion >= 14 ? .fullAccess : .legacy
    }

    /// What a toggle tap means in a given state. Only `.notDetermined` can fire
    /// a real prompt; every other state routes to System Settings because macOS
    /// exposes no API to re-request once the user has answered.
    nonisolated static func toggleIntent(for state: AccessState) -> ToggleIntent {
        state == .notDetermined ? .request : .openSettings
    }

    // MARK: - Reads

    func state(for domain: Domain) -> AccessState {
        switch domain {
        case .calendars: return calendars
        case .reminders: return reminders
        case .contacts: return contacts
        }
    }

    /// Reads a domain's **current** authorization status straight from the
    /// framework, without touching `@Published` state.
    ///
    /// Safe to call from a SwiftUI `body`, which `refreshAll()` is not (writing
    /// published state during a view update is a "Modifying state during view
    /// update" bug). Use this wherever a decision must reflect a grant the user
    /// changed in System Settings while Cai was already open, rather than
    /// whatever was cached the last time something called `refreshAll()`.
    nonisolated static func liveState(for domain: Domain) -> AccessState {
        switch domain {
        case .calendars: return state(from: EKEventStore.authorizationStatus(for: .event))
        case .reminders: return state(from: EKEventStore.authorizationStatus(for: .reminder))
        case .contacts: return state(from: CNContactStore.authorizationStatus(for: .contacts))
        }
    }

    /// Assigns only on change: this runs on every app activation while the
    /// System Access tab is open, and an unconditional write would fire
    /// `objectWillChange` three times per activation for no reason.
    func refreshAll() {
        let newCalendars = Self.liveState(for: .calendars)
        let newReminders = Self.liveState(for: .reminders)
        let newContacts = Self.liveState(for: .contacts)
        if calendars != newCalendars { calendars = newCalendars }
        if reminders != newReminders { reminders = newReminders }
        if contacts != newContacts { contacts = newContacts }
    }

    // MARK: - Toggle handling

    /// Handles a toggle flip for `domain` according to `toggleIntent(for:)`:
    /// request the live OS prompt when undetermined, otherwise open the domain's
    /// System Settings pane. Refreshes published state after a request resolves.
    func handleToggle(for domain: Domain) {
        switch Self.toggleIntent(for: state(for: domain)) {
        case .request:
            Task { await request(domain) }
        case .openSettings:
            NSWorkspace.shared.open(domain.settingsURL)
        }
    }

    // MARK: - Runtime remediation (grant-on-denial)

    /// Maps a detected TCC domain to an in-app domain Cai can *request*, or nil
    /// for domains Cai can only guide toward (Apple Events, Full Disk Access).
    nonisolated static func requestableDomain(for key: TCCRemediation.Domain.Key) -> Domain? {
        switch key {
        case .calendars: return .calendars
        // Requestable as of the "Complete System Access" change: a mid-action
        // Reminders denial now fires the OS prompt instead of only guiding to
        // Settings. Safe because Reminders rides EventKit's calendars
        // entitlement, which Cai already holds.
        case .reminders: return .reminders
        case .contacts: return .contacts
        case .appleEvents, .accessibility, .fullDiskAccess: return nil
        }
    }

    /// When an action fails because a requestable grant (Calendar, Reminders,
    /// Contacts) is missing, fix it
    /// *inside Cai* instead of dumping a raw error on the user.
    ///
    /// - `.notDetermined` → go **straight to the system prompt** (no custom
    ///   pre-dialog). The user just ran an action that needs this and the OS
    ///   prompt already carries Cai's usage string, so a priming modal would be
    ///   redundant friction — and other tools don't show one. Confirms via toast.
    /// - `.denied`/`.restricted` → a Cai alert that deep-links the Settings pane,
    ///   because macOS exposes no way to re-prompt once answered — here the alert
    ///   earns its place (there's no system prompt to defer to).
    ///
    /// Returns `true` when it handled the error (caller should suppress its own
    /// raw failure toast), `false` for non-TCC errors or non-requestable domains
    /// so the caller falls back to its normal surface.
    @discardableResult
    func offerGrantIfPossible(forErrorMessage message: String) -> Bool {
        guard let guidance = TCCRemediation.detect(in: message),
              let domain = Self.requestableDomain(for: guidance.domain.key) else { return false }

        // Re-read live status before deciding. The cached state is only
        // refreshed at init, on tab open, and after a request, so a grant
        // revoked in System Settings mid-session would otherwise look
        // `.authorized` here and fall through to the raw error.
        refreshAll()

        let label = guidance.domain.label

        switch state(for: domain) {
        case .authorized:
            // Access is granted; the failure was something else. Let the caller
            // show its real error.
            return false
        case .notDetermined:
            requestAndConfirm(domain)   // straight to the OS prompt
            return true
        case .denied, .restricted:
            let alert = NSAlert()
            alert.messageText = "Cai needs \(label) access"
            alert.informativeText = "Cai doesn't have full \(label) access. Enable Cai under \(label) in System Settings, then run the action again."
            alert.addButton(withTitle: "Open \(label) Settings")
            alert.addButton(withTitle: "Not Now")
            NSApplication.shared.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(domain.settingsURL)
            }
            return true
        }
    }

    /// Fires the OS prompt for `domain`, then posts a toast telling the user
    /// whether it was granted so they know to re-run the action. The single
    /// grant entry point shared by both failure surfaces — the toast
    /// grant-on-denial path (`offerGrantIfPossible`) and the in-window
    /// `ResultView` remediation button — so the two never drift.
    func requestAndConfirm(_ domain: Domain) {
        Task {
            await request(domain)
            let granted = state(for: domain) == .authorized
            NotificationCenter.default.post(
                name: .caiShowToast, object: nil,
                userInfo: [
                    "message": granted
                        ? "\(domain.title) access granted — run the action again."
                        : "\(domain.title) access wasn't granted.",
                    "icon": granted ? ToastQueue.Icon.success.rawValue : ToastQueue.Icon.warning.rawValue
                ]
            )
        }
    }

    /// Fires the real OS permission prompt for `domain`. Safe to call only when
    /// the matching Info.plist usage string exists — EventKit/Contacts crash the
    /// process otherwise, which is why requests are funnelled through here.
    func request(_ domain: Domain) async {
        // Bring Cai forward so the system TCC prompt isn't presented behind the
        // floating panel (the prompt is system-drawn, so this is polish, not a
        // requirement). `activate()` replaces the deprecated
        // `activate(ignoringOtherApps:)` on macOS 14+.
        NSApplication.shared.activate()
        switch domain {
        case .calendars:
            await requestCalendars()
        case .reminders:
            await requestReminders()
        case .contacts:
            await requestContacts()
        }
        refreshAll()
    }

    private func requestCalendars() async {
        eventStore = EKEventStore()   // see the eventStore declaration
        let strategy = Self.eventKitRequestStrategy(
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        do {
            switch strategy {
            case .fullAccess:
                if #available(macOS 14.0, *) {
                    _ = try await eventStore.requestFullAccessToEvents()
                } else {
                    _ = try await eventStore.requestAccess(to: .event)
                }
            case .legacy:
                _ = try await eventStore.requestAccess(to: .event)
            }
        } catch {
            // A thrown error resolves to a denied/undetermined status, which
            // `refreshAll()` reads back — nothing to surface here.
        }
    }

    /// Mirrors `requestCalendars()` — same EventKit version branch, same silent
    /// catch (a thrown error resolves to a status `refreshAll()` reads back).
    /// Gated by `NSRemindersFullAccessUsageDescription` plus the shared EventKit
    /// `personal-information.calendars` entitlement.
    private func requestReminders() async {
        eventStore = EKEventStore()   // see the eventStore declaration
        let strategy = Self.eventKitRequestStrategy(
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        do {
            switch strategy {
            case .fullAccess:
                if #available(macOS 14.0, *) {
                    _ = try await eventStore.requestFullAccessToReminders()
                } else {
                    _ = try await eventStore.requestAccess(to: .reminder)
                }
            case .legacy:
                _ = try await eventStore.requestAccess(to: .reminder)
            }
        } catch {
            // See requestCalendars().
        }
    }

    private func requestContacts() async {
        contactStore = CNContactStore()   // see the contactStore declaration
        _ = try? await contactStore.requestAccess(for: .contacts)
    }
}
