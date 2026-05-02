# CLAUDE.md

Quick reference for Claude Code. For the full docs map (when to read what), see [`_docs/INDEX.md`](_docs/INDEX.md).

## Design System
Always read [`docs/design/DESIGN.md`](docs/design/DESIGN.md) before making any visual or UI decisions.
All color tokens, typography sizes, spacing, border radii, animation curves, and component patterns are defined there.
Do not deviate from the design system without explicit user approval.
In QA mode, flag any code that doesn't match DESIGN.md.

## What is Cai?

Native macOS menu bar clipboard manager (SwiftUI + AppKit). User presses **Option+C** anywhere, Cai detects the clipboard content type and shows context-aware actions powered by an LLM. Privacy-first and local-by-default — no telemetry; runs fully on-device with the built-in MLX model or Apple Intelligence. Optional cloud providers (OpenRouter, Anthropic) available for power users who want frontier-model quality.

## Build & Run

```bash
cd Cai
open Cai.xcodeproj
# Select "Cai" scheme → "My Mac" → Cmd+R
```

```bash
xcodebuild -scheme Cai -configuration Debug build      # Debug build
xcodebuild -scheme Cai -configuration Debug test        # Run tests
xcodebuild -scheme Cai -configuration Release archive -archivePath /tmp/Cai.xcarchive  # Release
```

## Project Structure

```
Cai/Cai/
├── CaiApp.swift                # @main entry, delegates to AppDelegate
├── AppDelegate.swift           # Menu bar icon, hotkey, popover, lifecycle
├── CaiNotifications.swift      # Custom notification constants
├── Models/
│   ├── ActionItem.swift        # ActionItem, ActionType (.shortcutShell, .shortcutURL, etc.), LLMAction enums
│   ├── CaiSettings.swift       # UserDefaults-backed settings (singleton), installedExtensions tracking
│   ├── CaiShortcut.swift       # User-defined shortcut model (prompt, url, shell types; prompt has optional autoReplaceSelection)
│   ├── OutputDestination.swift # Destination model, DestinationType (incl. .pasteBack), WebhookConfig, SetupField
│   ├── BuiltInDestinations.swift # Pre-defined destinations (Replace Selection, Email, Notes, Reminders)
│   └── MCPModels.swift         # MCP types: MCPServerConfig, MCPActionConfig, MCPFieldConfig, MCPError
├── Services/
│   ├── WindowController.swift  # Floating panel, keyboard routing, event monitors
│   ├── ClipboardService.swift  # CGEvent Cmd+C simulation + pasteboard read
│   ├── ContentDetector.swift   # Priority-based content type detection (URL, JSON, Address, Meeting, Word, Image, Short/Long Text)
│   ├── ActionGenerator.swift   # Generates actions per content type + appends destinations
│   ├── LLMService.swift        # Actor-based OpenAI-compatible API client
│   ├── MLXInference.swift       # Actor — in-process MLX-Swift inference on Apple Silicon
│   ├── ModelDownloader.swift   # Downloads MLX models from HuggingFace with progress
│   ├── CrashReportingService.swift # Opt-in Sentry crash reporting (privacy-first)
│   ├── OutputDestinationService.swift # Actor-based executor for all destination types
│   ├── SystemActions.swift     # URL, Maps, Calendar ICS, Search, Clipboard
│   ├── HotKeyManager.swift     # Global hotkey registration (dynamic, reads from settings)
│   ├── KeychainHelper.swift    # Lightweight macOS Keychain wrapper for secrets (API keys)
│   ├── ClipboardHistory.swift  # Last 9 unique clipboard entries (with pin support)
│   ├── OCRService.swift        # On-device image OCR via Apple Vision framework
│   ├── ExtensionParser.swift    # Parses community extension YAML into shortcuts/destinations
│   ├── ExtensionService.swift   # Fetches extension index + YAML from curated GitHub repo
│   ├── MCPClientService.swift  # Actor — MCP server connections, tool calls, metadata caching
│   ├── MCPTransportClient.swift # Thin MCP client — JSON-RPC 2.0 over HTTP, zero dependencies
│   ├── MCPConfigManager.swift  # ObservableObject — server configs, action registry, persistence
│   ├── UpdateChecker.swift     # GitHub release version check (24h interval)
│   └── PermissionsManager.swift # Accessibility permission check/polling
└── Views/
    ├── ActionListWindow.swift  # Main UI — routes between all screens
    ├── ActionRow.swift         # Single action row component
    ├── ResultView.swift        # LLM response display (loading/error/success)
    ├── CustomPromptView.swift  # Free-form LLM prompt (two-phase: input → result)
    ├── SettingsView.swift      # Preferences panel
    ├── ShortcutsManagementView.swift  # Create/edit custom actions
    ├── DestinationsManagementView.swift # Create/edit output destinations
    ├── ExtensionBrowserView.swift # Browse/search/install community extensions
    ├── MCPFormView.swift       # Generic MCP action form (text, picker, multiselect, LLM generation)
    ├── ConnectorsSettingsView.swift # MCP server management (API keys, test, toggles)
    ├── DestinationChip.swift   # Destination button for result/custom prompt views
    ├── ClipboardHistoryView.swift     # Last 9 entries view
    ├── OnboardingPermissionView.swift # First-launch accessibility permission guide
    ├── CaiColors.swift         # Color theme constants
    ├── CaiLogo.swift           # SVG→SwiftUI Shape for menu bar icon
    ├── KeyboardHint.swift      # Footer keyboard shortcut labels
    ├── ToastWindow.swift       # Pill notification ("Copied to Clipboard")
    ├── ShortcutRecorderView.swift  # Zen-style hotkey recorder (NSViewRepresentable)
    ├── ModelSetupView.swift     # First-launch model download + setup
    ├── AboutView.swift         # About window
    └── VisualEffectBackground.swift  # NSVisualEffectView wrapper
```

