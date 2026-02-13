# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What is Cai?

Native macOS menu bar clipboard manager (SwiftUI + AppKit). User presses **Option+C** anywhere, Cai detects the clipboard content type and shows context-aware actions powered by local LLMs. Privacy-first — no cloud, no telemetry, everything runs locally.

## Build & Run

```bash
cd Cai
open Cai.xcodeproj
# Select "Cai" scheme → "My Mac" → Cmd+R
```

Or via command line:

```bash
# Debug build
xcodebuild -scheme Cai -configuration Debug build

# Release archive (for DMG)
xcodebuild -scheme Cai -configuration Release archive -archivePath /tmp/Cai.xcarchive

# Run tests
xcodebuild -scheme Cai -configuration Debug test
```

## Project Structure

```
Cai/Cai/
├── CaiApp.swift                # @main entry, delegates to AppDelegate
├── AppDelegate.swift           # Menu bar icon, hotkey, popover, lifecycle
├── CaiNotifications.swift      # Custom notification constants
├── Models/
│   ├── ActionItem.swift        # ActionItem, ActionType, LLMAction enums
│   ├── CaiSettings.swift       # UserDefaults-backed settings (singleton)
│   ├── CaiShortcut.swift       # User-defined shortcut model
│   ├── OutputDestination.swift # Destination model, DestinationType, WebhookConfig, SetupField
│   └── BuiltInDestinations.swift # Pre-defined destinations (Email, Notes, Reminders)
├── Services/
│   ├── WindowController.swift  # Floating panel, keyboard routing, event monitors
│   ├── ClipboardService.swift  # CGEvent Cmd+C simulation + pasteboard read
│   ├── ContentDetector.swift   # Priority-based content type detection
│   ├── ActionGenerator.swift   # Generates actions per content type + appends destinations
│   ├── LLMService.swift        # Actor-based OpenAI-compatible API client
│   ├── OutputDestinationService.swift # Actor-based executor for all destination types
│   ├── SystemActions.swift     # URL, Maps, Calendar ICS, Search, Clipboard
│   ├── HotKeyManager.swift     # Global Option+C registration
│   ├── ClipboardHistory.swift  # Last 9 unique clipboard entries
│   ├── UpdateChecker.swift     # GitHub release version check (24h interval)
│   └── PermissionsManager.swift # Accessibility permission check/polling
└── Views/
    ├── ActionListWindow.swift  # Main UI — routes between all screens
    ├── ActionRow.swift         # Single action row component
    ├── ResultView.swift        # LLM response display (loading/error/success)
    ├── CustomPromptView.swift  # Free-form LLM prompt (two-phase: input → result)
    ├── SettingsView.swift      # Preferences panel
    ├── ShortcutsManagementView.swift  # Create/edit custom shortcuts
    ├── DestinationsManagementView.swift # Create/edit output destinations
    ├── DestinationChip.swift   # Destination button for result/custom prompt views
    ├── ClipboardHistoryView.swift     # Last 9 entries view
    ├── OnboardingPermissionView.swift # First-launch accessibility permission guide
    ├── CaiColors.swift         # Color theme constants
    ├── CaiLogo.swift           # SVG→SwiftUI Shape for menu bar icon
    ├── KeyboardHint.swift      # Footer keyboard shortcut labels
    ├── ToastWindow.swift       # Pill notification ("Copied to Clipboard")
    ├── AboutView.swift         # About window
    └── VisualEffectBackground.swift  # NSVisualEffectView wrapper
```

## Core Flow

```
Option+C → AppDelegate.handleHotKeyTrigger()
  → Capture frontmost app name (sourceApp)
  → ClipboardService.copySelectedText() [CGEvent Cmd+C simulation]
  → ContentDetector.detect() → ContentResult (type + entities)
  → ActionGenerator.generateActions() → [ActionItem] (includes action-list destinations)
  → WindowController.showActionWindow(text, detection, sourceApp)
    → ActionListWindow (SwiftUI) shown in CaiPanel
```

## Output Destinations

Output destinations define where to send text after an LLM action (or directly from the action list).

### Built-in Destinations (zero-config, AppleScript)
- **Email** — opens Mail.app with a new draft containing the text
- **Save to Notes** — creates a new note in Notes.app (auto-converts to HTML for formatting)
- **Create Reminder** — adds a reminder to the default list (disabled by default)

### Custom Destination Types
Users can create custom destinations via Settings → Output Destinations:
- **Webhook** — HTTP POST/PUT/PATCH with JSON body template
- **AppleScript** — arbitrary AppleScript with `{{result}}` placeholder
- **URL Scheme** — deep links (e.g. `bear://x-callback-url/create?text={{result}}`)
- **Shell Command** — terminal command; text passed via `{{result}}` and stdin

### Template Placeholders
- `{{result}}` — the clipboard/LLM-processed text (auto-escaped per destination type)
- `{{field_key}}` — value from a setup field (e.g. `{{api_key}}`)

### Text Escaping Per Destination Type
`OutputDestinationService` handles escaping automatically:
- **AppleScript** — backslash, quotes, newlines escaped for AppleScript strings. Notes.app gets HTML conversion (`\n` → `<br>`) since it expects HTML for the `body` property.
- **Webhook** — `JSONEncoder` for proper JSON string escaping (handles all special chars, unicode, control chars). Body template newlines collapsed (TextEditor artifact). Text trimmed of leading/trailing whitespace.
- **URL Scheme** — percent-encoded via `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`
- **Shell** — raw text in template + piped as stdin

