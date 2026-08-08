# CLAUDE.md

Quick reference for Claude Code. Full docs map: [`_docs/INDEX.md`](_docs/INDEX.md).

## What is Cai?

Native macOS action layer (SwiftUI + AppKit). User presses **Option+C** anywhere; Cai detects the selected content type and shows context-aware actions powered by an LLM. Privacy-first, local-by-default — no telemetry; runs on-device with the built-in MLX model or Apple Intelligence. Optional cloud providers (OpenRouter, Anthropic).

## Design System

Always read [`docs/design/DESIGN.md`](docs/design/DESIGN.md) before any UI/visual work. All color tokens, type scale, spacing, radii, motion curves, and component patterns live there. In QA mode, flag any code that doesn't match it.

## Build & Run

```bash
# Dev
cd Cai && open Cai.xcodeproj    # then "Cai" scheme → "My Mac" → Cmd+R

# CLI
xcodebuild -scheme Cai -configuration Debug build
xcodebuild -scheme Cai -configuration Debug test
xcodebuild -scheme Cai -configuration Release archive -archivePath /tmp/Cai.xcarchive
```

## Project Structure (entry points)

```
Cai/Cai/
├── CaiApp.swift              # @main → AppDelegate
├── AppDelegate.swift         # Menu bar, hotkey, popover, lifecycle
├── Models/                   # ActionItem, CaiSettings, CaiShortcut, OutputDestination, BuiltInDestinations, MCPModels
├── Services/                 # Window/Clipboard/ContentDetector, LLMService + MLXInference, OutputDestinationService, MCP*, KeychainHelper, ClipboardHistory, OCRService, ExtensionParser/Service, HotKeyManager, PermissionsManager, UpdateChecker, CrashReportingService, PendingChangeStore/Watcher + ActionHistoryLog (agent proposals)
└── Views/                    # ActionListWindow (router), ActionRow, ResultView, CustomPromptView, SettingsView, ShortcutsManagementView, DestinationsManagementView, ExtensionBrowserView, MCPFormView, MCPManagementView (Client/Server tabs), ConnectorsSettingsView, ConnectAgentContent + AgentConnection (connect-agent payloads), ModelSetupView, OnboardingPermissionView, ToastWindow, ShortcutRecorderView, ActionReviewView (approval sheet), CaiColors, CaiLogo, KeyboardHint, AboutView, VisualEffectBackground

Cai/CaiActionCore/            # SPM package: authored-action schema, validator, approval tiers. Shared with the cai-mcp helper; every function pure and table-tested.
Cai/CaiMCPHelper/             # cai-mcp: the stdio MCP server agents talk to. main.swift (handshake), Tools.swift (the four tools), ToolDispatch, CaiBridge. Embedded in Contents/Helpers, symlinked into ~/Library/Application Support/Cai/bin.
```

`ls Cai/Cai/{Models,Services,Views}` for the full file list.

## Feature pointers

