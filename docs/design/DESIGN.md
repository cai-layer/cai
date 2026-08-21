# Design System — Cai

The single source of truth for visual rules. Update this file whenever a UI rule changes — code is the implementation, this file is the rationale and the rulebook.

For technical SwiftUI/AppKit traps, see [`_docs/architecture/SWIFTUI_GOTCHAS.md`](../../_docs/architecture/SWIFTUI_GOTCHAS.md).

---

## Aesthetic

- **Direction:** Precision Minimal (Spotlight lineage). Frosted glass does the work. No gradients, no decorative shadows, no patterns.
- **Tone:** Invisible, precise, trustworthy. A tool that earns its place in muscle memory.
- **Mental rule:** Every pixel is justified. Nothing competes for attention except the action the user is about to take.

---

## Color

**Approach:** Restrained — one accent (indigo `#6366F2`), all surfaces adaptive via NSColor.

Tokens are defined in [`CaiColors.swift`](../../Cai/Cai/Views/CaiColors.swift) — that's the source of truth for values. Use cases:

| Token | Use |
|---|---|
| `caiPrimary` | Brand accent. Hardcoded (the only hardcoded color). See "Indigo discipline" below. |
| `caiPrimarySubtle` | `caiPrimary` @ 12%. Hover/selection wash for indigo-branded interactive states. |
| `caiSuccess` / `caiError` | Apple system green / orange. Match SF Symbol semantic colors. |
| `caiBackground` / `caiSurface` | Window/control surfaces. NSColor-based — auto-adapt Light/Dark. |
| `caiTextPrimary` / `caiTextSecondary` | Primary/secondary text. NSColor-based. |
| `caiSelection` | Text selection only (system blue). Do NOT use for interactive states — use `caiPrimarySubtle`. |
| `caiDivider` | Separator hairlines. NSColor-based. |
| `caiDiffRemoved` / `caiDiffAdded` | System red / green. **Diff row tints only.** See "Red" below. |

**Never hardcode a background or text color.** All NSColor tokens auto-adapt to Light/Dark/System.

**Dark mode:** three modes (System default, Light, Dark) via `NSApp.appearance` in `CaiSettings`. NSColor tokens handle it; no overrides needed.

### Red

Cai has no red. Warnings are `caiError` (system orange), failures are stated in words, and nothing is styled as alarm. The reason is that a utility interrupting your work has not earned the right to shout.

**One exception, added 2026-08-02: diffs.** The approval sheet for agent-authored actions renders changes as a unified diff, and red-removed / green-added is a convention every developer reads without thinking. An approval surface is the wrong place to make someone learn a house dialect, so the diff uses `caiDiffRemoved` and `caiDiffAdded`.

Scope of the exception, do not widen it without a design decision:

- Row background tints only, at 12% (removed) and 14% (added). Never text, never a control, never a border.
- Only inside a diff. Errors elsewhere stay orange or textual.
- Code text stays `caiTextPrimary` on every row, including removals, so the payload is equally legible in all three states.

### Indigo discipline

`caiPrimary` signals **"I will act / I am on / I am the focus."** It's the only chromatic moment in the app — overusing it dilutes the signal.

**Use indigo for:** primary buttons (Save, `+`, Run), ON-state toggles, focused input border, pinned-state pin glyph + tinted background, header product mark, dropdown/list-row selection highlight.

**Do NOT use indigo for:** tab indicators, individual chain-step chips, list-row hover backgrounds, section headers, helper text, dividers, secondary buttons. These are *passive structure* — they describe state, they don't act.

**The mental test:** if a screenshot of this element existed in isolation, would the user expect tapping it to *do* something? Indigo means yes.

---

## Typography

**Font:** SF Pro (macOS system font). Identical feel to Spotlight, Terminal, every first-party Apple app. Zero setup.

| Role | Size | Weight | Usage |
|---|---|---|---|
| Header title | 13pt | Semibold | Screen titles |
| Body / action label | 13pt | Medium | ActionRow labels, step labels, form values |
| Body regular | 13pt | Regular | LLM output, long-form content |
| Control row label | 12pt | Medium | Toggle row labels in Settings sub-screens. One step below body so the toggle reads as the primary affordance. |
| Secondary | 11pt | Regular | Subtitles, result summaries, step result snippets |
| Footer hints | 10pt | Medium | KeyboardHint chips |
| Micro / badges | 9pt | Medium | `⌘1`–`⌘9` shortcut badges |

**Rules:**

