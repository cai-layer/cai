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
- Select an email in Mail → Reply, Summarize, Translate
- Select any text → Custom Action: *"Extract ingredients for 2 people"*
- Select a project name → Shortcut: search in Google Drive (`https://drive.google.com/drive/search?q=%s`)

## Features

- **Smart detection** of 7 content types (word, text, meeting, address, URL, JSON) with context-aware actions
- **Built-in AI** — ships with [Ministral 3B](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF), downloaded on first launch. Also works with LM Studio, Ollama, or any OpenAI-compatible server
- **Custom AI action** (⌘1) — free-form prompt to do anything: improve writing, create email replies, translate, count words
- **Custom shortcuts** — save reusable prompts and URL templates, access them by typing to filter
- **Output destinations** — send results to Mail, Notes, Reminders, or custom webhooks, URL schemes, AppleScript, and shell commands
- **Type-to-filter** — start typing to filter actions, shortcuts, and destinations by name
- **Clipboard history** — access last 9 items with ⌘0
- **App-aware** — Cai knows which app you're in (Mail, Slack, Safari…) and adapts AI responses to match the context
- **Keyboard-first** — navigate and execute everything without touching the mouse
- **Privacy-first** — no internet required, no data leaves your machine

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
git clone https://github.com/clipboard-ai/cai.git
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

Models are stored in `~/Library/Application Support/Cai/models/`. The engine starts automatically on launch and stops when you quit Cai.

**Custom models:** Drop any `.gguf` file into the models folder and select it from the model picker in Settings or the action window footer. Cai will restart the engine with your chosen model.

### External providers

If you already use LM Studio, Ollama, or another local server, skip the built-in download. Cai works with any OpenAI-compatible endpoint.

| Provider | Default URL | Setup |
|---|---|---|
| **LM Studio** | `http://127.0.0.1:1234/v1` | [Download](https://lmstudio.ai) → Load model → Start server |
| **Ollama** | `http://127.0.0.1:11434/v1` | [Install](https://ollama.ai) → `ollama pull qwen3:4b` |
| **Jan AI** | `http://127.0.0.1:1337/v1` | [Download](https://jan.ai) → Load model → Start server |
| **Custom** | User-defined | Any OpenAI-compatible server |

Cai auto-detects running providers on launch — no manual setup needed in most cases.

### Cloud & authenticated providers

Cai works with any OpenAI-compatible cloud API. Set the provider to **Custom**, enter the API base URL, and add your API key in Settings.

| Provider | Base URL | Notes |
|---|---|---|
| **OpenAI** | `https://api.openai.com` | GPT-4o, GPT-4o-mini, etc. |
| **Google Gemini** | `https://generativelanguage.googleapis.com/v1beta/openai` | Gemini Flash, Pro, etc. |
| **OpenRouter** | `https://openrouter.ai/api` | 200+ models including Claude, Llama, Mistral |
| **Together AI** | `https://api.together.xyz` | Fast inference, open models |
| **Groq** | `https://api.groq.com/openai` | Ultra-fast inference |
| **Mistral AI** | `https://api.mistral.ai` | Mistral models |

The API key is stored in the **macOS Keychain** (encrypted at rest). AI is optional — system actions (Maps, Calendar, Search, Pretty Print JSON) work without it.

> **Note:** Anthropic's Claude API is not directly compatible. Use [OpenRouter](https://openrouter.ai) to access Claude models through an OpenAI-compatible interface.

### Recommended Models

| Model | Params | Why | Install |
|---|---|---|---|
| **Ministral 3B** _(built-in)_ | 3B | Fast, concise output. Ships with Cai. | Automatic on first launch |
| **Qwen3 4B** | 4B | Smartest at this size — best for complex instructions. | `lms get qwen3-4b` / `ollama pull qwen3:4b` |
| **Llama 3.2 3B** | 3B | Reliable all-rounder. | `lms get llama-3.2-3b-instruct` / `ollama pull llama3.2:3b` |
| **Gemma 3 4B** | 4B | Strong multilingual support (140+ languages). | `lms get gemma-3-4b` / `ollama pull gemma3:4b` |
| **Qwen3 8B** | 8B | Best quality in the small range. Slower. | `lms get qwen3-8b` / `ollama pull qwen3:8b` |

## Custom Shortcuts

Save frequently used prompts and URL templates as shortcuts. They appear when you type to filter the action list.

- **Prompt** — sends clipboard text + your prompt to the LLM (e.g., "Rewrite as email reply")
- **URL** — opens a URL with clipboard text substituted via `%s` (e.g., `https://reddit.com/search/?q=%s`)

Create them in Preferences → Custom Shortcuts.

## Output Destinations

Send results to an output destination instead of just copying to clipboard.

**Built-in:** Email (Mail.app), Save to Notes, Create Reminder.

**Custom destinations:** Webhook, AppleScript, Deeplink, Shell Command — use `{{result}}` as a placeholder for your text.

Create them in Preferences → Output Destinations. Enable "Show in action list" for direct-access workflows.

## Requirements

- **macOS 13.0** (Ventura) or later
- **Apple Silicon** (M1 or later) for the built-in AI engine
- **~2.5 GB disk space** for the bundled model (downloaded on first launch)
- **Accessibility permission** (for global hotkey ⌥C)

## Troubleshooting

**macOS blocks Cai from opening (building from source)**
Remove the quarantine flag: `xattr -cr /Applications/Cai.app`

**Global shortcut ⌥C doesn't work**
- Check **System Settings → Privacy & Security → Accessibility** — make sure Cai is listed and enabled
- If still not working, remove Cai from the list and re-add it
- Make sure no other app is using ⌥C (e.g., Raycast, Alfred)

**LLM not connecting**
- Verify your server is running: `curl http://127.0.0.1:1234/v1/models`
- Ollama uses port `11434`, LM Studio uses `1234` — make sure you selected the right provider

## Tech Stack

- **SwiftUI** + **AppKit** (native macOS, no Electron)
- **Bundled [llama.cpp](https://github.com/ggml-org/llama.cpp)** for local LLM inference (ARM64 macOS, Metal GPU)
- **Actor-based** services for thread-safe async/await
- [HotKey](https://github.com/soffes/HotKey) (SPM) for global keyboard shortcut

---

Built as a side project with [Claude Code](https://claude.ai/code)'s help

## License

[MIT](LICENSE)