| Topic | See |
|---|---|
| Core flow (Option+C → detect → actions → window) | [`_docs/architecture/ARCHITECTURE.md#core-flow`](_docs/architecture/ARCHITECTURE.md#core-flow) |
| Custom shortcuts (Prompt / URL / Shell, `autoReplaceSelection`) | [`_docs/architecture/ARCHITECTURE.md#custom-shortcuts`](_docs/architecture/ARCHITECTURE.md#custom-shortcuts) |
| Output destinations (Replace Selection, Email, Notes, Reminders + Webhook/AppleScript/Deeplink/Shell) | [`_docs/architecture/ARCHITECTURE.md#output-destinations`](_docs/architecture/ARCHITECTURE.md#output-destinations) |
| Community extensions (in-app browser + clipboard YAML) | [`_docs/architecture/ARCHITECTURE.md#community-extensions`](_docs/architecture/ARCHITECTURE.md#community-extensions) |
| Built-in MLX LLM + provider routing | [`_docs/architecture/LLM.md`](_docs/architecture/LLM.md) |
| MCP connectors (GitHub, Linear) | [`_docs/architecture/MCP.md`](_docs/architecture/MCP.md), [`_docs/connectors/`](_docs/connectors/) |
| Agent-authored actions (Cai as an MCP server, `cai-mcp` helper, approval gate) | [`_docs/architecture/MCP.md#cai-as-a-server`](_docs/architecture/MCP.md#cai-as-a-server) |
| Architecture patterns (No Sandbox, CGEvent, CaiPanel, PassThrough, actors) | [`_docs/architecture/ARCHITECTURE.md#key-architecture-patterns`](_docs/architecture/ARCHITECTURE.md#key-architecture-patterns) |
| Crash reporting (Sentry, opt-in) | [`_docs/architecture/ARCHITECTURE.md#crash-reporting-sentry`](_docs/architecture/ARCHITECTURE.md#crash-reporting-sentry) |
| Bundle IDs (Debug `com.soyasis.cai.dev`, Release `com.soyasis.cai`) | [`_docs/architecture/ARCHITECTURE.md#bundle-ids`](_docs/architecture/ARCHITECTURE.md#bundle-ids) |

## Tests

```bash
xcodebuild -scheme Cai -configuration Debug test
```

`Cai/CaiTests/` — `ContentDetectorTests` covers 40+ cases across all content types. Other suites cover `ActionGenerator`, `OutputDestinationService`, MCP parsing/transport, `ChainExecutor`, `TemplateEngine`.

### Testability discipline

Extract decision logic out of views, the key monitor, and AppKit glue into pure, nonisolated static functions, and cover them with table-driven XCTests. Logic that lives inline in event handlers ships unverified and only breaks in the real app. Exemplars: `WindowController.returnSubmitsPrompt(...)` (tested by `EnterToSendTests`, called from both the key monitor and `MultilineTextEditor`) and `ContentDetector.detect()` (tested by `ContentDetectorTests`).

Before: `if settings.pressReturnToSend && isComposer && !mods.contains(.shift) { submit() }` buried in the key monitor. After: `if Self.returnSubmitsPrompt(pressReturnToSend:submitScreenActive:modifiers:) { submit() }` with the predicate unit-tested.

## Common Tasks

**New LLM action:** add case to `LLMAction` enum (`ActionItem.swift`) → method on `LLMService` (with `appContext`) → wire in `ActionGenerator` → handle in `ActionListWindow.executeAction()` → title in `llmActionTitle()`.

**New content type:** add case to `ContentType` (`ContentDetector.swift`) → detection logic in `detect()` (priority order matters) → action generation in `ActionGenerator` → tests in `ContentDetectorTests`.

**New built-in destination:** add `static let` with fixed UUID in `BuiltInDestinations.swift` → append to `BuiltInDestinations.all` → migration in `CaiSettings.init()` (existing users won't get new built-ins otherwise).

**New setting:** key in `CaiSettings.Keys` → `@Published` with `didSet` persistence → init in `CaiSettings.init()` → UI in `SettingsView.swift`.

**New community extension:** `extensions/<slug>/extension.yaml` in [cai-extensions](https://github.com/cai-layer/cai-extensions) starting with `# cai-extension` header → `index.json` entry. PR validation runs automatically (format, HTTPS for webhooks, author match).

**Build a DMG:** [`_docs/process/dmg-assets/BUILD-DMG.md`](_docs/process/dmg-assets/BUILD-DMG.md).

## Important Gotchas

- **The project uses file-system-synchronized folders** (Xcode 16 format): every file under `Cai/Cai` and `Cai/CaiTests` builds automatically, no pbxproj registration. Flip side: never leave scratch or experimental files in those folders; they compile into the app.
- **Never put `.onTapGesture` on a SwiftUI `List` row** — silently breaks `.onMove`. Use a trailing `Menu` or `Button`. Full bisect in [`_docs/architecture/SWIFTUI_GOTCHAS.md`](_docs/architecture/SWIFTUI_GOTCHAS.md).
- **Never use `.id(index)` on LazyVStack rows** — use `.id(action.id)` to prevent stale cached views when filtering.
- **`KeyEventHostingView` should NOT have an `onKeyDown` handler** — the local event monitor handles everything; adding `keyDown` causes double-handling.
- **Filter uses word-prefix matching** (`anyWordHasPrefix()`) — splits title on spaces, `hasPrefix` per word. "note" matches "Save to Notes"; "ote" doesn't.
- **Always reset `selectionState.filterText`** when navigating away from the action list.
- **`passThrough` must be set/unset** when entering/leaving TextEditor screens (custom prompt, destination forms).
- **Don't use App Sandbox** — CGEvent posting requires it disabled.
- **Notes.app expects HTML** — `OutputDestinationService` auto-converts via `plainTextToHTML()` for Notes.
- **Webhook JSON escaping uses `JSONEncoder`** — not manual string replacement. Strip outer quotes since the template provides them.
- **API keys go in Keychain via `KeychainHelper`**, never UserDefaults. Cloud providers (Anthropic, OpenRouter) use dedicated entries to prevent cross-provider leakage.
- **Shell shortcut escaping ≠ shell destination escaping** — Shortcuts: single-quote escaping only, no wrapping (template controls quoting). Destinations: wraps entire text in single quotes.
- **`ExtensionParser.allowShell`** — `true` for curated repo installs, `false` (default) for clipboard installs.
- **Webhook URLs must use HTTPS** — enforced in `ExtensionParser` and the GitHub Actions validator.
- **`ExtensionService` uses `reloadIgnoringLocalCacheData`** — prevents stale GitHub CDN responses.
- **Clipboard text clamped to 10K chars** (`ClipboardHistory.maxTextLength`). Silent truncation.
- **OCR via Apple Vision**, on-device (~50-200ms). Image entries use the `photo` SF Symbol (NOT `doc.text.image`).
- **Extension detection uses `# cai-extension` header** at priority 0 (before URL). Shell/AppleScript blocked from clipboard install.
- **`github.logo` and `linear.logo` are NOT SF Symbols** — they map to `GitHubIcon()` and `LinearIcon()` SwiftUI shapes via `connectorIcon()`. Never `Image(systemName: "github.logo")`.
- **Debug builds ignore `pending-changes/` unless `CAI_MCP_PENDING=1`** — both bundle IDs share Application Support, so an unguarded Debug build races the Release build for the same proposal files. Set it in the run scheme when working on agent proposals.
- **In `cai-mcp`, stdout belongs to JSON-RPC** — a stray `print` corrupts the stream and the agent disconnects. Diagnostics go to stderr via `CaiMCPHelper.log`.
- **Agent-facing guidance has two homes with different costs** — `AgentInstructions.text` rides in every request for the whole session (keep it short: when to reach for Cai, the approval boundary, the pre-proposal self-check), while `Tools.swift` descriptions are read on demand and carry the per-tool mechanics. Keep mechanics out of the instructions (`AgentInstructionsTests` fails if field names leak in); the approval boundary is deliberately stated in both, since an agent may only read one.
- **Everything read from `pending-changes/` is untrusted** — always through `ActionValidator`, re-validated at approve time; provenance `source` is forced to `.mcp` on ingest. Never trust helper-side validation.

## Dependencies

- HotKey ([soffes/HotKey](https://github.com/soffes/HotKey) v0.2.0+) — global hotkey
- Sentry ([getsentry/sentry-cocoa](https://github.com/getsentry/sentry-cocoa) v8.0.0+) — opt-in crash reporting
- Yams ([jpsim/Yams](https://github.com/jpsim/Yams) v5.0.0+) — extension YAML parsing
- Sparkle ([sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)) — auto-update
- MLX-Swift v0.31.3 + mlx-swift-lm v2.31.3 — Apple Silicon LLM inference
- macOS 14.0+ deployment target

## Style

- SwiftUI for views, AppKit for window management + system integration
- Singletons for services (`CaiSettings.shared`, `LLMService.shared`, `OutputDestinationService.shared`, `MLXInference.shared`, `ModelDownloader.shared`, `PermissionsManager.shared`, …)
- `@Published` + `didSet` for UserDefaults persistence
- Notification-based AppKit↔SwiftUI bridge
- SF Symbols for icons; color constants in `CaiColors.swift` (system colors, light/dark)
- Concise commit messages: the *why*, not the *what*

## PR sizing & review

- Ship while the diff is still reviewable line-by-line. ~300 lines is the sweet spot, ~1,000 the limit.
- Append to every review prompt (`/review`, `/codex`, etc.):
  1. **No nitpicks, no pedantic opinions, no scope creep.**
  2. **If there isn't anything major, just say so.**
  3. **Only review the diff.**
- Add `/codex` for risky paths: CGEvent / pasteboard, Keychain, MCP transport, subprocess execution, `OutputDestinationService`, `ClipboardService`.
- Every review checks the diff against the Cai risk catalog: [`_docs/process/REVIEW-CHECKLIST.md`](_docs/process/REVIEW-CHECKLIST.md) (CAI-01..26; apply only the items whose area the diff touches).
- Full doc: [`_docs/process/CODE-REVIEW.md`](_docs/process/CODE-REVIEW.md).
