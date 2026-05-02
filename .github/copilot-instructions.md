# Cai — Copilot Review Instructions

Native macOS menu bar clipboard manager (SwiftUI + AppKit, macOS 14+, Apple Silicon). Privacy-first: no cloud, no telemetry.

Every rule here should be verifiable from a diff. If a rule fires, say *why* and cite the file/line. Be terse — one-line review comments, no essays.

---

## Basics (merge-blocking)

- PR must build: `xcodebuild -scheme Cai -configuration Debug build`
- PR must pass tests: `xcodebuild -scheme Cai -configuration Debug test`
- 40+ content detection tests in `CaiTests/ContentDetectorTests.swift` — these are the regression net

---

## 🔴 Security & privacy (merge-blocking)

### Never log clipboard text, LLM prompts/output, API keys, or paths under `~`
Flag any new `print(…)`, `NSLog(…)`, `os_log(…)`, `CrashReportingService` breadcrumb, or `SentrySDK.capture*` call that includes these values — even in debug branches. The product ships with "no telemetry" as a core promise; one `print("clipboard: \(text)")` reaching Console.app breaks it.

### Never interpolate untrusted text into a shell invocation
Flag `"/bin/zsh -c \"\(text)\""` and any concatenation of clipboard/LLM text into shell command strings. Shell templates must go through the existing single-quote escaper in `OutputDestinationService` / `ActionListWindow.runShellCommand`. Raw text as a literal element in `Process.arguments` is fine; raw text inside `-c` is not.

### Never interpolate untrusted text into AppleScript source
Same rule for `NSAppleScript` / `osascript`. Use the existing AppleScript escaper (backslash, quotes, newlines). A clipboard containing `"; do shell script "curl …"` is the canonical attack.

### Deeplink substitution must use `.urlQueryAllowed`
Not `.urlPathAllowed` or `.urlFragmentAllowed`. Flag `addingPercentEncoding(withAllowedCharacters:)` with a wider set.

### Webhook/deeplink URLs must stay HTTPS
Enforced in `ExtensionParser` and the extensions repo CI. Don't weaken or add an `allowInsecure` escape hatch without a separate security review. HTTPS doesn't block SSRF to `localhost.*` cert-holders — if a PR adds new webhook destinations, consider whether private-IP blocking is warranted.

### Secrets flow through `KeychainHelper` only
Flag any `UserDefaults.set(…apiKey…)`, plist write, or JSON file write that includes tokens/PATs. Anthropic keys (`sk-ant-*`) use `cai_anthropicApiKey`, never the shared `cai_apiKey` — cross-provider key leakage risk.

### New SPM dependencies need a called-out reason in the PR description
Flag any `Package.resolved` diff that adds a new dependency (not a version bump). Every SPM dep is a code-execution vector on users' machines.

---

## 🔴 Crash risks (merge-blocking)

### No `try!`, no force unwraps outside of static-fact contexts
Acceptable: `UUID(uuidString: "00000000-…-known-literal-…")!`, `Bundle.main.url(forResource: "shipped")!`. Everywhere else (network results, pasteboard items, `NSRunningApplication.runningApplications(…).first`, MLX calls, decoder results) — flag.

### Actor boundary violations
Flag access to actor-isolated members from non-isolated contexts without `await`. Specifically: `LLMService.shared.*`, `MLXInference.shared.*`, `OutputDestinationService.shared.*`, `MCPClientService.shared.*` called synchronously from a view or AppKit callback.

### UI/AppKit calls must be on the main actor
`NSPasteboard.general`, `NSRunningApplication`, `NSApp`, `NSWindow`, `NSPanel`, `NSView` must be touched on `@MainActor`. Flag those calls from inside actor methods without `await MainActor.run { … }`.

### Prefer `Task { @MainActor in }` over `DispatchQueue.main.async`
Flag `DispatchQueue.main` in new code. The codebase uses structured concurrency; mixing GCD creates data races that only surface under load.

### Services are singletons — never instantiate a second one
`LLMService.shared`, `CaiSettings.shared`, `MLXInference.shared`, etc. Flag `LLMService()` or `CaiSettings()` in new code.

### Long-lived closures need `[weak self]`
Flag `NotificationCenter.default.addObserver(…)` closures, stored `Timer`/`DispatchSource` closures, escaping completion handlers, and `Task { self.foo(…) }` without weak capture. `Task { … }` inside a view body is especially prone to retaining the view.

### Every new observer/timer needs a teardown path
If a diff adds `scheduledTimer`, `addObserver`, or `DispatchSource.makeTimerSource`, flag the file for a corresponding `invalidate()` / `removeObserver()` / `cancel()` call.