## Feature Overview

- **[Core flow](_docs/architecture/ARCHITECTURE.md#core-flow)**: Option+C → CGEvent Cmd+C → ContentDetector → ActionGenerator → ActionListWindow
- **[Custom actions](_docs/architecture/ARCHITECTURE.md#custom-shortcuts)**: Prompt (LLM), URL (%s), Shell ({{result}}) types. Shell runs via `/bin/zsh -c`, shows output in ResultView. Prompt-type shortcuts support an optional `autoReplaceSelection` flag that pastes the LLM result directly over the source selection, skipping the result view. (Code still uses `CaiShortcut` / `shortcuts` internally.)
- **[Output destinations](_docs/architecture/ARCHITECTURE.md#output-destinations)**: Replace Selection, Email, Notes, Reminders (built-in) + Webhook, AppleScript, Deeplink, Shell (custom). `{{result}}` placeholder, auto-escaped per type. Replace Selection pastes the result over the user's selection in the source app via simulated ⌘V.
- **[Community extensions](_docs/architecture/ARCHITECTURE.md#community-extensions)**: In-app browser (Settings → Browse) + clipboard YAML install. Curated repo: `cai-extensions`. Shell/AppleScript blocked from clipboard install.
- **[Built-in LLM](_docs/architecture/ARCHITECTURE.md#built-in-llm)**: In-process MLX-Swift inference on Apple Silicon. Auto-download Ministral 3B 4-bit from mlx-community. Curated model picker + custom HuggingFace model support. See also [`_docs/architecture/LLM.md`](_docs/architecture/LLM.md).
- **[Crash reporting](_docs/architecture/ARCHITECTURE.md#crash-reporting-sentry)**: Opt-in Sentry, disabled by default. No PII.
- **[MCP connectors](_docs/architecture/MCP.md)**: GitHub, Linear via MCP protocol. Declarative `MCPActionConfig` → generic `MCPFormView`. Config: `~/.config/cai/mcp-servers.json`. Actions always visible for enabled connectors; clicking without API key redirects to Connectors setup. Provider docs: [`_docs/connectors/`](_docs/connectors/).
- **[Architecture patterns](_docs/architecture/ARCHITECTURE.md#key-architecture-patterns)**: No Sandbox, CGEvent, CaiPanel, PassThrough, keyboard routing, actors.
- **[Bundle IDs](_docs/architecture/ARCHITECTURE.md#bundle-ids)**: Debug `com.soyasis.cai.dev`, Release `com.soyasis.cai` (separate accessibility entries).

## Tests

```bash
xcodebuild -scheme Cai -configuration Debug test
```

Tests in `Cai/CaiTests/ContentDetectorTests.swift` — 40+ cases covering all content types.

## Common Tasks

### Adding a New LLM Action
1. Add case to `LLMAction` enum in `ActionItem.swift`
2. Add method to `LLMService.swift` (with `appContext` parameter)
3. Add to `ActionGenerator.swift` for relevant content types
4. Handle in `ActionListWindow.executeAction()` switch
5. Add title in `llmActionTitle()` in `ActionListWindow.swift`

### Adding a New Content Type
1. Add case to `ContentType` in `ContentDetector.swift`
2. Add detection logic in `detect()` (respects priority order)
3. Add action generation in `ActionGenerator.swift`
4. Add tests in `ContentDetectorTests.swift`

### Adding a New Built-in Destination
1. Add static let in `BuiltInDestinations.swift` with a fixed UUID
2. Add to `BuiltInDestinations.all` array
3. Note: existing users won't get new built-ins (they loaded from persisted data). Consider a migration in `CaiSettings.init()`.

### Adding a New Setting
1. Add key to `CaiSettings.Keys`
2. Add `@Published` property with `didSet` persistence
3. Initialize in `CaiSettings.init()`
4. Add UI in `SettingsView.swift`

### Adding a New Community Extension
1. Create `extensions/<slug>/extension.yaml` in the [cai-extensions](https://github.com/cai-layer/cai-extensions) repo
2. Add entry to `index.json` with slug, name, description, author, version, icon, type, tags
3. YAML must start with `# cai-extension` header
4. PR validation runs automatically (checks format, HTTPS for webhooks, author match)

### Building a DMG
See `_docs/process/dmg-assets/BUILD-DMG.md` for the full process.

## Important Gotchas

- **Never use `.id(index)` on LazyVStack rows** — use `.id(action.id)` to prevent stale cached views when filtering
- **KeyEventHostingView should NOT have an `onKeyDown` handler** — the local event monitor handles everything; adding `keyDown` causes double-handling
- **Filter uses word-prefix matching** — `anyWordHasPrefix()` splits title on spaces, checks `hasPrefix` per word. "note" matches "Save to Notes", "ote" does not.
- **Always reset `selectionState.filterText`** when navigating away from the action list
- **`passThrough` must be set/unset** when entering/leaving TextEditor screens (custom prompt, destination forms)
- **Don't use App Sandbox** — CGEvent posting requires it to be disabled
- **Notes.app expects HTML** — `OutputDestinationService` auto-converts via `plainTextToHTML()` when targeting Notes
- **Webhook JSON escaping uses JSONEncoder** — not manual string replacement. Strip outer quotes since the template provides them.
- **API key uses Keychain, not UserDefaults** — `KeychainHelper` wraps the Security framework. Never store secrets in UserDefaults.
- **Shell shortcut escaping differs from shell destinations** — Shortcuts: single-quote escaping only, no wrapping (template controls quoting). Destinations: wraps entire text in single quotes.
- **ExtensionParser `allowShell`** — `true` for curated repo installs, `false` (default) for clipboard installs
- **Webhook URLs must use HTTPS** — enforced in both `ExtensionParser` and GitHub Actions validator
- **ExtensionService uses `reloadIgnoringLocalCacheData`** — prevents stale cached responses from GitHub CDN
- **Clipboard text clamped to 10K chars** — `ClipboardHistory.maxTextLength`. Silent truncation.
- **OCR uses Apple Vision framework** — on-device, ~50-200ms. Image entries use `photo` SF Symbol (macOS 13+, NOT `doc.text.image`).
- **Extension detection uses `# cai-extension` header** — priority 0 (before URL). Shell/AppleScript blocked from clipboard install.
- **`github.logo` and `linear.logo` are NOT SF Symbols** — they're custom identifiers mapped to `GitHubIcon()` and `LinearIcon()` SwiftUI shapes. Use `connectorIcon()` helper, never `Image(systemName:)`.

## Dependencies

- **HotKey** (SPM): [soffes/HotKey](https://github.com/soffes/HotKey) v0.2.0+ — global keyboard shortcut
- **Sentry** (SPM): [getsentry/sentry-cocoa](https://github.com/getsentry/sentry-cocoa) v8.0.0+ — opt-in crash reporting
- **Yams** (SPM): [jpsim/Yams](https://github.com/jpsim/Yams) v5.0.0+ — YAML parsing for community extensions
- **Sparkle** (SPM): [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) — auto-update framework
- **MLX-Swift** (SPM): [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) v0.31.3 — Apple Silicon ML framework
- **MLX-Swift-LM** (SPM): [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) v2.31.3 — LLM inference layer for MLX
- **macOS 14.0+** (Sonoma) deployment target

## Style Guide

- SwiftUI for views, AppKit for window management and system integration
- Singletons for services (`CaiSettings.shared`, `LLMService.shared`, `OutputDestinationService.shared`, `MLXInference.shared`, `ModelDownloader.shared`, `PermissionsManager.shared`, etc.)
- `@Published` properties with `didSet` for UserDefaults persistence
- Notification-based communication between AppKit and SwiftUI layers
- SF Symbols for all icons
- Color constants in `CaiColors.swift` (system colors, supports light/dark)
- Concise commit messages describing the "why" not the "what"
