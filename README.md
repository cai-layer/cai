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
- **Built-in AI** — ships with [Ministral 3B](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF), downloaded on first launch. Also works with LM Studio, Ollama, or any OpenAI-compatible server
- **Custom AI action** (⌘1) — set your own prompt to do anything: improve writing, create email replies, translate, count words
- **Custom shortcuts** — save reusable prompts and URL templates, access them by typing to filter
- **Output destinations** — send results to Mail, Notes, Reminders, or custom webhooks, URL schemes, AppleScript, and shell commands
- **Type-to-filter** — start typing to filter actions, shortcuts, and destinations by name
- **Clipboard history** — access last 9 items with ⌘0
- **App-aware** — Cai knows which app you're in (Mail, Slack, Safari…) and adapts AI responses to match the context
- **Keyboard-first** — navigate and execute everything without touching the mouse
- **Privacy-first** — no internet required, no data leaves your machine

## Content Types & Actions

| Content Type | Detection | Actions |
|---|---|---|
| **JSON** | Valid JSON object/array | Pretty Print |
| **Meeting** | Date/time references | Reply, Create Calendar Event, Open in Maps, Summarize |
| **Address** | Street patterns, "at [Place Name]" | Open in Maps |
| **Word** | 1–2 words | Define, Explain, Translate, Search |
| **Short Text** | < 100 characters | Explain, Reply, Proofread, Translate, Search |
| **Long Text** | 100+ characters | Summarize, Reply, Proofread, Translate, Search |

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
3. Open the app and grant Accessibility permission ([see below](#first-launch-setup))
4. Cai will download a small AI model (~2 GB) on first launch — or skip if you already use LM Studio / Ollama

### First Launch Setup

On first launch, Cai needs **Accessibility permission** to use the global hotkey (⌥C) and simulate ⌘C to copy your selection.

**Step 1** — Open Cai. It will ask for Accessibility permission. Click **Open System Settings**.

<img src="assets/setup-5-accessibility-prompt.png" width="450" alt="Accessibility permission prompt">

**Step 2** — Toggle Cai **on** in the Accessibility list.

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

### Built-in (zero config)

Cai ships with a bundled AI engine ([llama.cpp](https://github.com/ggml-org/llama.cpp)). On first launch it downloads [Ministral 3B](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF) (~2 GB) and runs everything locally — no external server needed.

The model is stored in `~/Library/Application Support/Cai/models/`. The engine starts automatically on launch and stops when you quit Cai.

### External providers

If you already use LM Studio, Ollama, or another local server, skip the built-in download. Cai works with any OpenAI-compatible endpoint.

| Provider | Default URL | Setup |
|---|---|---|
| **LM Studio** | `http://127.0.0.1:1234/v1` | [Download](https://lmstudio.ai) → Load model → Start server |
| **Ollama** | `http://127.0.0.1:11434/v1` | [Install](https://ollama.ai) → `ollama pull qwen3:4b` |
| **Jan AI** | `http://127.0.0.1:1337/v1` | [Download](https://jan.ai) → Load model → Start server |
| **LocalAI** | `http://127.0.0.1:8080/v1` | [Setup guide](https://localai.io) |
| **Open WebUI** | `http://127.0.0.1:8080/v1` | [Install](https://openwebui.com) → Enable OpenAI API |
| **GPT4All** | `http://127.0.0.1:4891/v1` | [Download](https://gpt4all.io) → Enable API server |
| **Custom** | User-defined | Any OpenAI-compatible server |

**Auto-detection:** On launch, Cai checks if the current provider is reachable. If not, it probes known local ports and switches to the first one that responds — no manual setup needed.

**To configure manually:** Open Cai Preferences (left-click menu bar icon) → select your Model Provider.

AI is optional — system actions (Open URL, Maps, Calendar, Search, Pretty Print JSON) work without it.

### Recommended Models

Cai works best with small, fast instruct models (3–4B parameters). Speed matters more than size — you want sub-second responses for clipboard actions.

| Model | Params | Why | Install |
|---|---|---|---|
| **Ministral 3B** | 3B | Fastest real-world feel — concise output, clean markdown, fewest tokens per answer. Our top pick. | `lms get ministral-3-3b-instruct-2512` / `ollama pull ministral:3b` |
| **Qwen3 4B** | 4B | Smartest at this size — best on STEM, coding, and instruction following. Can be verbose. | `lms get qwen3-4b` / `ollama pull qwen3:4b` |
| **Llama 3.2 3B** | 3B | Reliable all-rounder — solid summarization, Q&A, and general conversation. | `lms get llama-3.2-3b-instruct` / `ollama pull llama3.2:3b` |
| **Gemma 3 4B** | 4B | Strong multilingual support (140+ languages). | `lms get gemma-3-4b` / `ollama pull gemma3:4b` |
| **Qwen3 8B** | 8B | Best quality in the small range. Slower than 3–4B. | `lms get qwen3-8b` / `ollama pull qwen3:8b` |

> **Tip:** Start with **Ministral 3B** — it produces the most concise, well-formatted responses, which means faster real-world speed for clipboard actions like summarize, translate, reply, and explain. Switch to **Qwen3 4B** if you need more intelligence (e.g., complex instructions or coding tasks).
>
> **LM Studio vs Ollama:** Both work great with Cai. LM Studio tends to be noticeably faster for inference (aggressive Metal GPU acceleration, speculative decoding), which matters for a clipboard tool where you want sub-second responses. Ollama is simpler to set up and manage models via CLI. Try both and see what feels snappier on your hardware.

## Configuration

Left-click the Cai menu bar icon (or click the logo in the action window footer) to access Preferences:

| Setting | Description | Default |
|---|---|---|
| **Translation Language** | Target language for translations | English |
| **Search URL** | Base URL for web searches | Brave Search |
| **Maps Provider** | Apple Maps or Google Maps | Apple Maps |
| **Model Provider** | Built-in, LM Studio, Ollama, or Custom | Built-in (auto-detected) |
| **Custom Action** | Free-form AI prompt via ⌘1 | — |
| **Custom Shortcuts** | Save prompt and URL shortcuts for instant access | — |
| **Output Destinations** | Where to send results (Mail, Notes, webhooks, etc.) | Email + Notes enabled |
| **Launch at Login** | Start Cai automatically | On |

## Custom Shortcuts

Save frequently used prompts and URL templates as shortcuts. They appear when you type to filter the action list.

**Two types:**
- **Prompt** — sends your clipboard text + saved prompt to the local LLM (e.g., "Rewrite as email reply", "Convert to CSV")
- **URL** — opens a URL with your clipboard text substituted via `%s` (e.g., `https://reddit.com/search/?q=%s`)

**To create:** Preferences → Custom Shortcuts → click **+** → add a name, pick the type, and enter the prompt or URL template.

**To use:** Press **⌥C**, then start typing the shortcut name. Matching shortcuts appear alongside filtered built-in actions.

## Output Destinations

After an AI action processes your text (or directly from the action list), you can send the result to an output destination instead of just copying it to the clipboard.

### Built-in Destinations

| Destination | What it does | Default |
|---|---|---|
| **Email** | Opens Mail.app with a new draft containing the text | Enabled |
| **Save to Notes** | Creates a new note in Notes.app (preserves line breaks) | Enabled |
| **Create Reminder** | Adds a reminder to your default Reminders list | Disabled |

Toggle built-in destinations on/off in Preferences → Output Destinations.

### Custom Destinations

Create your own destinations to send text to any app or service:

| Type | Use case | Example |
|---|---|---|
| **Webhook** | Send to any API via HTTP POST/PUT/PATCH | Post to Slack channel, create Notion page |
| **AppleScript** | Control any macOS app | Add to Things, create OmniFocus task |
| **URL Scheme** | Open deep links with your text | Save to Bear, open in Obsidian |
| **Shell Command** | Run terminal commands | `gh issue create`, pipe to a script |

**Template placeholders:**
- `{{result}}` — your clipboard or AI-processed text (auto-escaped for the destination type)
- `{{field_key}}` — value from a setup field (e.g. `{{api_key}}` for API tokens)

**Setup fields** let you store secrets like API keys. They're resolved at execution time and masked in the UI.

**"Show in action list"** — enable this to make a destination appear as a direct action (skips the AI step). Useful for quick-send workflows like "Send to Slack" directly from the action list.

**To create:** Preferences → Output Destinations → click **+** → pick a type, configure the template, and optionally add setup fields.

## Requirements

- **macOS 13.0** (Ventura) or later
- **Apple Silicon** (M1 or later) for the built-in AI engine
- **~2.5 GB disk space** for the bundled model (downloaded on first launch)
- **Accessibility permission** (for global hotkey ⌥C)

## Troubleshooting

**macOS blocks Cai from opening (building from source)**
If you build from source without a Developer ID, macOS Gatekeeper may block the app. Remove the quarantine flag via Terminal:
```bash
xattr -cr /Applications/Cai.app
```
This is not needed when installing from the [official DMG release](../../releases/latest).

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
- **Bundled [llama.cpp](https://github.com/ggml-org/llama.cpp)** for local LLM inference (ARM64 macOS, Metal GPU)
- **Actor-based** LLMService, BuiltInLLM, and OutputDestinationService for thread-safe async/await
- **ICS file generation** for calendar events (no EventKit permissions needed)
- **AppleScript** integration for native app destinations (Mail, Notes, Reminders)
- **SMAppService** for Launch at Login
- [HotKey](https://github.com/soffes/HotKey) (SPM) for global keyboard shortcut

## License

[MIT](LICENSE)