1. **`.rounded` design variant for accent numerals only** — keyboard shortcut badges, step counts, standalone result counts ("3 found"). All other labels use default SF Pro. Rounded adds warmth at decision points.
2. **`.monospacedDigit()` on every runtime-changing number.** Prevents layout jitter when digits change width (1→2→3).
3. **Never use Dynamic Type.** macOS doesn't support it. All sizes are fixed pt.
4. **SF Mono for secret names, nowhere else** (added 2026-08-08; sizing amended 2026-08-21). A secret name is the exact string typed inside `{{secrets.…}}`, so it renders monospaced everywhere it appears: Secrets rows, the name field, import candidates, the approval callout, the delete alert, capability chips. **Size follows the containing role** — 12pt medium where the name stands on its own, and the container's own size where it sits inside one (10pt in a capability chip, 11pt in a list subtitle) — the same way radius scales with element size. The substance of this rule is the monospace, not the point size. Long names truncate `.middle` with the full name in `.help()`. This is an identifier treatment, not a general label style — do not widen it without a design decision.

---

## Window & Background

- **Material:** `NSVisualEffectView` with `.behindWindow`. Light = `.hudWindow` (Spotlight-style frosted glass). Dark = `.underWindowBackground` (`.hudWindow` is too translucent in dark). `window.backgroundColor = .clear`, `isOpaque = false`.
- **Indigo tint:** 4–5% `caiPrimary` overlay on the visual effect background. Makes the window feel like Cai before the user reads a word. Implemented in `VisualEffectBackground.swift`.
- **Window dimensions:** 540pt wide, fixed. Height varies by content. Corner radius **20pt**. The wider width accommodates MCP forms, subtitles, and destination chips comfortably (closer to Raycast than Spotlight).

---

## Spacing

**Base unit:** 4px.

| Token | Value | Usage |
|-------|-------|-------|
| `spacing2xs` | 4pt | Icon inner padding, tight gaps |
| `spacingXs` | 6pt | Row internal gaps (icon↔text) |
| `spacingSm` | 8pt | Small internal padding |
| `spacingMd` | 12pt | Row horizontal padding |
| `spacingLg` | 16pt | Section horizontal padding |
| `spacingXl` | 24pt | Between major sections |
| `spacing2xl` | 32pt | Large separations |
| `spacing3xl` | 48pt | Max content separation |

**Row heights:** standard action row 42pt (label only) / 56pt (+ subtitle); progress step row 44pt / 60pt; header row 38pt; footer row 32pt.

---

## Border Radius

| Role | Value | Elements |
|---|---|---|
| Micro | 4pt | Keyboard shortcut chips, small badges |
| Small | 6pt | Icon containers (28×28) |
| Medium | 8pt | Action rows, cards, form inputs |
| Large | 10pt | Panels, popovers, settings toggle row cards |
| Window | 20pt | The Cai popover window itself |

**Rule:** radius scales with element size. A 28pt icon at 6pt looks proportionally correct; a full window at 4pt looks underbaked.

---

## Motion

**Approach:** minimal-functional. Every animation aids comprehension. None are decorative.

| Curve | Duration | Usage |
|---|---|---|
| `.easeOut` | 0.2s | Screen changes, step completions, result reveals, error states |
| `.easeOut` | 0.15s | Row selection highlight, button press feedback |
| `.easeInOut` repeating | 1.2s | In-progress ◉ pulse (opacity 0.45↔1.0) — in-progress states only |

**The rule:** No bounce. No spring physics on utility interactions. Bounce signals "consumer app." Utility tools that interrupt your workflow should move with intent, not personality.

---

## Reusable Component Patterns

### Settings sub-screen toggle row

Used for any "list of items, each with on/off." Established by `ConnectorsSettingsView`, reused by `BuiltInActionsView` and `DestinationsManagementView` built-in tab.

```
┌────────────────────────────────────────────────────────┐
│  [icon]  Label                                [Toggle] │
│          Subtitle (scope, status, or hint)             │
└────────────────────────────────────────────────────────┘
```

- **Container:** `RoundedRectangle(cornerRadius: 10).fill(Color.caiSurface.opacity(0.3))`. Padding `.horizontal(12) .vertical(10)`.
- **Leading icon:** SF Symbol, 14pt medium, in a `frame(width: 20)` for alignment. `caiPrimary` when on, `caiTextSecondary.opacity(0.5)` when off.
- **Label:** 12pt medium, `caiTextPrimary`. Subtitle: 10pt regular, `caiTextSecondary.opacity(0.7)` — carries scope/status, not decoration.
- **Toggle:** `.toggleStyle(.switch).controlSize(.mini).tint(.caiPrimary).labelsHidden()`, right-aligned via `Spacer()`.
- **No chevron** unless the row drills into a sub-detail.

