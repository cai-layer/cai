import AppKit
import Carbon

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

    /// Pastes `text` into the app identified by `bundleId` by simulating Cmd+V.
    ///
    /// Flow: snapshot the whole pasteboard (every item, every type) so images,
    /// file URLs, and rich text survive the round trip. Re-activate the source
    /// app (Cai has stolen focus by now), briefly wait for the activation to
    /// take effect, overwrite the pasteboard with `text`, post Cmd+V via CGEvent
    /// (same private-source + flag-override trick as copy), then restore the
    /// snapshot after a short delay.
    ///
    /// `completion(true)` is called only if the paste was actually posted.
    /// Any early exit (CGEventSource creation fail, CGEvent build fail) restores
    /// the snapshot first and calls `completion(false)` so callers can show an
    /// accurate "something broke" toast instead of a misleading success.
    ///
    /// Requirements mirror `copySelectedText`: Accessibility permission, App
    /// Sandbox disabled. Keycode for V is 9 (kVK_ANSI_V).
    func pasteResult(_ text: String, toBundleId bundleId: String?, completion: @escaping (Bool) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)

        // Re-activate the source app if known. Without this, Cmd+V would be
        // delivered to Cai (frontmost after the panel became key).
        let reactivationDelay: TimeInterval
        if let bundleId = bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: [])
            reactivationDelay = 0.08  // Give the WindowServer a moment to swap focus
        } else {
            reactivationDelay = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + reactivationDelay) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            guard let eventSource = CGEventSource(stateID: .privateState) else {
                print("❌ Failed to create CGEventSource for paste")
                snapshot.restore(to: pasteboard)
                completion(false)
                return
            }

            let keyCodeV: CGKeyCode = 9  // kVK_ANSI_V

            guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCodeV, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCodeV, keyDown: false) else {
                print("❌ Failed to create CGEvent for paste")
                snapshot.restore(to: pasteboard)
                completion(false)
                return
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand

            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)

            print("⌨️ Posted Cmd+V via CGEvent to \(bundleId ?? "frontmost app")")

            // Restore the snapshot after a delay long enough for the target
            // app to consume our text. 400ms is conservative: fast apps finish
            // the paste in ~50ms, slow Electron apps can take ~200ms.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                snapshot.restore(to: pasteboard)
                completion(true)
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
    func readClipboard() -> String? {
        let pasteboard = NSPasteboard.general

        guard let content = pasteboard.string(forType: .string) else {
            print("📋 Clipboard is empty or doesn't contain text")
            return nil
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            print("📋 Clipboard contains only whitespace")
            return nil
        }

        print("📋 Clipboard read: \(trimmed.prefix(50))\(trimmed.count > 50 ? "..." : "")")
        return trimmed
    }
}
