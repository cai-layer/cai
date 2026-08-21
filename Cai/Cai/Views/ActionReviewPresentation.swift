import CaiActionCore
import Foundation

/// Everything the approval sheet decides before it draws anything.
///
/// The sheet is the security boundary for agent authoring, so the parts that
/// determine what the user is told (which callout, which acknowledgment, what
/// the payload is, whether Approve can fire at all) are pure static functions
/// with a table-driven test each, not conditions buried in a view body. A
/// wrong callout here means a user approving something other than what they
/// read.
///
/// Copy strings are deliberate review-surface trust copy, agreed in design
/// review; see `_docs/architecture/MCP.md` (Cai as a Server).
enum ActionReviewPresentation {

    // MARK: - Fixed copy

    static let approveButton = "Approve"
    static let rejectButton = "Reject"
    static let emptyState = "No proposals waiting. Connect your agent in Settings to create actions from Claude Code."
    static let emptyStateButton = "Open Settings"
    /// Fallback when the MCP handshake carried no client name.
    static let unknownAuthor = "An agent"

    // MARK: - Window title

    /// The sheet's title, split so the view can render the action's name in the
    /// primary weight and the create/update prefix underneath it in secondary.
    /// The name is the subject of the whole decision, so it leads; the prefix
    /// says which of the two shapes (a new action, or a change to one) the
    /// reader is looking at.
    struct WindowTitle: Equatable {
        /// "New action" or "Update".
        let prefix: String
        /// The action's name, sanitized to a single capped line.
        let name: String

        /// One string for VoiceOver and tests: "New action · Unread mail digest".
        var combined: String { "\(prefix) · \(name)" }
    }

    /// "New action · <name>" for a create, "Update · <name>" for an update.
    ///
    /// The name is attacker-controlled: it rides in from the proposal and sits
    /// in Cai's own title voice. `ActionValidator` already normalizes the
    /// proposed side, but this is the belt to that brace and also covers the
    /// stored `before` side, which reaches the sheet un-normalized. Control
    /// characters are stripped (a newline would let a name fake a second title
    /// line) and the length is capped, so the title can never be more than one
    /// bounded line however the name arrives.
    static func windowTitle(name: String, isUpdate: Bool) -> WindowTitle {
        let clean = name
            .strippingControlCharacters(keepingNewlines: false)
            .prefix(ActionSchema.maxNameLength)
        return WindowTitle(prefix: isUpdate ? "Update" : "New action", name: String(clean))
    }

    // MARK: - Escalation copy

    /// The plain-language warning shown under the payload, one per reason.
    ///
    /// `secretNames` is scanned from the proposal's template at render time
    /// (never taken from the stored validation — CAI-25), so a
    /// `referencesSecrets` callout names exactly what the payload on screen
    /// reaches for. Empty names still warn, just generically: a chained action
    /// can carry the reason while the proposal's own text has no reference.
    static func callout(for reason: EscalationReason, secretNames: [String] = []) -> String {
        switch reason {
        case .runsShellCommands:
            return "This action can run terminal commands on your Mac."
        case .sendsSelectionToURL:
            return "This action sends your selected text to the URL shown above."
        case .replacesSelection:
            return "This action replaces your selected text without showing a preview."
        case .runsWithoutShowingOutput:
            return "This action runs without showing its output."
        case .chainsToUnknownAction:
            return "This action triggers another action that doesn't exist yet, so Cai can't say what it will do."
        case .referencesSecrets:
            guard !secretNames.isEmpty else {
                return "This action uses one of your secrets."
            }
            let noun = secretNames.count == 1 ? "secret" : "secrets"
            return "This action uses your \(noun) \(secretList(secretNames))."
        }
    }

    /// "A" / "A and B" / "A, B and C" — names only, never values.
    static func secretList(_ names: [String]) -> String {
        let sorted = names.sorted()
        guard sorted.count > 1 else { return sorted.first ?? "" }
        return sorted.dropLast().joined(separator: ", ") + " and " + sorted[sorted.count - 1]
    }

    /// Lead-in for the grouped callout, used when an action carries more than
    /// one risk.
    static let calloutHeader = "This action will:"