---

## 🔴 App-wide invariants (merge-blocking)

### App Sandbox must stay disabled
CGEvent posting requires it. Flag any entitlements change that enables sandbox.

### `CGEvent`-based actions need a `PermissionsManager` accessibility preflight
Not just a post-hoc error toast. Flag new `CGEvent.post(…)` call sites without an upstream permission check.

### `ExtensionParser.allowShell` default stays `false`
Clipboard install must block shell and AppleScript. Only the curated-repo install path passes `allowShell: true`.

### Don't raise or remove `ClipboardHistory.maxTextLength` (10K chars)
Silent truncation is deliberate.

### Debug and Release bundle IDs must stay different
Debug: `com.soyasis.cai.dev`. Release: `com.soyasis.cai`. Unifying them resets production accessibility permissions for users.

---

## 🟡 Regression guards (should fix before merge)

### `@Published` mutations inside `init` do not fire `didSet`
If an `init` mutates a `@Published` property that normally persists via `didSet`, the write is dropped. Flag init-time mutations of persisted published properties; require an explicit `UserDefaults` write.

### New `BuiltInDestinations.all` entries need a seeding migration
Adding to the array alone does not reach existing users. Flag PRs that grow `all` without touching the seeding block in `CaiSettings.init()`.

### `Codable` model changes need backward-compatible decoding
New stored properties on `CaiShortcut`, `OutputDestination`, `MCPServerConfig`, or anything persisted via `CaiSettings` must either default, use `decodeIfPresent`, or ship a migration. Flag new non-optional stored properties on `Codable` types without one.

### Pasteboard snapshots must capture every item, every type
Flag any `NSPasteboard` read/restore flow that only handles `.string`. The `PasteboardSnapshot` pattern (all `pasteboardItems`, all declared types, raw `Data`) is required. Clearing without snapshot = silent data loss.

### Read-then-write sequences on the pasteboard need `changeCount` checks
If code does `read → await/asyncAfter → write`, the user may have copied something else in between. Flag sequences that don't capture `changeCount` before the async boundary and verify before overwriting.

### `ContentDetector` changes require corresponding tests
Flag PRs that touch `ContentDetector.swift` without updating `Cai/CaiTests/ContentDetectorTests.swift`. Those tests are the only regression net for detection priority.

### Don't store state in `@State` that should be in `CaiSettings`
If a value needs to survive window close/reopen or be readable from services, it belongs in `CaiSettings` (persisted via UserDefaults/Keychain), not `@State`.

### MLX `ChatSession(history:)` must not contain system messages
`instructions:` already prepends the system prompt. A system message in `history` produces incoherent output; `testIgnoresSystemMessagesInHistoryArray` locks this in. Flag any diff that bypasses `MLXInference.buildSessionInputs`.

### MLX tuning knobs to leave alone
- Don't set `MLX.Memory.memoryLimit` — hangs the process.
- Don't add `repetitionPenalty` — `1.1` corrupts Ministral 3B output.
- Don't remove `LLMService.maxMessageChars = 50_000` — OOM risk and multi-minute prefill on large pastes.
- Don't bypass the `MLXInference.isGenerating` concurrency guard.

---

## 🟡 SwiftUI / Views (should fix before merge)

### Never use `.id(index)` on `LazyVStack` rows
Use `.id(model.id)`. Index-based IDs show stale cached content when the filtered list changes.

### `KeyEventHostingView` must not have an `onKeyDown` handler
The local event monitor handles keys; adding one causes double-handling.

### `WindowController.passThrough` / `acceptsFilterInput` discipline
New screens with a `TextEditor` must set `passThrough = true` on enter, `false` on exit. Non-action screens must set `acceptsFilterInput = false` on enter. Flag diffs that introduce either screen type without both sides of the flag.

### `github.logo` / `linear.logo` are not SF Symbols
Flag `Image(systemName: "github.logo")` — use the `connectorIcon()` helper that maps to `GitHubIcon()` / `LinearIcon()`.

### Reset `selectionState.filterText` when navigating away from the action list
Flag navigations that leave filter state set.

---

## ⚪ Design tokens (nice to have)

- Colors come from `CaiColors.swift` — flag hardcoded hex, `Color(red:green:blue:)`, or raw system colors (`Color.blue`, `.gray`, `.black`, `.white`). `caiPrimary` is the only hardcoded brand color — everything else must be an NSColor-adaptive token for Light/Dark mode.
- Read `docs/design/DESIGN.md` before approving visual changes.
