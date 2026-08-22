import AppKit
import Carbon

/// Fully-resolved clipboard content for the ⌥C / history-poll detection path,
/// in priority order. Produced from ONE atomic pasteboard snapshot.
enum ClipboardContent {
    case imageText(String)      // OCR text from an image file OR image data
    case text(String)           // trimmed, non-empty plain text
    case empty(hadImage: Bool)  // nothing usable; hadImage only picks the log line
}

class ClipboardService {
    static let shared = ClipboardService()

    private init() {}

    /// Simulates Cmd+C by posting CGEvents directly to the frontmost application.
    ///
    /// This is the same technique used by Raycast, Rectangle, and other macOS utilities.
    /// Requirements:
    ///   - Accessibility permission granted (AXIsProcessTrusted)
    ///   - App Sandbox DISABLED
    ///   - Hardened Runtime enabled (fine — CGEvent posting is allowed)
    ///
    /// CRITICAL DETAIL: We use a CGEventSource with `.combinedSessionState` and
    /// explicitly set the flags to ONLY `.maskCommand`. This is essential because
    /// our hotkey is Option+C — when the handler fires, the Option key is still
    /// physically held down. Without an explicit event source and flag override,
    /// the OS would merge the physical Option key state into our synthetic event,
    /// sending Cmd+Option+C to the target app instead of Cmd+C.
    func copySelectedText(completion: @escaping () -> Void) {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        // Create a private event source so our synthetic keystrokes have their
        // own modifier state, independent of physical keys currently held down.
        guard let eventSource = CGEventSource(stateID: .privateState) else {
            print("❌ Failed to create CGEventSource")
            completion()
            return
        }

        // The virtual keycode for 'C' is 8 (from Carbon's Events.h / kVK_ANSI_C)
        let keyCodeC: CGKeyCode = 8  // kVK_ANSI_C

        // Create key-down event for Cmd+C using our private event source
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCodeC, keyDown: true) else {
            print("❌ Failed to create CGEvent key-down")
            completion()
            return
        }