    /// One risk as a list item, for the grouped callout. Same claim as the
    /// sentence form, minus the repeated "This action" that reads as noise
    /// once it is stacked three deep.
    static func calloutBullet(for reason: EscalationReason, secretNames: [String] = []) -> String {
        switch reason {
        case .runsShellCommands:
            return "Run terminal commands on your Mac"
        case .sendsSelectionToURL:
            return "Send your selected text to the URL shown above"
        case .replacesSelection:
            return "Replace your selected text without showing a preview"
        case .runsWithoutShowingOutput:
            return "Run without showing its output"
        case .chainsToUnknownAction:
            return "Trigger another action that doesn't exist yet"
        case .referencesSecrets:
            guard !secretNames.isEmpty else { return "Use one of your secrets" }
            let noun = secretNames.count == 1 ? "secret" : "secrets"
            return "Use your \(noun) \(secretList(secretNames))"
        }
    }

    /// How the callout renders for a given set of risks: one sentence for a
    /// single risk (the design spec's verbatim copy), a grouped list beyond
    /// that.
    enum Callout: Equatable {
        case none
        case sentence(String)
        case grouped(header: String, bullets: [String])
    }

    static func callout(for reasons: [EscalationReason], secretNames: [String] = []) -> Callout {
        switch reasons.count {
        case 0:
            return .none
        case 1:
            return .sentence(callout(for: reasons[0], secretNames: secretNames))
        default:
            return .grouped(
                header: calloutHeader,
                bullets: reasons.map { calloutBullet(for: $0, secretNames: secretNames) }
            )
        }
    }

    // MARK: - The approve interlock

    /// One acknowledgment, however many risks the action carries.
    ///
    /// It used to be one checkbox per risk, which is where habituation actually
    /// comes from: tick-tick-approve becomes muscle memory faster than a single
    /// deliberate act does, and then the interlock is theatre. It also
    /// contradicted the merged callout, which states every risk once.
    ///
    /// Not zero, though. This approval is permanent: the action runs from ⌥C
    /// forever afterwards with no further prompt, unlike a per-invocation
    /// permission that expires. Permanence is what buys one extra deliberate
    /// act beyond the button the user was going to click anyway.
    ///
    /// This is also what makes Return inert until the box is ticked: Approve
    /// owns the shortcut, and a disabled button swallows the key.
    static func canApprove(tier: ApprovalTier, acknowledged: Bool) -> Bool {
        tier == .escalated ? acknowledged : true
    }

    /// The label for that one checkbox.
    ///
    /// It refers to the callout rather than restating it. The design spec had a
    /// per-risk sentence in the first person, which put the same words on
    /// screen twice: "This action can run terminal commands on your Mac."
    /// immediately above "I understand this action can run terminal commands".
    /// Repetition on a small sheet costs height and teaches the eye to skip the
    /// second copy, which works against the reading the checkbox exists to
    /// force.
    ///
    /// Generic wording is only a problem when the label is the sole statement
    /// of risk. It never is: this returns nil unless there are risks, and risks
    /// always render the callout directly above.
    static let acknowledgmentLabel = "I understand what this action can do"

    static func acknowledgment(for reasons: [EscalationReason]) -> String? {
        reasons.isEmpty ? nil : acknowledgmentLabel
    }

    // MARK: - Queue

    /// "1 of 3" while more than one proposal waits, nil for a single one. The
    /// queue is deliberately one at a time; this only says how much is behind
    /// the current card.
    static func queueCounter(index: Int, total: Int) -> String? {
        guard total > 1 else { return nil }
        return "\(index + 1) of \(total)"
    }

