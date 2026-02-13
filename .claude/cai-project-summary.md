# Cai - macOS Smart Clipboard Actions

## What It Is
Native macOS menu bar app (SwiftUI) that detects clipboard content types and offers context-aware actions powered by local AI. Ships with a built-in LLM engine (llama-server) for zero-config experience, or works with LM Studio/Ollama. Privacy-first, no cloud, no telemetry.

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
| 1 | URL | Regex `https?://\|www\.` | 1.0 |
| 2 | JSON | Starts `{`/`[` + JSONSerialization | 1.0 |
| 3 | Address | International street regex + NSDataDetector | 0.8 |
| 4 | Meeting | NSDataDetector.date + preprocessing (14h→14:00) | 0.7-0.9 |
| 5 | Venue | Case-sensitive regex: `at/in` + uppercase place name | 0.6 |
| 6 | Word | ≤2 words, <30 chars | 1.0 |
| 7 | Short Text | <100 chars | 1.0 |
| 8 | Long Text | ≥100 chars | 1.0 |

**Filters**: Currency ($50), durations ("for 5 minutes"), pure numbers

## Actions Per Content Type
- **All types**: Custom Action (⌘1, always first)
- **Word**: Define, Explain, Translate, Search
- **Short Text**: Explain, Reply, Proofread, Translate, Search
- **Long Text**: Summarize, Reply, Proofread, Translate, Search
- **Meeting**: Reply, Create Calendar Event, Open in Maps (if location), Summarize, Proofread, Translate, Search
- **Address/Venue**: Open in Maps
- **URL**: Open in Browser (+ Summarize/Explain if substantial text beyond URL)
- **JSON**: Pretty Print

## Features
- **Type-to-filter**: Start typing to filter actions and shortcuts by prefix
- **Custom shortcuts**: User-defined prompts and URL templates (with %s placeholder)
- **App context**: Frontmost app name passed to LLM prompts (e.g., "from Mail")
- **Clipboard history**: Last 9 unique entries (Cmd+0)
- **Window resume**: Dismissed window cached for 10s, restores state on reopen
- **Permission indicator**: Shield icon in Settings header (green/orange)

## Keyboard Shortcuts
| Key | Action |
|-----|--------|
| Option+C | Global trigger |
| ↑↓ | Navigate actions |
| Enter | Execute selected |
| Cmd+1-9 | Direct action shortcuts |
| Cmd+0 | Clipboard history |
| Cmd+Enter | Submit custom prompt / Copy result |
| A-Z | Type to filter actions and shortcuts |
| ESC | Clear filter / Back / Dismiss |

## Key Technical Decisions
- **No sandbox**: Required for CGEvent posting + global hotkey
- **CGEvent private source**: Prevents Option key leak from hotkey into simulated Cmd+C
- **CaiPanel (NSPanel subclass)**: Overrides `canBecomeKey` for keyboard events
- **PassThrough flag**: Lets TextEditor receive Enter/arrows during custom prompt input
- **acceptsFilterInput flag**: Prevents filter accumulation on non-action screens
- **LazyVStack `.id(action.id)`**: Prevents stale cached rows (not index-based)
- **ICS files for calendar**: No EventKit permissions needed
- **Notification-based keyboard routing**: WindowController posts, SwiftUI views subscribe
- **Actor-based services**: LLMService, BuiltInLLM, OutputDestinationService — thread-safe async/await
- **App context awareness**: Captures frontmost app before Cmd+C, passes to LLM
- **Built-in LLM**: Bundled llama-server (llama.cpp b8022) with auto-restart on crash (3 retries), orphan cleanup, PID tracking
- **Model download**: Singleton ModelDownloader survives window close for background downloads

## Dependencies
- **HotKey** (SPM): soffes/HotKey v0.2.0+
- **llama-server** (bundled): llama.cpp b8022, ARM64 macOS, Metal GPU
- **System**: AppKit, SwiftUI, Foundation, ApplicationServices, Carbon, ServiceManagement

## Bundle IDs
- **Debug**: `com.soyasis.cai.dev` (separate accessibility entry)
- **Release**: `com.soyasis.cai` (production)
- **Tests**: `com.soyasis.cai.tests`
