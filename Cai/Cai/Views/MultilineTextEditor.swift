import AppKit
import SwiftUI

/// Multi-line text editor that wraps `NSTextView` with the two key bindings
/// SwiftUI's stock components get wrong on macOS:
///
/// - **Plain Return → inserts newline** (NSTextView default).
///   `TextField(axis: .vertical)` swallows Return on macOS — the event
///   never produces a newline. Users can't write multi-line content.
///
/// - **⌘⏎ → forwarded to next responder** so the form-level
///   `.keyboardShortcut(.return, modifiers: .command)` on the Save button
///   fires. NSTextView's default treats ⌘⏎ as `insertLineBreak:` which
///   consumes the event before SwiftUI sees it (the very reason
///   `LLMEditPopover` had to abandon `TextEditor`).
///
/// - **Esc → forwarded** so `.keyboardShortcut(.cancelAction)` on the
///   Cancel button fires.
///
/// Use this for multi-line form fields where users need both:
/// (a) a real text editor with newline-on-Return, and
/// (b) ⌘⏎ to save / Esc to cancel the parent form.
///
/// **Visual styling:** matches the unified input shell from the editor
/// redesign — `caiSurface`-tinted background, 0.5px separator border (or
/// 1px `caiPrimary` on focus). Caller adds the rounded background; this
/// view renders the editor itself with no chrome.
///
/// **Auto-expanding height (2026-05-06):** the editor measures its
/// rendered content via `NSLayoutManager` and self-frames to that height,
/// clamped to `[minLines, maxLines] * lineHeight`. Beyond `maxLines`, the
/// inner `NSScrollView` scrolls. Caller does NOT add their own
/// `.frame(minHeight:maxHeight:)` — the editor handles it.
struct MultilineTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = false
    var fontSize: CGFloat = 12
    /// Default visible-line count when the editor is empty. Combined with
    /// `maxLines`, gives "1 line tall by default, grow with content,
    /// scroll beyond 4 lines" — matches Linear / Notion / Apple Mail
    /// composer UX. Two-line defaults are a web-form holdover; modern
    /// macOS composers all start at one line and grow.
    var minLines: Int = 1
    var maxLines: Int = 4
    /// When true, the editor takes first-responder focus once added to a
    /// window. Use for popovers where the user expects to start typing
    /// immediately on open (e.g. the inline LLM directive editor).
    var autoFocus: Bool = false
    /// Fired when the user presses ⌘⏎. Bypasses SwiftUI's `keyboardShortcut`
    /// chain (which doesn't cooperate cleanly with NSTextView's responder
    /// chain). Set this to the parent form's save action.
    var onCommit: (() -> Void)? = nil
    /// Fired when the user presses Esc. Same rationale as `onCommit`.
    var onCancel: (() -> Void)? = nil

    /// Height of the rendered content as measured by `NSLayoutManager` —
    /// updated whenever the text changes or the view is laid out. Drives
    /// the outer frame so the editor grows/shrinks with content.
    @State private var measuredHeight: CGFloat = 0

    /// Smallest height the editor renders at — `minLines × lineHeight`.
    /// The editor never shrinks below this even when empty.
    private var minHeight: CGFloat { ceil(fontSize * 1.4 * CGFloat(minLines)) }
    /// Largest height before scrolling kicks in — `maxLines × lineHeight`.
    /// Beyond this, the `NSScrollView` clips and scrolls internally.
    private var maxHeight: CGFloat { ceil(fontSize * 1.4 * CGFloat(maxLines)) }

    /// Final clamped height fed into `.frame(height:)`. Initial render
    /// (before measurement) uses `minHeight` so layout doesn't jump.
    private var clampedHeight: CGFloat {
        let target = measuredHeight > 0 ? measuredHeight : minHeight
        return min(maxHeight, max(minHeight, target))
    }

    var body: some View {
        _MultilineTextEditorRepresentable(
            text: $text,
            placeholder: placeholder,
            monospaced: monospaced,
            fontSize: fontSize,
            autoFocus: autoFocus,
            onCommit: onCommit,
            onCancel: onCancel,
            onMeasure: { height in
                // Round to 0.5pt steps to suppress sub-pixel jitter as
                // NSLayoutManager re-measures during typing.
                let rounded = (height * 2).rounded() / 2
                if abs(rounded - measuredHeight) > 0.5 {
                    measuredHeight = rounded
                }
            }
        )
        .frame(height: clampedHeight)
    }
}