    /// Keeps a browse position inside the queue as it changes underneath.
    ///
    /// The queue is live: a proposal can arrive or be withdrawn while the user
    /// is reading one. Without clamping, deciding the last of three leaves the
    /// index past the end and the sheet renders nothing at all.
    static func clampedQueueIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }

    // MARK: - Layout

    /// How tall the single body scroll is allowed to get.
    ///
    /// The sheet grows to fit its content and only this cap stops a giant
    /// payload from sizing the window past the screen. The target is 80% of the
    /// screen, but the header, callout, acknowledgment and buttons live outside
    /// this scroll, so on a short display we also keep `reservedChrome` points
    /// free for them: without that floor a tall payload could push the pinned
    /// buttons below the bottom of the screen, which is the one control that
    /// must always be reachable. On a large display the 80% target wins.
    static func bodyMaxHeight(screenHeight: CGFloat) -> CGFloat {
        // Raised from 340 when the capability chip row replaced the one-line
        // prose summary in the header. The prose was capped at two 11pt lines;
        // a wrapping chip row on a secrets-heavy action plausibly reaches three
        // lines plus its "plus anything else the command does" tail, so the
        // header band grew and the floor that keeps Approve on screen has to
        // grow with it. Approve is the one control that must always be
        // reachable, so this errs high.
        let reservedChrome: CGFloat = 380
        let byFraction = screenHeight * 0.8
        let byChrome = screenHeight - reservedChrome
        return max(240, min(byFraction, byChrome))
    }

    // MARK: - Toasts

    /// Arrival is passive: one toast, no window, no focus steal.
    static func arrivalToast(client: String?, isUpdate: Bool) -> String {
        let author = client ?? unknownAuthor
        return isUpdate
            ? "\(author) proposed a change to an action"
            : "\(author) proposed a new action"
    }

    static func approvedToast(isUpdate: Bool) -> String {
        isUpdate ? "Action updated" : "Action added"
    }

    /// Shown when a proposal stopped applying while it waited: the action it
    /// patches was edited or deleted, or its id is now taken. Distinct from
    /// the arrival copy, which would tell the user something just came in when
    /// what actually happened is that their own click was refused.
    static let refusedToast = "That proposal no longer applies. It was set aside and won't run."

    /// Shown when the proposal file changed on disk between the user reading
    /// the card and clicking a decision. Without this the click is a silent
    /// no-op, the natural response is to click again, and the second click
    /// approves content the user never consciously re-read.
    static let reloadedToast = "This proposal changed since you read it. Nothing was decided; review the new version."

    // MARK: - Provenance

    /// "Claude Code · today 14:32", the title's subtitle. The "New action" /
    /// "Update" prefix in the title already says what happened, so the subtitle
    /// drops the "Proposed by" lead-in and just answers who and when. Time
    /// formatting follows the user's locale (12h or 24h); the day is relative
    /// because "when did this arrive" is the only question this line answers.
    static func provenanceSubtitle(
        client: String?,
        authoredAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = formatter.string(from: authoredAt)

        let day: String
        if calendar.isDate(authoredAt, inSameDayAs: now) {
            day = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(authoredAt, inSameDayAs: yesterday) {
            day = "yesterday"
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = locale
            dayFormatter.timeZone = timeZone
            dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")
            day = dayFormatter.string(from: authoredAt)
        }

        return "\(client ?? unknownAuthor) · \(day) \(time)"
    }

    /// The badge on an authored row in the shortcuts list, still answering
    /// "where did this come from" weeks later. `nil` for anything the user
    /// wrote themselves.
    static func provenanceBadge(for provenance: ActionProvenance?) -> String? {
        guard let provenance else { return nil }
        switch provenance.source {
        case .mcp:
            return "via \(provenance.client ?? unknownAuthor)"
        case .inApp:
            return "via Cai"
        }
    }

    // MARK: - Payload

    /// VoiceOver label for the payload block. The type has to be spoken: the
    /// difference between a prompt and a shell command is the whole decision.
    static func payloadLabel(for type: CaiActionType) -> String {
        switch type {
        case .prompt: return "Prompt this action will send"
        case .url: return "URL this action will open"
        case .shell: return "Shell command this action will run"
        }
    }

    // MARK: - Chain expansion

    /// One row per chain step, with referenced names resolved to what they
    /// actually are. A step reading "Slack" tells the user nothing; "Slack,
    /// webhook destination" tells them their selection leaves the Mac.
    struct ChainStepDisplay: Equatable, Identifiable {
        let index: Int
        let label: String
        let kind: String

        var id: Int { index }
    }

    static func chainSteps(_ steps: [ChainStep], known: KnownActions) -> [ChainStepDisplay] {
        steps.enumerated().map { index, step in
            ChainStepDisplay(index: index, label: step.displayLabel, kind: kind(of: step, known: known))
        }
    }

    private static func kind(of step: ChainStep, known: KnownActions) -> String {
        switch step {
        case .inlineLLM:
            return "Inline AI step"
        case .appleShortcut:
            return "Apple Shortcut"
        case .action(let name):
            switch known.resolveChainName(name) {
            case .shortcut(let shortcut):
                return "\(shortcut.type.label) action"
            case .destination(let destination):
                // By role for Cai's own built-ins. Labelling these by kind read
                // "AppleScript destination" on the row for Save to Notes, while
                // the chip above said a bounded "Writes to Notes" and — since
                // built-ins stopped escalating — no callout appeared at all. A
                // reader seeing "AppleScript destination" with no warning would
                // reasonably conclude one had been missed. Same fact, one
                // vocabulary.
                if let role = destination.builtInRole {
                    return "\(builtInRoleLabel(role)) destination"
                }
                return "\(destinationLabel(destination.kind)) destination"
            case .builtIn:
                return "Built-in action"
            case .unresolved:
                return "Not installed"
            }
        }
    }

    private static func builtInRoleLabel(_ role: BuiltInDestinationRole) -> String {
        switch role {
        case .mailDraft: return "Mail"
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        case .replaceSelection: return "Replace Selection"
        case .clipboard: return "Copy to Clipboard"
        case .showInCai: return "Show in Cai"
        }
    }

    private static func destinationLabel(_ kind: DestinationSummary.Kind) -> String {
        switch kind {
        case .applescript: return "AppleScript"
        case .webhook: return "Webhook"
        case .deeplink: return "Deeplink"
        case .shell: return "Shell"
        case .pasteBack: return "Replace Selection"
        case .clipboardCopy: return "Copy to Clipboard"
        case .showInCai: return "Show in Cai"
        }
    }

    // MARK: - Action summary

    /// One plain line saying what the action does, in Cai's own voice.
    ///
    /// Built only from what Cai can verify and will itself run: the action's
    /// type and its resolved chain. Deliberately NOT the agent's own words and
    /// NOT a model summary of the payload. A description on an approval surface
    /// must be something the sheet can vouch for, or it becomes a friendly
    /// sentence that disagrees with the code ("just formats text" over an
    /// `rm -rf`). This is the macOS model: the system says "wants to access
    /// your Contacts" from the entitlement, not from the app's marketing copy.
    /// It answers "what does this do" at the mechanism level, which is exactly
    /// the level an approval decision is made at.
    /// `promptModel` folds the engine ("Built-in", "Anthropic", …) into the
    /// prompt clause so the sheet does not also carry a separate "Runs with"
    /// line saying the same thing. It is privacy-relevant, not decoration: it
    /// is the difference between the selection staying on device and it leaving
    /// for a cloud provider.
    static func actionSummary(
        type: CaiActionType, steps: [ChainStep], known: KnownActions, promptModel: String? = nil
    ) -> String {
        var phrase = summaryBasePhrase(for: type, promptModel: promptModel)
        let tail = steps.map { summaryStepPhrase(of: $0, known: known) }
        if !tail.isEmpty {
            phrase += ", then " + tail.joined(separator: ", then ")
        }
        return phrase + "."
    }

    private static func summaryBasePhrase(for type: CaiActionType, promptModel: String?) -> String {
        switch type {
        case .prompt:
            if let promptModel, !promptModel.isEmpty {
                return "Sends a prompt to the \(promptModel) model"
            }
            return "Sends a prompt to your model"
        case .url: return "Opens a URL"
        case .shell: return "Runs a shell command"
        }
    }

    private static func summaryStepPhrase(of step: ChainStep, known: KnownActions) -> String {
        switch step {
        case .inlineLLM:
            return "runs an AI step"
        case .appleShortcut:
            return "runs an Apple Shortcut"
        case .action(let name):
            switch known.resolveChainName(name) {
            case .shortcut(let shortcut):
                switch shortcut.type {
                case .prompt: return "runs another prompt"
                case .url: return "opens a URL"
                case .shell: return "runs a shell command"
                }
            case .destination(let destination):
                return summaryDestinationPhrase(destination.kind)
            case .builtIn:
                return "runs a built-in action"
            case .unresolved:
                return "triggers an action that isn't installed yet"
            }
        }
    }

    private static func summaryDestinationPhrase(_ kind: DestinationSummary.Kind) -> String {
        switch kind {
        case .applescript: return "runs an AppleScript"
        case .webhook: return "sends to a webhook"
        case .deeplink: return "opens a deeplink"
        case .shell: return "runs a shell command"
        case .pasteBack: return "replaces your selection"
        case .clipboardCopy: return "copies to the clipboard"
        case .showInCai: return "shows the result in Cai"
        }
    }

    // MARK: - Capability chips

    /// One capability as it renders: a label, plus whether part of it is an
    /// identifier that takes the monospace treatment.
    ///
    /// Chips are Cai's own factual claims, derived by `CapabilityDetector` from
    /// the action alone. They are an unordered bag stating what the action
    /// reaches, NOT the order it reaches things in — the numbered chain block
    /// below the payload remains the ordered evidence, and must not be dropped
    /// on the grounds that the chips cover it.
    ///
    /// These replace the prose mechanism line on the sheet rather than sitting
    /// beside it (design review, 2026-08-21, option B). The deciding argument
    /// was band count, not duplication: the header already carries the name, the
    /// provenance and a type chip, and a fourth claim saying what the prose line
    /// said is the noun sprawl the CPO review flagged. `actionSummary` survives
    /// as this row's VoiceOver string and as the one-line plain-text fallback.
    struct CapabilityChip: Equatable, Identifiable {
        let label: String
        /// The identifier inside the label, if any — a secret name. Rendered in
        /// SF Mono per the typography rule, at the chip's own size.
        let identifier: String?

        var id: String { label + (identifier ?? "") }
    }

    /// The engine a model step runs on, folded into the AI chip's label.
    ///
    /// Privacy-relevant, not decoration: it is the difference between the
    /// selection staying on device and it leaving for a cloud provider. The
    /// configured engine is app state rather than a property of the action, so
    /// the detector cannot know it and the label takes it as a parameter. Option
    /// B would otherwise have deleted a fact the prose line carried.
    struct AIEngine: Equatable {
        let name: String
        let isOnDevice: Bool
        /// True for the two engines that run in-process with no endpoint at
        /// all (the built-in MLX model, Apple Intelligence). A loopback server
        /// is still on-device, but it is a named server the user configured, and
        /// naming it is the recall value.
        var isInProcess: Bool = false
    }

    static func chip(for capability: Capability, engine: AIEngine?) -> CapabilityChip {
        switch capability {
        case .runsShellCommand:
            return CapabilityChip(label: "Runs a shell command", identifier: nil)
        case .runsAppleScript:
            return CapabilityChip(label: "Runs an AppleScript", identifier: nil)
        case .runsAppleShortcut:
            return CapabilityChip(label: "Runs a Shortcut", identifier: nil)
        case .runsUninstalled(let name):
            // Names the step and reuses the phrase the callout and the chain
            // block already use. "Chains to something Cai can't see" was
            // authoring jargon that also dropped the name the case carries,
            // while the secrets chip shows its name.
            //
            // Capped as well as stripped. This is the one chip label carrying
            // attacker-controlled text, and the validator only normalizes the
            // PROPOSED side: the stored `before` action reaches the sheet
            // un-normalized and `ExtensionParser` keeps chain-step text raw. The
            // chip row lives in the header band, which — unlike the body — has
            // no height cap, so an unbounded name would grow the window and
            // could push the callout and Approve off the bottom of the screen.
            // Same cap and reasoning as `windowTitle`.
            return CapabilityChip(label: "Runs \(cappedName(name)) (not installed)", identifier: nil)
        case .sendsToHost(let host):
            return CapabilityChip(label: "Sends to \(host)", identifier: nil)
        case .opensHost(let host):
            return CapabilityChip(label: "Opens \(host)", identifier: nil)
        case .opensScheme(let scheme):
            return CapabilityChip(label: "Opens \(scheme)://", identifier: nil)
        case .sendsToUnknownHost:
            // Deliberately vaguer than every other chip, because the vagueness
            // is the fact: the address is built at runtime, so Cai will not
            // name one it cannot verify.
            return CapabilityChip(label: "Sends somewhere Cai can't name", identifier: nil)
        case .usesSecret(let name):
            // "Uses secret", not bare "Uses": every other chip is
            // self-explanatory, and someone who has not met Cai's secrets
            // feature cannot tell that SLACK_WEBHOOK is one.
            return CapabilityChip(label: "Uses secret", identifier: name)
        case .runsAI:
            guard let engine else {
                return CapabilityChip(label: "Runs an AI step", identifier: nil)
            }
            // One verb rule: "sends" means the selection leaves the Mac. A
            // cloud model is a network destination and says so in the same
            // words a webhook does.
            let label: String
            if !engine.isOnDevice {
                label = "Sends to \(engine.name)"
            } else if engine.isInProcess {
                label = "Runs on-device AI"
            } else {
                // A local server is on-device but it is still a named thing the
                // user pointed Cai at, and "on-device AI" alone loses which one.
                label = "On-device AI via \(engine.name)"
            }
            return CapabilityChip(label: label, identifier: nil)
        case .opensMailDraft:
            return CapabilityChip(label: "Opens a Mail draft", identifier: nil)
        case .writesTo(let app):
            return CapabilityChip(label: "Writes to \(app)", identifier: nil)
        case .replacesSelection:
            return CapabilityChip(label: "Replaces your selection", identifier: nil)
        case .copiesToClipboard:
            return CapabilityChip(label: "Copies to the clipboard", identifier: nil)
        }
    }

    /// One bounded line of attacker-controlled text: control characters removed
    /// so it cannot fake structure, length capped so it cannot resize the sheet.
    private static func cappedName(_ name: String) -> String {
        String(oneLine(name).prefix(ActionSchema.maxNameLength))
    }

    static func chips(for capabilities: [Capability], engine: AIEngine?) -> [CapabilityChip] {
        capabilities.map { chip(for: $0, engine: engine) }
    }

    /// The row's own admission that it cannot be complete, or nil when it can.
    ///
    /// Plain text, not a chip: this is the row's epistemics, not a capability.
    /// The copy is derived from the CAUSE, because `isExhaustive` clears for
    /// three different reasons and "that command" is false for two of them. When
    /// an uninstalled step is the only cause, the "(not installed)" chip already
    /// says it and this returns nil rather than repeating it.
    static func capabilityTail(for capabilities: [Capability]) -> String? {
        // Driven off the first open-ended member of an already-sorted list
        // rather than a chain of `contains` checks in a hand-kept order. The
        // two used to be able to drift: the checks encoded their own priority,
        // and a capability could be open-ended with no branch here at all,
        // leaving the row non-exhaustive but silent about it.
        guard let cause = capabilities.first(where: \.isOpenEnded) else { return nil }
        switch cause {
        case .runsShellCommand:
            return "plus anything else the command does"
        case .runsAppleScript:
            return "plus anything else the script does"
        case .runsAppleShortcut:
            return "plus whatever the Shortcut does"
        case .sendsToUnknownHost:
            // The chip says Cai can't name the address; the tail says why the
            // reader should look at the payload for it.
            return "the address is built when it runs — read it above"
        case .runsUninstalled:
            // The "(not installed)" chip already states it; a tail would be the
            // same fact twice.
            return nil
        default:
            // Unreachable while `isOpenEnded` is exhaustive — the compiler stops
            // a new case there first, and its doc comment sends you here.
            return nil
        }
    }

    /// Height ceiling for the sheet's capability row before it scrolls.
    ///
    /// Roughly four lines of chips. Past that the row scrolls rather than
    /// growing the header, because the chip count is attacker-influenced (one
    /// per distinct secret reference) and an unbounded header pushes the pinned
    /// callout and Approve off the screen. Nothing is elided — every chip is
    /// still reachable — so the "never truncate on the sheet" rule holds.
    ///
    /// `reservedChrome` in `bodyMaxHeight` is sized against this, so the two
    /// move together.
    static let capabilityRowMaxHeight: CGFloat = 76

    /// How many chips a compact row (a list subtitle) shows before eliding.
    static let compactCapabilityLimit = 3

    /// The compact subset for a list row, and how many were left out.
    ///
    /// Honest by construction rather than by the "+N": `Capability.sortOrder`
    /// puts every open-ended capability first, so the floor chip can never be
    /// the one cut. `excluding` drops a capability a given surface already
    /// states another way — the Settings row keeps its orange unresolved-steps
    /// triangle, whose tooltip names the steps, and chip-plus-triangle would be
    /// the same fact twice in one 56pt row.
    static func compactCapabilities(
        _ capabilities: [Capability],
        excluding: (Capability) -> Bool = { _ in false }
    ) -> (shown: [Capability], hidden: Int) {
        let eligible = capabilities.filter { !excluding($0) }
        guard eligible.count > compactCapabilityLimit else { return (eligible, 0) }
        return (
            Array(eligible.prefix(compactCapabilityLimit)),
            eligible.count - compactCapabilityLimit
        )
    }

    /// "+2" for the elided remainder.
    static func compactOverflowLabel(hidden: Int) -> String? {
        hidden > 0 ? "+\(hidden)" : nil
    }

    /// The whole chip row as one spoken sentence. VoiceOver gets Cai's prose
    /// line (which option B retired visually, not semantically) followed by the
    /// row's own limits, so a screen-reader user is told exactly what a sighted
    /// reader is.
    static func capabilityAccessibilityLabel(
        summary: String, capabilities: [Capability], engine: AIEngine?
    ) -> String {
        var spoken = summary
        let labels = chips(for: capabilities, engine: engine).map { chip in
            chip.identifier.map { "\(chip.label) \($0)" } ?? chip.label
        }
        if !labels.isEmpty {
            spoken += " Touches: " + labels.joined(separator: ", ") + "."
        }
        if let tail = capabilityTail(for: capabilities) {
            spoken += " " + tail.prefix(1).uppercased() + tail.dropFirst() + "."
        }
        return spoken
    }

    // MARK: - Payload folding

    /// Line count past which a long prompt payload renders collapsed.
    static let payloadFoldThreshold = 18

    /// Whether the payload should render folded, and the total line count for
    /// the "Show more (N lines)" affordance, or nil to render it in full.
    ///
    /// Only prompt payloads ever fold. Shell and URL are executable evidence
    /// and stay open at any length: a fold is a place to hide the one line that
    /// matters. A prompt cannot run a command, so a long one may collapse for
    /// legibility, but only when it carries no risk: a risk-flagged payload
    /// auto-expands so the thing the callout is about is never behind a fold.
    /// The count is logical lines, which is also honest signal in the label.
    static func collapsedPayload(
        type: CaiActionType, value: String, hasRisks: Bool
    ) -> (lineLimit: Int, totalLines: Int)? {
        guard type == .prompt, !hasRisks else { return nil }
        let total = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard total > payloadFoldThreshold else { return nil }
        return (payloadFoldThreshold, total)
    }

    /// "Show more (142 lines)" — the count is why the reader might want the
    /// rest, so it rides in the control.
    static func showMorePayload(totalLines: Int) -> String {
        "Show more (\(totalLines) lines)"
    }

    static let showLessPayload = "Show less"

    // MARK: - Update diff

    /// One changed field, old value beside new. Only fields the patch touched
    /// appear, so the user reads the change rather than re-reading the action.
    struct DiffRow: Equatable, Identifiable {
        let field: ActionField
        let label: String
        let before: String
        let after: String

        var id: String { field.rawValue }
    }

    static func diffRows(before: ActionSnapshot, after: ActionSnapshot, changed: [ActionField]) -> [DiffRow] {
        changed.map { field in
            DiffRow(
                field: field,
                label: fieldLabel(field),
                before: before.rendered(field),
                after: after.rendered(field)
            )
        }
    }

    // MARK: - The action as a document

    /// The whole action as text, for diffing an update.
    ///
    /// Shaped like the YAML Cai already uses for sharing an action, because
    /// that is the one serialized form a user may have seen. It is a *display*
    /// rendering and nothing parses it back: the stored action is a struct,
    /// and inventing a round-trippable format here would risk the sheet
    /// showing something subtly different from what gets saved, which is the
    /// one mistake this surface cannot make.
    ///
    /// Every field is always present, including the flags. An update that
    /// flips `type` from prompt to shell leaves `value` untouched while
    /// completely changing what it does, so the payload has to stay on screen
    /// beside the change rather than being filtered out as unmodified.
    /// Gutter for lines belonging to the value block.
    ///
    /// Not the two-space indent YAML would use. `value` is the one field that
    /// legitimately keeps its newlines, so with a plain indent a payload line
    /// reading `- action: Copy to Clipboard` rendered *byte-identical* to a
    /// real chain step, in the same font, with the same diff tint, directly
    /// above the real `next:` block. A payload could therefore draw flags and
    /// chain steps the action does not have, on the one surface whose whole job
    /// is to not be misread. A visible gutter cannot be confused with `- `,
    /// and it reads as continuation rather than structure.
    static let documentBlockGutter = "│ "

    static func renderDocument(_ action: ActionSnapshot) -> String {
        var lines: [String] = [
            "name: \(oneLine(action.name))",
            "type: \(action.type.rawValue)",
            "pinned: \(action.pinned)",
            "autoReplaceSelection: \(action.autoReplaceSelection)",
            "runInBackground: \(action.runInBackground)",
        ]

        // Block scalar, so a multi-line command keeps its shape and every line
        // of it takes part in the diff.
        //
        // Split on every line break, not just `\n`. `Text` breaks on U+2028
        // and U+2029 too, and `components(separatedBy: "\n")` does not, so a
        // value carrying one would get a single gutter and render as two
        // lines, the second unmarked and starting where structure lines start.
        // Splitting here gives every rendered line its own gutter.
        lines.append("value: |")
        for line in action.value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines.append("\(documentBlockGutter)\(line)")
        }

        if action.next.isEmpty {
            lines.append("next: []")
        } else {
            lines.append("next:")
            for step in action.next {
                switch step {
                case .action(let name): lines.append("  - action: \(oneLine(name))")
                case .inlineLLM(let directive): lines.append("  - llm: \(oneLine(directive))")
                case .appleShortcut(let name): lines.append("  - apple_shortcut: \(oneLine(name))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Collapses a field that must occupy exactly one rendered line.
    ///
    /// `ActionValidator.normalize` already strips control characters from
    /// these, but it only ever sees the *proposed* side. The `before` side is
    /// the stored action, handed over by `CaiSettings.knownActions` as a plain
    /// mapping with no normalization, and `ExtensionParser` stores names and
    /// chain-step text raw. So a clipboard-installed extension can put a
    /// newline into a field that this function then renders, and one field
    /// would become several lines at column zero: fabricated structure in the
    /// diff the user is reading to decide. Escaping here rather than trusting
    /// the caller keeps that guarantee inside the function that needs it.
    private static func oneLine(_ text: String) -> String {
        text.strippingControlCharacters(keepingNewlines: false)
    }

    // MARK: - Line diff

    /// One rendered line of a unified diff, in the shape every developer
    /// already knows: old and new line numbers, a marker, tinted rows.
    struct DiffLine: Equatable, Identifiable {
        enum Kind: Equatable {
            case context
            case removed
            case added
        }

        let id: Int
        let kind: Kind
        let text: String
        /// Line number on the old side, absent for additions.
        let oldNumber: Int?
        /// Line number on the new side, absent for removals.
        let newNumber: Int?

        var marker: String {
            switch kind {
            case .context: return " "
            case .removed: return "−"
            case .added: return "+"
            }
        }
    }

    /// A unified line diff over the whole value, nothing hidden.
    ///
    /// No collapsing: on an approval surface, "N unchanged lines" is a claim
    /// the user has to take on trust, and the whole point of this sheet is
    /// that nothing about the payload is taken on trust. The view scrolls
    /// instead.
    static func lineDiff(before: String, after: String) -> [DiffLine] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")

        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }

        // Walk both sides in step, emitting removals at their old offsets and
        // insertions at their new ones, numbering each side as it advances.
        var lines: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if let removed = removals[oldIndex] {
                lines.append(DiffLine(
                    id: lines.count, kind: .removed, text: removed,
                    oldNumber: oldIndex + 1, newNumber: nil
                ))
                oldIndex += 1
            } else if let inserted = insertions[newIndex] {
                lines.append(DiffLine(
                    id: lines.count, kind: .added, text: inserted,
                    oldNumber: nil, newNumber: newIndex + 1
                ))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                lines.append(DiffLine(
                    id: lines.count, kind: .context, text: old[oldIndex],
                    oldNumber: oldIndex + 1, newNumber: newIndex + 1
                ))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }

        return lines
    }

    static func fieldLabel(_ field: ActionField) -> String {
        switch field {
        case .name: return "Name"
        case .type: return "Type"
        case .value: return "Value"
        case .autoReplaceSelection: return "Replace selection"
        case .runInBackground: return "Run in background"
        case .pinned: return "Pinned"
        case .next: return "Chain"
        }
    }
}
