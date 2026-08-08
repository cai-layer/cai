# Cai - local-first action layer for macOS

Behavioral quick-reference: the core flow and the lookup tables an agent needs fast. Deeper context is single-sourced elsewhere and not repeated here: system design in [`_docs/architecture/ARCHITECTURE.md`](../_docs/architecture/ARCHITECTURE.md), model/inference in [`_docs/architecture/LLM.md`](../_docs/architecture/LLM.md), build + dependencies + gotchas in [`CLAUDE.md`](../CLAUDE.md).

Press Option+C on any selection: Cai detects the content type and offers context-aware actions powered by local AI. Built-in LLM runs in-process via MLX-Swift on Apple Silicon (zero-config), or Apple Intelligence (macOS 26+) / LM Studio / Ollama / any OpenAI-compatible endpoint. Privacy-first, no cloud, no telemetry.

## Core Flow
1. **Option+C** anywhere → `HotKeyManager` fires
2. Capture frontmost app name (`sourceApp`) for LLM context
3. `ClipboardService` simulates **Cmd+C** via CGEvent (private event source to isolate modifier state)
4. `ContentDetector` analyzes clipboard → returns type + entities
5. `ActionGenerator` generates context-aware actions (always shows all actions regardless of LLM availability)
6. `WindowController` shows floating panel with fade animation → user picks action
7. Action executes (LLM call / system action) → result auto-copied → user pastes with Cmd+V

## Content Detection Priority
| Priority | Type | Detection Method | Confidence |
|----------|------|-----------------|------------|
| 0 | Extension | `# cai-extension` header in YAML | 1.0 |
| 1 | URL | Regex `https?://\|www\.` | 1.0 |
| 2 | JSON | Starts `{`/`[` + JSONSerialization | 1.0 |
| 3 | Address | International street regex + NSDataDetector (≤200 chars) | 0.8 |
| 4 | Meeting | NSDataDetector.date + preprocessing (14h→14:00) (≤200 chars) | 0.7-0.9 |
| 5 | Image | NSPasteboardType.tiff or image file | 1.0 |
| 6 | Word | ≤2 words, <30 chars | 1.0 |
| 7 | Short Text | <100 chars | 1.0 |
| 8 | Long Text | ≥100 chars | 1.0 |

**Filters**: Currency ($50), durations ("for 5 minutes"), pure numbers

## Actions Per Content Type

Structure: Custom Action (⌘1, always first) → type-specific actions → universal text actions.
Universal text actions appear for relevant content types. Filter-to-reveal lets users type to surface any action regardless of detected content type, so misdetection never locks the user out.

- **Word**: Define + Explain, Translate, Search (no Reply/Proofread)
- **Short Text**: Explain, Reply, Proofread, Translate, Search
- **Long Text**: Summarize, Explain, Reply, Proofread, Translate (no Search)
- **Meeting**: Create Event, Open in Maps (if location) + all text actions
- **Address/Venue**: Open in Maps + all text actions
- **URL (bare)**: Open in Browser only
- **URL+text**: text actions + Open in Browser
- **JSON**: Pretty Print only
- **Image**: Extract Text (OCR via Apple Vision) + text actions on extracted text

Meeting/address detection is skipped for text >200 chars — long text always gets text actions.

## Features
- **Type-to-filter**: Start typing to filter actions and shortcuts by prefix
- **Filter-to-reveal**: Typing also reveals actions hidden for the current content type (so misdetection never blocks an action)
- **Custom shortcuts**: User-defined prompts, URL templates (%s), and shell commands ({{result}})
- **Shell shortcuts**: Run shell commands on clipboard text, display output in result view (15s timeout, stdin piping, follow-up LLM queries on output)
- **Community extensions**: In-app extension browser fetches from curated GitHub repo. Search, one-tap install, shell confirmation. Also installable by copying YAML to clipboard.
- **Output destinations**: Send text to external apps/services (Email, Notes, Reminders built-in; Webhook, AppleScript, Deeplink, Shell custom)
- **MCP connectors**: GitHub + Linear via MCP protocol. Create issues with LLM-generated titles, duplicate detection, label fetching.
- **Agent authoring (Cai as MCP server)**: bundled `cai-mcp` stdio helper lets Claude Code / Cursor / Codex propose and update actions; the tiered approval sheet is the security boundary (no run / delete / approve tools)
- **Named secrets**: actions reference `{{secrets.NAME}}`, resolved from the Keychain at execution only; never in action text, model input, or agent view
- **App context**: Frontmost app name passed to LLM prompts (e.g., "from Mail")
- **Clipboard history**: Last 9 unique entries with pin support (Cmd+0)
- **Multi-turn follow-ups**: Tab to ask follow-up questions (fresh stateless session per call, seeded with prior turns)
- **Window resume**: Dismissed window cached for 10s, restores state on reopen
- **Permission indicator**: Shield icon in Settings header (green/orange)
- **Auto-updates**: Sparkle framework for checking/installing updates
- **OCR**: Apple Vision framework for image text extraction

## Keyboard Shortcuts
| Key | Action |
|-----|--------|
| Option+C | Global trigger |
| ↑↓ | Navigate actions |
| Enter | Execute selected |
| Cmd+1-9 | Direct action shortcuts |
| Cmd+0 | Clipboard history |
| Cmd+N | New action (Ask AI without clipboard) |
| Cmd+Enter | Submit custom prompt / Copy result |
| Tab | Follow-up question (from result view) |
| A-Z | Type to filter actions and shortcuts |
| ESC | Clear filter / Back / Dismiss |

## Key technical decisions
Single-sourced, not repeated here. Patterns (no-sandbox, CGEvent private source, CaiPanel `canBecomeKey`, passThrough, `acceptsFilterInput`, `LazyVStack .id(action.id)`, ICS-no-EventKit, notification-based routing, actor-based services): [`_docs/architecture/ARCHITECTURE.md`](../_docs/architecture/ARCHITECTURE.md). Inference (MLX in-process, stateless per-call sessions, per-action `GenerationConfig`, `isGenerating` concurrency guard, 50K input cap, Ministral 3B default + model catalog): [`_docs/architecture/LLM.md`](../_docs/architecture/LLM.md). `CaiActionCore` package + agent authoring: [`_docs/architecture/MCP.md`](../_docs/architecture/MCP.md).

## Reference (single-sourced)
Dependencies + versions: [`CLAUDE.md`](../CLAUDE.md). Bundle IDs (`com.soyasis.cai.dev` / `com.soyasis.cai`) and deployment target (macOS 14.0+): [`_docs/architecture/ARCHITECTURE.md`](../_docs/architecture/ARCHITECTURE.md).
