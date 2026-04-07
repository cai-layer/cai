<p align="center">
  <img src="assets/cailogo-dark-rounded.png" width="128" height="128" alt="Cai logo">
</p>

<h1 align="center">Cai</h1>

<h3 align="center">The AI Action Layer for macOS</h3>

<p align="center">
  Select any text or image, press ⌥C, get instant AI actions.<br>
  100% local. Free and open source.
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/cai-layer/cai?label=download&color=blue" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-13.0%2B-blue" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/runs%20100%25%20locally-black" alt="Runs locally">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <a href="../../stargazers"><img src="https://img.shields.io/github/stars/cai-layer/cai?style=flat" alt="GitHub Stars"></a>
</p>

<p align="center">
  <a href="https://getcai.app">Website</a> · <a href="https://getcai.app/docs/">Docs</a> · <a href="../../releases/latest">Download</a> · <a href="https://github.com/cai-layer/cai-extensions">Extensions</a>
</p>

---

https://github.com/user-attachments/assets/7abef32a-deed-4da3-880f-1222031800ee

Cai is a native macOS menu bar app that adds an AI action layer to your Mac. Select any text or image, press **⌥C**, and instantly run AI actions — summarize, translate, OCR, draft replies, create GitHub issues, run shell commands, and more — all without leaving your workflow. It's the missing AI action layer your Mac needs.

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
- Copy a screenshot → Image to Text (OCR), then any text action
- Select any text → Ask AI: *"Extract ingredients for 2 people"*

→ [Read the full How It Works guide](https://getcai.app/docs/usage/how-it-works/)

## Features

- **Smart detection** — Cai reads what you copied (word, text, image, meeting, address, URL, JSON) and shows the right actions
- **Image to Text** — extract text from screenshots and images via on-device OCR (Apple Vision)
- **Built-in AI** — uses [Apple Intelligence](https://getcai.app/docs/getting-started/llm-setup/) on macOS 26+, or runs an MLX model in-process via MLX-Swift on Apple Silicon
- **Bring your own LLM** — works with LM Studio, Ollama, any OpenAI-compatible server, or any model from [HuggingFace mlx-community](https://huggingface.co/mlx-community)
- **Built-in chat** — ask follow-up questions with **Tab**, or press **⌘N** to start a new chat
- **Custom actions** — save reusable prompts, URL templates, and shell commands
- **Connectors** — create GitHub Issues and Linear tickets from any selected text or image with AI-generated context
- **Output destinations** — send results to Mail, Notes, Reminders, or any app via webhooks, AppleScript, deeplinks, and shell commands
- **Clipboard history** — search, pin, and reuse your last 100 clipboard items with **⌘0**
- **Context Snippets** — teach Cai per-app context so every action gets smarter
- **Privacy-first** — no internet required, no data leaves your machine

→ [See all features in the docs](https://getcai.app/docs/)

## Installation

1. Download the `.dmg` from the [latest release](../../releases/latest)
2. Open the DMG and drag **Cai.app** to your Applications folder
3. Open the app and grant **Accessibility permission** when prompted
4. On macOS 26+, Cai uses Apple Intelligence automatically. Otherwise, the built-in MLX model downloads on first launch — or skip if you already use LM Studio / Ollama

→ [Full installation guide](https://getcai.app/docs/getting-started/installation/) · [LLM setup](https://getcai.app/docs/getting-started/llm-setup/)

### Build from Source

```bash
git clone https://github.com/cai-layer/cai.git
cd cai/Cai
open Cai.xcodeproj
```

In Xcode: select the **Cai** scheme and **My Mac** as destination, then **Product → Run** (⌘R).

> **Note:** The app requires **Accessibility permission** and runs **without App Sandbox** (required for global hotkey and CGEvent posting).

## Documentation

Full documentation is at [getcai.app/docs](https://getcai.app/docs/):

- **[How It Works](https://getcai.app/docs/usage/how-it-works/)** — content detection, smart actions, follow-ups
- **[Keyboard Shortcuts](https://getcai.app/docs/usage/keyboard-shortcuts/)** — every key and what it does
- **[LLM Setup](https://getcai.app/docs/getting-started/llm-setup/)** — Apple Intelligence, MLX, LM Studio, Ollama, cloud providers
- **[Choosing a Model](https://getcai.app/docs/getting-started/llm-setup/#choosing-a-model)** — model picker guide and quantization explainer
- **[Ask AI](https://getcai.app/docs/usage/custom-actions/)** — free-form prompts on selected text
- **[Custom Actions](https://getcai.app/docs/usage/saved-actions/)** — save prompts, URLs, and shell commands
- **[Custom Destinations](https://getcai.app/docs/usage/destinations/)** — webhooks, AppleScript, deeplinks, shell
- **[Connectors](https://getcai.app/docs/usage/connectors/)** — GitHub and Linear integration
- **[Context Snippets](https://getcai.app/docs/usage/context-snippets/)** — per-app context for smarter actions
- **[Community Extensions](https://getcai.app/docs/usage/extensions/)** — install and create shared actions
- **[Troubleshooting](https://getcai.app/docs/troubleshooting/common-issues/)** — common issues and fixes

## Requirements

- **macOS 13.0** (Ventura) or later
- **Apple Silicon** (M1 or later) for the built-in AI engine
- **Accessibility permission** (for global hotkey ⌥C)

## Tech Stack

- **SwiftUI** + **AppKit** (native macOS, no Electron)
- **[MLX-Swift](https://github.com/ml-explore/mlx-swift)** for in-process LLM inference on Apple Silicon
- **Actor-based** services for thread-safe async/await
- [HotKey](https://github.com/soffes/HotKey) (SPM) for the global keyboard shortcut

---

Built as a side project with [Claude Code](https://claude.ai/code)'s help.

## License

[MIT](LICENSE)