### "Show in Action List"
Destinations with `showInActionList: true` appear as direct-route actions (skip LLM step). They're appended by `ActionGenerator` and deduplicated by UUID.

## Bundle IDs

| Build | Bundle ID | Purpose |
|-------|-----------|---------|
| Debug (Xcode Run) | `com.soyasis.cai.dev` | Separate accessibility entry for dev |
| Release (Archive/DMG) | `com.soyasis.cai` | Production |

This prevents debug builds from resetting production accessibility permissions.

## Key Architecture Patterns

### No Sandbox
Required for CGEvent posting and global hotkey. The app needs Accessibility permission.

### CGEvent Private Event Source
When Option+C fires, the Option key is physically held. To simulate clean Cmd+C, we use `CGEventSource(stateID: .privateState)` to isolate from physical modifier state.

### Notification-Based Keyboard Routing
WindowController's local event monitor intercepts all keyboard events and posts notifications (`caiEscPressed`, `caiEnterPressed`, `caiArrowUp`, etc.). SwiftUI views subscribe via `.onReceive()`. This bridges the AppKit event system to SwiftUI.

### CaiPanel (NSPanel subclass)
Standard NSPanel can't become key window. `CaiPanel` overrides `canBecomeKey` to enable keyboard input.

### PassThrough Flag
When `TextEditor` is active (custom prompt input, destination forms), `WindowController.passThrough = true` lets Enter and arrow keys pass through to the text editor instead of being intercepted.

### acceptsFilterInput Flag
When `true`, typed characters are appended to `selectionState.filterText` for type-to-filter. Set to `false` when non-action screens are active (settings, history, destinations, etc.).

### Actor-Based Services
`LLMService` and `OutputDestinationService` are both Swift actors for thread safety. LLMService communicates with OpenAI-compatible `/v1/chat/completions` endpoint. OutputDestinationService executes destinations (webhooks, AppleScript, URL schemes, shell commands).

### Window Resume Cache
Dismissed windows are cached for 10 seconds. If reopened with the same clipboard text, the previous state (result view, custom prompt) is restored instead of creating a new window.

### LazyVStack Row Identity
Action list rows use `.id(action.id)` (not index-based). This prevents SwiftUI from showing stale cached content when the filtered list changes.

### Type-to-Filter Word Matching
Filter matches any word in the action title by prefix. "note" matches "Save to **Note**s", but "ote" matches nothing. Implemented via `anyWordHasPrefix()` which splits on spaces and checks `hasPrefix` on each word.

## Tests

```bash
xcodebuild -scheme Cai -configuration Debug test
```

Tests are in `Cai/CaiTests/ContentDetectorTests.swift` — 40+ test cases covering all content types, edge cases, priority ordering, and international address formats.

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

### Building a DMG

See `_docs/BUILD-DMG.md` for the full process. Key points:
- Background image: `_docs/dmg-assets/extension-icon.png`
- `.DS_Store` from previous DMG preserves window layout
- Upload via `gh release upload v1.0.0 Cai-1.0.0-macos.dmg --clobber`

## Important Gotchas

- **Never use `.id(index)` on LazyVStack rows** — use `.id(action.id)` to prevent stale cached views when filtering
- **KeyEventHostingView should NOT have an `onKeyDown` handler** — the local event monitor handles everything; adding `keyDown` causes double-handling
- **Filter uses word-prefix matching** — `anyWordHasPrefix()` splits title on spaces, checks `hasPrefix` per word. "note" matches "Save to Notes", "ote" does not.
- **Always reset `selectionState.filterText`** when navigating away from the action list
- **`passThrough` must be set/unset** when entering/leaving TextEditor screens (custom prompt, destination forms)
- **Don't use App Sandbox** — CGEvent posting requires it to be disabled
- **Accessibility permission polling** stops once granted — uses `startPollingForPermission()` on launch, timer invalidates on grant
- **Notes.app expects HTML** — the `body` property takes HTML, not plain text. `OutputDestinationService` auto-converts via `plainTextToHTML()` when targeting Notes.
- **Webhook JSON escaping uses JSONEncoder** — not manual string replacement. `JSONEncoder().encode(text)` handles all edge cases. Strip outer quotes since the template provides them.
- **Destination deduplication** — `ActionGenerator` uses a `seenDestIDs` set to prevent the same destination UUID from appearing twice in the action list.

## Dependencies

- **HotKey** (SPM): [soffes/HotKey](https://github.com/soffes/HotKey) v0.2.0+ — global keyboard shortcut
- **macOS 13.0+** (Ventura) deployment target

## Style Guide

- SwiftUI for views, AppKit for window management and system integration
- Singletons for services (`CaiSettings.shared`, `LLMService.shared`, `OutputDestinationService.shared`, `PermissionsManager.shared`, etc.)
- `@Published` properties with `didSet` for UserDefaults persistence
- Notification-based communication between AppKit and SwiftUI layers
- SF Symbols for all icons
- Color constants in `CaiColors.swift` (system colors, supports light/dark)
- Concise commit messages describing the "why" not the "what"