### Chip shape: fact vs control (added 2026-08-21)

Cai has two chip families and **shape is what tells them apart**. Get this wrong and passive text looks tappable.

| Shape | Meaning | Examples |
|---|---|---|
| **Borderless capsule**, `caiSurface` fill, `caiTextSecondary` | Cai stating a fact. Not interactive. | capability chips |
| **Bordered rounded-rect**, radius 5, hairline border, hover wash, pointing-hand cursor | A control. Click does something. | `ChipToggle`, `ChipButton`, `DestinationChip` |

**Compact form (added 2026-08-21).** In a 42/56pt list row at 11pt, the same facts render as **dot-separated plain text**, not capsules — `Sends to hooks.slack.com · Uses secret API_KEY · +2`. Capsule chrome at that size is noise in a row that already carries an icon, a title, a provenance badge and a `…` menu. This is a sanctioned third rendering of the fact family, not a deviation: same copy, same source, same order, same no-indigo rule. `CapabilitySubtitle.swift` owns it.

Rules for the capsule (fact) family:

- **No border, no hover state, no cursor change, no indigo, ever.** Per Indigo discipline these are passive structure; per the Red rule orange stays reserved for the escalation callout, so a fact chip is never itself an alarm.
- **They appear on every item, not only risky ones.** A chip family that showed up only on dangerous actions would quietly become a second warning channel competing with the callout.
- **Never mix the two families in one row.** This is why the action editor does NOT show capability chips: its chip row is `ChipToggle`s, and look-alike passive chips there would fail the Indigo-discipline mental test ("would the user expect tapping it to do something?"). Decided 2026-08-21; do not revisit as a quick add.

### Pin button (progressive disclosure)

For items with a binary "elevated/normal" state, where the row already has a leading icon (e.g., Custom Actions). The icon doubles as the pin toggle.

- **Pinned (always visible):** `pin.fill` 12pt medium, `caiPrimary`, on `caiPrimary.opacity(0.15)` rounded background.
- **Unpinned + hovered:** `pin` (unfilled) 12pt medium, `caiTextSecondary.opacity(0.5)`, on `caiSurface.opacity(0.6)`.
- **Unpinned + not hovered:** show the row's regular icon (e.g., shortcut type icon).
- **Tooltip:** `.help(item.isPinned ? "Unpin" : "Pin to top")` for both states.

The icon-doubles-as-button keeps the row visually quiet for the 90% of items the user doesn't elevate.

**Note (2026-05-07):** Custom Destinations do NOT have pinning — destinations are passive sinks, not commands competing for action-list position. `showInActionList` controls visibility; drag controls order.

### Drag-to-reorder lists

Used in `ShortcutsManagementView` and `DestinationsManagementView` Custom tab.

- Wrap rows in a SwiftUI `List` (not `ScrollView { VStack }`) so `.onMove(perform:)` works.
- Strip List chrome with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, plus per-row `.listRowSeparator(.hidden)` + `.listRowBackground(Color.clear)` + tight `.listRowInsets`.
- Enforce invariants in the move handler (e.g., pinned-first), not via section boundaries — re-sort the underlying array after the move. Cross-section drags snap back on drop.
- **Critical:** never put `.onTapGesture` on a row — any tap gesture variant breaks `List`'s drag responder. Use a trailing `Menu` or `Button` instead. See [`SWIFTUI_GOTCHAS.md`](../../_docs/architecture/SWIFTUI_GOTCHAS.md).

### Two-tab management screen

Parent shell for Settings sub-screens with a Custom + Built-in pattern. Used by `ActionsManagementView` and `DestinationsManagementView`.

```
┌────────────────────────────────────────────────────────┐
│  [icon]  Title                                     [+] │   ← header
│          Per-tab subtitle                              │
├────────────────────────────────────────────────────────┤
│  [ Custom (12) ]  [ Built-in (8) ]                     │   ← TabBar (neutral)
├────────────────────────────────────────────────────────┤
│                                                        │
│  Tab content (List for Custom; toggle list for         │
│  Built-in)                                             │
│                                                        │
├────────────────────────────────────────────────────────┤
│  [Esc] Back                                            │   ← footer
└────────────────────────────────────────────────────────┘
```

