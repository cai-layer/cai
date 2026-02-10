<p align="center">
  <img src="assets/cai-logo.png" width="128" height="128" alt="Cai logo">
</p>

<h1 align="center">Cai</h1>

<h3 align="center">Select any text. Get smart actions.</h3>

<p align="center">
  A privacy-first clipboard assistant powered by local AI.<br>
  Your data never leaves your machine.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0%2B-blue" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  <a href="https://getcai.app">getcai.app</a>
</p>

---

![Cai Demo](assets/cai-demo.gif)

Cai is a native macOS menu bar app that detects what's on your clipboard and offers smart, context-aware actions. Copy a meeting invite and it creates a calendar event. Copy an address and it opens Maps. Copy any text and ask your local AI to summarize, translate, or do anything you want — all without leaving your keyboard.

No cloud. No telemetry. No accounts.

## How It Works

1. **Select text** anywhere on your Mac
2. Press **⌥C** (Option+C)
3. Cai detects the content type and shows relevant actions
4. Pick an action with arrow keys or **⌘1–9**
5. Result is auto-copied to your clipboard — just **⌘V** to paste

**Examples:**
- Select `"serendipity"` → Define, Explain, Translate, Search
- Select `"Let's meet Tuesday at 3pm at Starbucks"` → Create calendar event, Open in Maps
- Select `"123 Main St, NYC 10001"` → Open in Maps
- Select an email in Mail → Reply, Summarize, Translate
- Select a Slack message → Reply (matches the conversation tone)
- Select a recipe → Custom Action: *"Extract ingredients for 2 people"*
- Select meeting notes → Shortcut: *"Format as action items with owners and deadlines"*
- Select a project name → Shortcut: search in Google Drive (`https://drive.google.com/drive/search?q=%s`)
- Select `{"name": "John"}` → Pretty Print JSON

## Features

- **Smart detection** of 7 content types with context-aware actions
- **Local AI** integration — works with LM Studio, Ollama, or any OpenAI-compatible server
- **Custom AI action** (⌘1) — set your own prompt to do anything: improve writing, create email replies, translate, count words
- **Custom shortcuts** — save reusable prompts and URL templates, access them by typing to filter
- **Type-to-filter** — start typing to filter actions and shortcuts by name
- **Clipboard history** — access last 9 items with ⌘0
- **App-aware** — Cai knows which app you're in (Mail, Slack, Safari…) and adapts AI responses to match the context
- **Keyboard-first** — navigate and execute everything without touching the mouse
- **Privacy-first** — no internet required, no data leaves your machine

## Content Types & Actions

| Content Type | Detection | Actions |
|---|---|---|
| **JSON** | Valid JSON object/array | Pretty Print |
| **Meeting** | Date/time references | Create Calendar Event, Open in Maps |
| **Address** | Street patterns, "at [Place Name]" | Open in Maps |
| **Word** | 1–2 words | Define, Explain, Translate, Search |
| **Short Text** | < 100 characters | Explain, Reply, Translate, Search |
| **Long Text** | 100+ characters | Summarize, Reply, Translate, Search |

All text types also get **Custom Action** (⌘1) for free-form AI prompts.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **⌥C** | Trigger Cai (global hotkey) |
| **↑ ↓** | Navigate actions |
| **↵** | Execute selected action |
| **⌘1–9** | Jump to action by number |
| **⌘0** | Open clipboard history |
| **⌘↵** | Submit custom prompt / Copy result |
| **A–Z** | Type to filter actions and shortcuts |
| **Esc** | Clear filter / Back / Dismiss |

## Installation

### Download

