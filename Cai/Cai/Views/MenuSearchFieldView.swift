import AppKit

/// Search field hosted in the status-item menu (an `NSMenuItem.view`). It takes
/// focus as soon as the menu opens and keeps it, so every letter filters the
/// clips instead of triggering NSMenu's type-select. Return copies the first
/// match; Esc closes the menu, as in any macOS menu (the query lives only as
/// long as the menu, so there is nothing to clear first). Arrow keys are left
/// to the field: handing them to the menu would strand focus there, and the
/// next letter would jump rows instead of refining the search.
final class MenuSearchFieldView: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    private let field = NSSearchField()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        autoresizingMask = .width
        field.placeholderString = "Search clips"
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The menu window exists but is mid-setup; focus on the next pass of
        // the run loop, in the tracking mode the open menu runs in.
        RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self.field)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            enclosingMenuItem?.menu?.cancelTracking()
            return true
        default:
            return false
        }
    }
}