- **Header:** `icon · title · subtitle` left, `+` right (only on the Custom tab).
- **TabBar:** neutral active pill on a recessed neutral track. No indigo (per Indigo discipline). Custom always first, Built-in always second.
- **Single-list variant** (added 2026-08-08): pass `tabs: []` and the shell renders no TabBar, content directly under the header; `+` shows whenever `onAdd` is set. Used by Secrets.
- **`+` button trigger:** parent's `+` bumps a UUID `@State` that the child watches via `.onChange(of: externalAddTrigger)` to call `cancelForm() + beginAdding()`. Do NOT use `.id()` on the embed — it remounts the child but `.onChange` won't fire on the freshly-mounted instance. See [`SWIFTUI_GOTCHAS.md`](../../_docs/architecture/SWIFTUI_GOTCHAS.md) for details.
- **Footer:** single `KeyboardHint(key: "Esc", label: "Back")`.

### Row "…" menu (Edit / Duplicate / Share / Delete)

Linear-style trailing menu that consolidates row actions. Used in `ShortcutsManagementView` and `DestinationsManagementView`.

```swift
Menu {
    Button { beginEditing(item) } label: { Label("Edit", systemImage: "pencil") }
    Button { duplicate(item) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
    Button { share(item) } label: { Label("Share as Extension", systemImage: "square.and.arrow.up") }
    Divider()
    Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
} label: {
    Image(systemName: "ellipsis")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.caiTextSecondary.opacity(0.6))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
}
.menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.fixedSize()
```

A `Menu` button is a self-contained click target — it does NOT capture row-level mouse-down, so the underlying `List`'s drag-to-reorder gesture continues to work.

### Composer text input

Multi-line form fields use `MultilineTextEditor` (an `NSTextView` wrapper).

- **Default size:** 1 line, grows with content, scrolls beyond 4 lines. Matches Linear / Notion / Apple Mail composer UX.
- **Keyboard:** Plain Return inserts a newline. `⌘⏎` fires the form's save callback. `Esc` fires cancel. Both bypass SwiftUI's `keyboardShortcut` chain (which doesn't cooperate with NSTextView reliably).
- **Self-frames:** the editor measures content via `NSLayoutManager.usedRect` and clamps height itself. Caller does NOT add `.frame(minHeight:maxHeight:)`.
- **Visual shell:** wrap with `.formFieldShell(focused:)`. Background `Color(nsColor: .textBackgroundColor)`, hairline `caiDivider.opacity(0.5)` border, `caiPrimary.opacity(0.5)` 1px when focused (the focus ring is the only indigo moment on this control).

### Empty states

`ManagementEmptyState` (in `ManagementScreen.swift`). Used inside a tab when zero items.

**Anatomy:** icon + title + description + optional CTA button.

- **Icon:** SF Symbol, 28pt light, `caiTextSecondary.opacity(0.4)`. Pick a symbol that depicts the *kind* of thing missing (`bolt.circle` for Actions, `paperplane.circle` for Destinations).
- **Title:** 13pt medium, `caiTextPrimary`. Short noun phrase ("No custom destinations yet").
- **Description:** 11pt, `caiTextSecondary.opacity(0.7)`, centered. Tells the user what the thing IS in plain language.
- **Optional CTA:** neutral button matching `ChipButton` vocabulary — `caiSurface.opacity(0.6)` fill, hairline border. Usually exposes the most likely next step ("Browse Community Extensions").

**The mental rule:** an empty state is a *welcome*, not an error. Warmth + one clear next step. One deliberate exception (2026-08-08): the Secrets empty state shows two CTAs (Add a Secret, Import from Shell…) because import only sells itself if it is visible the first time; do not add second CTAs elsewhere without a design decision.

---

## Accessibility

- **Minimum touch target:** 44×44pt for all interactive elements.
- **Step indicators:** always have `.accessibilityLabel("Completed" / "In progress" / "Pending" / "Failed")` — never rely on the visual symbol alone.
- **Pulsing ◉:** add `.accessibilityAddTraits(.updatesFrequently)` to suppress VoiceOver chatter on animation frames.
- **State change announcements:** `UIAccessibility.post(notification: .announcement, ...)` on each step transition.
- **Keyboard navigation:** all interactive elements reachable via Tab. `⌘1`–`⌘9` are the primary interaction model — they must work before the mouse does.
- **Contrast:** `caiPrimary` (#6366F2) on white = 4.52:1 (WCAG AA). On dark (#1C1C1E) = 6.1:1. Both pass.
- **Hover-only affordances:** anything that appears on hover (e.g., the unpinned pin button) must also be reachable via the form/edit flow for keyboard-only users.