        // Create key-up event for Cmd+C using our private event source
        guard let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCodeC, keyDown: false) else {
            print("❌ Failed to create CGEvent key-up")
            completion()
            return
        }

        // Set flags to ONLY Command — this overrides any physical modifier state.
        // Without this, the Option key (still physically held from our hotkey)
        // would leak into the event, turning Cmd+C into Cmd+Option+C.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post at the CGAnnotatedSession tap level. This inserts the event into
        // the current login session's event stream and routes it to the focused app.
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        print("⌨️ Posted Cmd+C via CGEvent (private source) to frontmost app")

        // Poll for pasteboard changes every 20ms, up to 500ms.
        // 20ms is fast enough to catch quick apps (TextEdit, Terminal) on the first poll
        // while still giving heavy apps (Electron, IDEs) up to 500ms.
        var attempts = 0
        let pollInterval: TimeInterval = 0.02
        let maxAttempts = 25  // 25 × 20ms = 500ms max
        func checkPasteboard() {
            attempts += 1
            if pasteboard.changeCount > changeCountBefore {
                print("✂️ Text copied to clipboard (pasteboard changed after \(attempts * 20)ms)")
                completion()
            } else if attempts >= maxAttempts {
                print("⚠️ Pasteboard unchanged after \(maxAttempts * 20)ms — no text was selected, or app too slow")
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                    checkPasteboard()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            checkPasteboard()
        }
    }

    /// Outcome of a paste-back attempt.
    enum PasteOutcome {
        /// Cmd+V was posted to the source app. Caller should toast "Replaced selection".
        case pasted
        /// Source app was no longer frontmost at paste time (user switched apps,
        /// tabs, DMs, etc.). The response has been written to the clipboard and
        /// the caller should toast "Response copied — switch back and ⌘V to paste".
        case copiedForManualPaste
        /// Accessibility revoked or CGEvent creation failed. Caller should show
        /// an error toast.
        case failed
    }

    /// Attempts to paste `text` into the app identified by `bundleId`.
    ///
    /// Three-way frontmost check at paste time:
    /// - **Source app is frontmost** → paste directly.
    /// - **Cai itself is frontmost** → Cai's activation is sticky after panel
    ///   dismiss (macOS doesn't auto-yield). Activate the source app, wait
    ///   briefly for focus to swap, then paste. This is the normal path for
    ///   both the chip click and auto-replace.
    /// - **Some other app is frontmost** → user actively switched during
    ///   generation (different tab, app, DM). Don't yank them back; copy
    ///   the text and return `.copiedForManualPaste` so they can ⌘V at will.
    ///
    /// Completion fires `.pasted` immediately after the CGEvent post (not
    /// after the 400ms snapshot restore) so callers can update UI without
    /// waiting.
    ///
    /// Requirements: Accessibility permission, App Sandbox disabled. Keycode
    /// for V is 9 (kVK_ANSI_V).
    func pasteResult(_ text: String, toBundleId bundleId: String?, completion: @escaping (PasteOutcome) -> Void) {
        // Completion always fires on main — callers update UI from it. Defined
        // first so every exit (including the preflight failure) routes through it.
        let finish: (PasteOutcome) -> Void = { outcome in
            DispatchQueue.main.async { completion(outcome) }
        }

        // Preflight: without accessibility, CGEventSource builds fine but the
        // posted event is silently dropped. Call AXIsProcessTrusted() directly
        // rather than PermissionsManager.shared.hasAccessibilityPermission —
        // the latter is a cached @Published property refreshed by a poll timer,
        // so recently-revoked permission can still read as granted.
        guard AXIsProcessTrusted() else {
            print("❌ Paste aborted — accessibility permission missing")
            finish(.failed)
            return
        }

        // Frontmost detection and app activation are AppKit-main-affine, so
        // resolve them here on the calling thread (always main). Only the
        // pasteboard byte ops below run on the serial queue.
        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let caiBundleId = Bundle.main.bundleIdentifier
        let sourceIsFrontmost = bundleId != nil && bundleId == frontmostBundleId
        let caiIsFrontmost = frontmostBundleId != nil && frontmostBundleId == caiBundleId

        // Case 3: user actively moved to an unrelated app. Respect it — don't
        // force-activate the source (would leak AI output into the wrong
        // context, e.g. Slack DM with the wrong person). Copy instead.
        if !sourceIsFrontmost && !caiIsFrontmost && bundleId != nil {
            PasteboardQueue.shared.write {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                print("📋 User moved from \(bundleId ?? "nil") to \(frontmostBundleId ?? "unknown"); copied for manual paste")
                finish(.copiedForManualPaste)
            }
            return
        }

        // Case 2: Cai is still frontmost (panel just dismissed or we never left).
        // Activate the source app and give the WindowServer a moment to swap
        // focus before posting Cmd+V.
        let activationDelay: TimeInterval
        if caiIsFrontmost,
           let id = bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate(options: [])
            activationDelay = 0.08
        } else {
            // Case 1: source is already frontmost, or no bundle id known.
            activationDelay = 0
        }

        // Snapshot -> set -> Cmd+V -> conditional restore runs as ONE serial-queue
        // block, holding the pasteboard lane from snapshot through restore so a
        // second concurrent paste-back can't interleave and clobber the clipboard.
        PasteboardQueue.shared.write {
            if activationDelay > 0 {
                Thread.sleep(forTimeInterval: activationDelay)
            }

            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let ourChangeCount = pasteboard.changeCount

            guard let eventSource = CGEventSource(stateID: .privateState),
                  let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: false) else {
                print("❌ Failed to create CGEvent for paste")
                snapshot.restore(to: pasteboard)
                finish(.failed)
                return
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)

            print("⌨️ Posted Cmd+V via CGEvent to \(bundleId ?? "frontmost app")")

            // Fire completion immediately so the caller can dismiss UI, then keep
            // holding the lane through the restore window. 400ms is enough for
            // fast apps (~50ms) through slow Electron (~200ms). Skip the restore
            // if changeCount moved (another process wrote during the window).
            finish(.pasted)

            Thread.sleep(forTimeInterval: 0.4)
            if pasteboard.changeCount == ourChangeCount {
                snapshot.restore(to: pasteboard)
            }
        }
    }

    /// Snapshot of every NSPasteboardItem on the pasteboard at a moment in time.
    /// Captures every declared type per item as raw Data, so images, file URLs,
    /// RTF, plain text etc. all survive a clear + restore cycle. NSPasteboardItem
    /// instances themselves are invalidated by `clearContents()`, so we can't
    /// just hang on to the original objects: we have to extract the data eagerly
    /// and rebuild fresh items on restore.
    private struct PasteboardSnapshot {
        private let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard) {
            self.items = pasteboard.pasteboardItems?.map { item in
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dict[type] = data
                    }
                }
                return dict
            } ?? []
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let fresh = items.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(fresh)
        }
    }

    /// Reads text content from the system clipboard
    /// - Returns: Trimmed text content, or nil if clipboard is empty or doesn't contain text
    ///
    /// Runs the read on `PasteboardQueue` (off the main thread) so a slow
    /// pasteboard daemon — e.g. Universal Clipboard fetching a paired-device
    /// copy — can't freeze the ⌥C hot path.
    func readClipboard() async -> String? {
        let content = await PasteboardQueue.shared.read { NSPasteboard.general.string(forType: .string) }

        guard let content else {
            print("📋 Clipboard is empty or doesn't contain text")
            return nil
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            print("📋 Clipboard contains only whitespace")
            return nil
        }

        // Deliberately log length only — clipboard content may include passwords,
        // API keys, or other secrets that must never leave the process.
        print("📋 Clipboard read: \(trimmed.count) chars")
        return trimmed
    }

    /// Reads everything the detection path needs in ONE PasteboardQueue hop, then
    /// resolves it (OCR + disk image load) OFF the lane. Replaces the previous
    /// chain of separate async reads, which weren't atomic — a write landing
    /// between them let the ⌥C window / history poll act on a mix of two clipboard
    /// states. Returns the resolved content plus the `changeCount` observed in the
    /// same snapshot, so callers set their poll baseline from the same read.
    ///
    /// `isConcealed` is true when the same snapshot carried a concealed/transient
    /// marker type (password managers set these — see `RecentClipsMenuModel`).
    /// Callers that record into `ClipboardHistory` must skip recording when set,
    /// so marked secrets never enter history. Read in the SAME lane occupancy as
    /// the content, so Cai's own reads and writes can't interleave between the
    /// two. (Another process writing mid-occupancy can still slip between the
    /// individual pboardd round-trips — a tiny window this shares with the
    /// content reads themselves.)
    func readClipboardContent() async -> (content: ClipboardContent, changeCount: Int, isConcealed: Bool) {
        // Capture raw materials in a SINGLE lane occupancy — pasteboard reads only.
        // No OCR, no disk I/O, and no nested PasteboardQueue call (re-entering the
        // serial queue would self-deadlock).
        let capture: RawClipboardCapture = await PasteboardQueue.shared.read {
            let pb = NSPasteboard.general
            let fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: [
                NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true
            ]) as? [URL]) ?? []
            return RawClipboardCapture(
                fileURLs: fileURLs,
                text: pb.string(forType: .string),
                image: NSImage(pasteboard: pb),
                changeCount: pb.changeCount,
                // Union across ALL items, not `pb.types` (which reflects only
                // the first item): a writer can declare the concealed marker on
                // a secondary NSPasteboardItem, and missing it would record the
                // secret. `pb.types` stays in as a legacy-writer fallback.
                isConcealed: RecentClipsMenuModel.containsSensitiveType(
                    ((pb.pasteboardItems ?? []).flatMap(\.types) + (pb.types ?? [])).map(\.rawValue)
                )
            )
        }

        // Resolve OFF the lane, preserving the original priority: image file
        // (OCR; nil → fall through, since Finder puts BOTH a file URL and the path
        // string) > plain text > image data > empty.
        if let ocrText = OCRService.shared.ocrImageFiles(capture.fileURLs) {
            return (.imageText(ocrText), capture.changeCount, capture.isConcealed)
        }
        if let raw = capture.text {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (.text(trimmed), capture.changeCount, capture.isConcealed)
            }
        }
        if let image = capture.image, let ocrText = OCRService.shared.ocrImage(image) {
            return (.imageText(ocrText), capture.changeCount, capture.isConcealed)
        }
        let hadImage = capture.image != nil
            || capture.fileURLs.contains { OCRService.imageExtensions.contains($0.pathExtension.lowercased()) }
        return (.empty(hadImage: hadImage), capture.changeCount, capture.isConcealed)
    }

    /// Raw clipboard materials captured in one lane occupancy, resolved off-lane.
    private struct RawClipboardCapture {
        let fileURLs: [URL]
        let text: String?
        let image: NSImage?
        let changeCount: Int
        let isConcealed: Bool
    }
}
