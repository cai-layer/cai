<p align="center">
  <img src="assets/cailogo-dark.png" width="128" height="128" alt="Cai logo">
</p>

<h1 align="center">Cai</h1>

<h3 align="center">Select any text or image. Get smart actions.</h3>

<p align="center">
  A privacy-first clipboard assistant powered by local AI.<br>
  Your data never leaves your machine.
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/clipboard-ai/cai?label=download&color=blue" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-13.0%2B-blue" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/runs%20100%25%20locally-black" alt="Runs locally">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <a href="../../stargazers"><img src="https://img.shields.io/github/stars/clipboard-ai/cai?style=flat" alt="GitHub Stars"></a>
</p>

<p align="center">
  <a href="https://getcai.app">Website</a> · <a href="../../releases/latest">Download</a> · <a href="https://github.com/clipboard-ai/cai-extensions">Extensions</a>
</p>

---

![Cai Demo](assets/cai-demo.gif)

Cai is a native macOS menu bar app that detects what's on your clipboard and offers smart, context-aware actions. Copy a meeting invite and it creates a calendar event. Copy an address and it opens Maps. Copy a screenshot and it extracts the text. Copy any text and ask your local AI to summarize, translate, or do anything you want — all without leaving your keyboard.

No cloud. No telemetry. No accounts.

## How It Works

1. **Select text or copy an image** anywhere on your Mac
2. Press **⌥C** (Option+C)
3. Cai detects the content type and shows relevant actions
4. Pick an action with arrow keys or **⌘1–9**
5. Result is auto-copied to your clipboard — just **⌘V** to paste

**Examples:**
- Select `"serendipity"` → Define, Explain, Translate, Search
- Select `"Let's meet Tuesday at 3pm at Starbucks"` → Create calendar event, Open in Maps
- Select an email in Mail → Reply, Summarize, Translate
- Select any text → Ask AI: *"Extract ingredients for 2 people"*
- Copy a screenshot → Image to Text (OCR), then Summarize, Translate, or any action
- Select a project name → Custom action: search in Google Drive (`https://drive.google.com/drive/search?q=%s`)

## Features

- **Smart detection** of content types (word, text, image, meeting, address, URL, JSON) with context-aware actions
- **Image to Text** — copy a screenshot or image and Cai extracts the text via on-device OCR (Apple Vision), then run any action on it
- **Built-in AI** — ships with [Ministral 3B](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF), downloaded on first launch. Also compatible with [Apple Intelligence](#apple-intelligence) (macOS 26+), LM Studio, Ollama, or any OpenAI-compatible server
- **Built-in chat** — ask follow-up questions with **Tab**, or press **⌘N** to start a new chat without clipboard content
- **Ask AI** (⌘1) — free-form prompt to do anything: improve writing, create email replies, translate, count words
- **Custom actions** — save reusable prompts and URL templates, access them by typing to filter
- **Output destinations** — send results to Mail, Notes, Reminders, or custom webhooks, URL schemes, AppleScript, and shell commands
- **Clipboard history** — search, pin, and reuse your last 100 clipboard items with **⌘0**
- **App-aware** — Cai knows which app you're in (Mail, Slack, Safari…) and adapts AI responses to match the context
- **About You** — set personal context (profession, tone, preferences) so AI responses are tailored to you
- **Type-to-filter** — start typing to filter actions and destinations by name
- **Keyboard-first** — navigate and execute everything without touching the mouse
- **Privacy-first** — no internet required, no data leaves your machine

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| **⌥C** | Trigger Cai (global hotkey) |
| **↑ ↓** | Navigate actions |
| **↵** | Execute selected action |
| **⌘1–9** | Jump to action by number |
| **⌘0** | Open clipboard history (searchable, with pinning) |
| **⌘N** | New chat (ask anything, without clipboard content) |
| **⌘↵** | Submit custom prompt / Copy result |
| **Tab** | Ask a follow-up question on the result |
| **A–Z** | Type to filter actions |
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

### Apple Intelligence

On Macs with an M1 chip or later running **macOS 26+**, Cai can use Apple Intelligence as a built-in model provider — no download needed. If available, Cai will offer it during first launch setup.

### External providers

Cai works with **LM Studio**, **Ollama**, or any OpenAI-compatible endpoint (local or cloud). Auto-detects running providers on launch.

AI is optional — system actions (Maps, Calendar, Search, Pretty Print JSON) work without it. API keys are stored in the **macOS Keychain**.

## Custom Actions

Save frequently used prompts and URL templates as custom actions. They appear when you type to filter the action list.

- **Prompt** — sends clipboard text + your prompt to the LLM (e.g., "Rewrite as email reply")
- **URL** — opens a URL with clipboard text substituted via `%s` (e.g., `https://reddit.com/search/?q=%s`)

Create them in Preferences → Custom Actions.

## Output Destinations

Send results to an output destination instead of just copying to clipboard.

**Built-in:** Email (Mail.app), Save to Notes, Create Reminder.

**Custom destinations:** Webhook, AppleScript, Deeplink, Shell Command — use `{{result}}` as a placeholder for your text.

Create them in Preferences → Output Destinations. Enable "Show in action list" for direct-access workflows.

## Community Extensions

Browse and install extensions from the [cai-extensions](https://github.com/clipboard-ai/cai-extensions) repo.

**Install:** Copy an extension's YAML → press **⌥C** → "Install Extension" → review and confirm.

Cai shows a trust confirmation before installing — you'll see the extension name, type, author, and where it sends data (if applicable). AppleScript and shell extensions are blocked from clipboard install for security.

**Create your own:** Fork the repo, add a YAML file, and open a PR. See the [extension guide](https://github.com/clipboard-ai/cai-extensions#creating-extensions) for details.

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