/// Internal `NSViewRepresentable` that hosts the actual `NSTextView` /
/// `NSScrollView` pair. The wrapping `MultilineTextEditor` View owns the
/// `@State` height and frames this view accordingly.
private struct _MultilineTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var monospaced: Bool
    var fontSize: CGFloat
    var autoFocus: Bool
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fired with the rendered content height (from `NSLayoutManager`)
    /// after every text change and after initial layout.
    var onMeasure: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = ForwardingTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = effectiveFont
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.placeholderString = placeholder
        textView.shouldAutoFocusOnFirstAppear = autoFocus
        textView.onCommit = onCommit
        textView.onCancel = onCancel
        // Let NSTextView's text container resize horizontally to whatever
        // the scroll view gives us — but never grow vertically beyond the
        // scroll view's clip view (so word-wrap kicks in instead of the
        // text running off the right edge).
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        scrollView.documentView = textView

        // Measure once on next runloop tick — the layout manager needs
        // the view to be in a window with a known frame before
        // `usedRect(for:)` returns meaningful values.
        DispatchQueue.main.async { [onMeasure] in
            measureHeight(textView, fontSize: fontSize, report: onMeasure)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ForwardingTextView else { return }
        // Avoid stomping the user's caret position when SwiftUI re-renders
        // for a reason unrelated to the text content.
        if textView.string != text {
            textView.string = text
        }
        textView.font = effectiveFont
        textView.placeholderString = placeholder
        // Refresh callbacks each render — captures the latest closure
        // (parent's @State / bindings may have changed).
        textView.onCommit = onCommit
        textView.onCancel = onCancel
        // Re-measure on every update so external text changes (e.g. the
        // form being reset for a new add) reflect in the editor height.
        DispatchQueue.main.async { [onMeasure] in
            measureHeight(textView, fontSize: fontSize, report: onMeasure)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private var effectiveFont: NSFont {
        monospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: _MultilineTextEditorRepresentable

        init(_ parent: _MultilineTextEditorRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            measureHeight(textView, fontSize: parent.fontSize, report: parent.onMeasure)
        }
    }
}

/// Free function (not a method) so it can be called from both the
/// representable's lifecycle hooks and the coordinator's delegate
/// callback without capturing self.
///
/// Asks the layout manager for the actual rendered text height, falling
/// back to a single empty line when there's no content yet. The 1.4×
/// line-height multiplier matches NSTextView's defaults for system
/// fonts; we use it as a floor so an empty editor still gets one full
/// line of breathing room (rather than collapsing to zero).
private func measureHeight(_ textView: NSTextView, fontSize: CGFloat, report: (CGFloat) -> Void) {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
    lm.ensureLayout(for: tc)
    let used = lm.usedRect(for: tc)
    let oneLine = ceil(fontSize * 1.4)
    let height = ceil(max(used.height, oneLine) + 2 * textView.textContainerInset.height)
    report(height)
}

// MARK: - NSTextView subclass with placeholder + key forwarding

/// `NSTextView` subclass that:
/// - Renders a placeholder when empty (NSTextView has no built-in
///   placeholder support).
/// - Forwards `⌘⏎` and `Esc` to the next responder so the parent form's
///   keyboard shortcuts fire instead of being eaten by the text view.
private final class ForwardingTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }
    var shouldAutoFocusOnFirstAppear: Bool = false
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private var hasAutoFocused: Bool = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shouldAutoFocusOnFirstAppear, !hasAutoFocused, window != nil else { return }
        hasAutoFocused = true
        // Defer to next runloop tick so the window's responder chain is
        // fully wired before we ask it to make us first responder.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    /// Intercept ⌘⏎ at performKeyEquivalent (fires BEFORE keyDown). Direct
    /// callback bypasses SwiftUI's `.keyboardShortcut` chain entirely —
    /// experiments showed forwarding via `nextResponder` doesn't reliably
    /// route to the form's Save button when focus is in NSTextView.
    /// Returning `true` marks the event handled so NSTextView's default
    /// `insertLineBreak:` doesn't also fire.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if cmd, event.charactersIgnoringModifiers == "\r" {
            if let onCommit = onCommit {
                onCommit()
                return true
            }
            return false  // no callback wired — let it propagate
        }
        return super.performKeyEquivalent(with: event)
    }

    /// When "Return to submit" is enabled, a bare Return commits the form just
    /// like ⌘⏎ (Shift/Option/Control+Return still insert a newline). Uses the same
    /// `WindowController.returnSubmitsPrompt` predicate as the floating-window
    /// composer, so the rule is identical everywhere. `submitScreenActive: true`
    /// because reaching here means we have an `onCommit` to fire.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let onCommit = onCommit {  // Return
            // ⌘⏎ always commits; a bare Return commits when "Return to submit" is on.
            // (Shift/Option/Control+Return fall through to insert a newline.) ⌘⏎ is
            // normally caught by performKeyEquivalent, but handle it here too so it
            // works even if that path is pre-empted.
            let onlyCommand = event.modifierFlags.intersection([.shift, .option, .control, .command]) == [.command]
            let bareSubmit = WindowController.returnSubmitsPrompt(
                pressReturnToSend: CaiSettings.shared.pressReturnToSend,
                submitScreenActive: true,
                modifiers: event.modifierFlags
            )
            if onlyCommand || bareSubmit {
                onCommit()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Esc → fire onCancel callback directly. Same rationale as ⌘⏎: the
    /// SwiftUI shortcut chain was being intercepted by Cai's window-level
    /// Esc handler before the form's Cancel button could see it.
    override func cancelOperation(_ sender: Any?) {
        if let onCancel = onCancel {
            onCancel()
        } else {
            nextResponder?.cancelOperation(sender)
        }
    }

    /// Tab → move focus to the next form field instead of inserting a
    /// tab character. Standard macOS form-field convention. Note: SwiftUI
    /// doesn't always wire its hosted views into the AppKit key view loop,
    /// so this can be a no-op in some contexts. Acceptable degradation —
    /// user can click between fields.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    // Placeholder rendering — drawn behind the text when string is empty.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.4)
        ]
        let inset = textContainerInset
        let origin = NSPoint(
            x: inset.width + (textContainer?.lineFragmentPadding ?? 5),
            y: inset.height
        )
        placeholderString.draw(at: origin, withAttributes: attrs)
    }
}

// MARK: - Form field shell modifier
//
// Shared visual treatment for ALL form input fields across both editors
// (Custom Actions + Destinations). One source of truth for background,
// border, focus highlight — change here, propagates everywhere.

extension View {
    /// Wraps a form input field in the standard Cai input shell:
    /// `caiSurface`-tinted background, hairline separator border (or
    /// `caiPrimary` border when `focused`), 6pt corner radius, 8pt inner
    /// padding. Use for all form text inputs (multi-line and single-line)
    /// to keep visual rhythm consistent across editors.
    func formFieldShell(focused: Bool = false) -> some View {
        self
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        focused ? Color.caiPrimary.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5),
                        lineWidth: focused ? 1.0 : 0.5
                    )
            )
    }
}