1. Download the `.dmg` from the [latest release](../../releases/latest)
2. Open the DMG and drag **Cai.app** to your Applications folder
3. Open the app — macOS will show a warning (the app is not notarized through the Apple Developer Program)
4. Follow the [first launch setup](#first-launch-setup) below
5. Configure your LLM server in Preferences (left-click menu bar icon)

### First Launch Setup

Cai is free and open source. Since it's not distributed through the App Store or notarized with a paid Apple Developer account ($99/year), macOS Gatekeeper will block it on first launch. This is normal for any open-source Mac app distributed outside the App Store.

**Step 1** — Open Cai. macOS blocks it. Click **Done**.

<img src="assets/setup-1-blocked.png" width="300" alt="macOS blocks Cai on first launch">

**Step 2** — Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

<img src="assets/setup-2-open-anyway-settings.png" width="500" alt="Privacy & Security showing Open Anyway button">

**Step 3** — Click **Open Anyway** in the confirmation dialog.

<img src="assets/setup-3-open-anyway.png" width="300" alt="Open Anyway confirmation dialog">

**Step 4** — Authenticate with Touch ID or your password.

<img src="assets/setup-4-authenticate.png" width="300" alt="Touch ID or password authentication">

**Step 5** — Cai needs Accessibility permission to use the global hotkey (⌥C) and simulate ⌘C to copy your selection. Click **Open System Settings**.

<img src="assets/setup-5-accessibility-prompt.png" width="450" alt="Accessibility permission prompt">

**Step 6** — Toggle Cai **on** in the Accessibility list.

<img src="assets/setup-6-accessibility-toggle.png" width="450" alt="Accessibility toggle enabled for Cai">

You're all set! Press **⌥C** with any text selected to start using Cai.

### Build from Source

```bash
git clone https://github.com/soyasis/cai.git
cd cai/Cai
open Cai.xcodeproj
```

In Xcode:
1. Select the **Cai** scheme and **My Mac** as destination
2. **Product → Run** (⌘R)

> **Note:** The app requires **Accessibility permission** and runs **without App Sandbox** (required for global hotkey and CGEvent posting).

## LLM Setup

Cai works with any OpenAI-compatible local server. AI is optional — system actions (Open URL, Maps, Calendar, Search, Pretty Print JSON) work without it.

| Provider | Default URL | Setup |
|---|---|---|
| **LM Studio** | `http://127.0.0.1:1234/v1` | [Download](https://lmstudio.ai) → Load model → Start server |
| **Ollama** | `http://127.0.0.1:11434/v1` | [Install](https://ollama.ai) → `ollama pull llama3.2` |
| **Jan AI** | `http://127.0.0.1:1337/v1` | [Download](https://jan.ai) → Load model → Start server |
| **LocalAI** | `http://127.0.0.1:8080/v1` | [Setup guide](https://localai.io) |
| **Open WebUI** | `http://127.0.0.1:8080/v1` | [Install](https://openwebui.com) → Enable OpenAI API |
| **GPT4All** | `http://127.0.0.1:4891/v1` | [Download](https://gpt4all.io) → Enable API server |
| **Custom** | User-defined | Any OpenAI-compatible server |

**To configure:** Open Cai Preferences (left-click menu bar icon) → select your Model Provider.

### Recommended Models

Cai works best with small, fast models optimized for short text tasks. Speed matters more than size — you want sub-second responses for clipboard actions.

| Model | Params | Why | Ollama |
|---|---|---|---|
| **Qwen3 4B** | 4B | Fast, great instruction following. Our top pick. | `ollama pull qwen3:4b` |
| **Qwen3 30B-A3B** | 30B (3B active) | Smarter output, similar speed to 4B (MoE). Needs 16GB+ RAM. | `ollama pull qwen3:30b-a3b` |
| **Gemma 3 4B** | 4B | Strong multilingual support (140+ languages). | `ollama pull gemma3:4b` |
| **Phi-4 Mini** | 3.8B | Lightweight, good at structured tasks. | `ollama pull phi4-mini` |
| **Qwen3 8B** | 8B | Best quality in the small range. Slower than 4B. | `ollama pull qwen3:8b` |

> **Tip:** Start with **Qwen3 4B** — it's the best balance of speed and quality for clipboard tasks like summarize, translate, reply, and explain.

## Configuration

Left-click the Cai menu bar icon (or click the logo in the action window footer) to access Preferences:

| Setting | Description | Default |
|---|---|---|
| **Translation Language** | Target language for translations | English |
| **Search URL** | Base URL for web searches | Brave Search |
| **Maps Provider** | Apple Maps or Google Maps | Apple Maps |
| **Model Provider** | LM Studio, Ollama, or Custom | LM Studio |
| **Custom Action** | Free-form AI prompt via ⌘1 | — |
| **Custom Shortcuts** | Save prompt and URL shortcuts for instant access | — |
| **Launch at Login** | Start Cai automatically | On |

## Custom Shortcuts

Save frequently used prompts and URL templates as shortcuts. They appear when you type to filter the action list.

**Two types:**
- **Prompt** — sends your clipboard text + saved prompt to the local LLM (e.g., "Rewrite as email reply", "Convert to CSV")
- **URL** — opens a URL with your clipboard text substituted via `%s` (e.g., `https://reddit.com/search/?q=%s`)

**To create:** Preferences → Custom Shortcuts → click **+** → add a name, pick the type, and enter the prompt or URL template.

**To use:** Press **⌥C**, then start typing the shortcut name. Matching shortcuts appear alongside filtered built-in actions.

## Requirements

- **macOS 13.0** (Ventura) or later
- **Accessibility permission** (for global hotkey ⌥C)
- **Local LLM server** (optional — for AI-powered actions only)

## Troubleshooting

**macOS blocks Cai from opening**
This is expected — see [First Launch Setup](#first-launch-setup) above. Alternatively, remove the quarantine flag via Terminal:
```bash
xattr -cr /Applications/Cai.app
```

**Global shortcut ⌥C doesn't work**
- Check **System Settings → Privacy & Security → Accessibility** — make sure Cai is listed and enabled
- If it's listed but still not working, remove Cai from the list and re-add it
- Make sure no other app is using ⌥C (e.g., Raycast, Alfred, BetterTouchTool)

**LLM not connecting**
- Verify your server is running: `curl http://127.0.0.1:1234/v1/models`
- Check that the URL in Preferences matches your server's address and port
- Ollama uses port `11434`, LM Studio uses `1234` — make sure you selected the right provider

**Date/meeting not detected**
- Detection works best with English dates ("Tuesday at 3pm", "lunch tomorrow at noon")
- Try rephrasing: "3pm tomorrow" instead of "tomorrow 15h"
- Some informal formats may not be recognized — explicit dates work most reliably

## Tech Stack

- **SwiftUI** + **AppKit** (native macOS, no Electron)
- **CGEvent** for Cmd+C simulation (private event source to isolate modifier state)
- **AXUIElement** for text selection detection
- **NSPanel** subclass for floating window that captures keyboard events
- **Actor-based** LLMService for thread-safe async/await
- **ICS file generation** for calendar events (no EventKit permissions needed)
- **SMAppService** for Launch at Login
- [HotKey](https://github.com/soffes/HotKey) (SPM) for global keyboard shortcut

## License

[MIT](LICENSE)
