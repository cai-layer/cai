import SwiftUI
import HotKey

/// Inline shortcut recorder — click to record, type a key combo, click out to save.
/// Zen browser-style: shows current combo or "Not set", captures on keyDown.
struct ShortcutRecorderView: NSViewRepresentable {
    @ObservedObject var settings = CaiSettings.shared

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onComboChanged = { combo in
            if let combo = combo {
                settings.keyCombo = combo
            } else {
                settings.resetHotKey()
            }
        }
        view.currentCombo = settings.keyCombo
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        if !nsView.isRecording {
            nsView.currentCombo = settings.keyCombo
            nsView.updateDisplay()
        }
    }
}

/// AppKit view that captures keyboard events for shortcut recording.
class ShortcutRecorderNSView: NSView {
    var currentCombo: KeyCombo?
    var isRecording = false
    var onComboChanged: ((KeyCombo?) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        // Label
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Clear button (×)
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.title = "\u{2715}" // ✕
        clearButton.font = .systemFont(ofSize: 10, weight: .regular)
        clearButton.target = self
        clearButton.action = #selector(clearCombo)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isHidden = true
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),

            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
        ])

        updateDisplay()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 24)
    }

    // MARK: - Display

    func updateDisplay() {
        if isRecording {
            label.stringValue = "Type shortcut..."
            label.textColor = .tertiaryLabelColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 1.5
            clearButton.isHidden = true
        } else if let combo = currentCombo {
            label.stringValue = combo.description
            label.textColor = .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            clearButton.isHidden = false
            clearButton.contentTintColor = .tertiaryLabelColor
        } else {
            label.stringValue = "Not set"
            label.textColor = .tertiaryLabelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            clearButton.isHidden = true
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            startRecording()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isRecording {
            NSCursor.pointingHand.push()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        updateDisplay()
    }

    private func stopRecording() {
        isRecording = false
        updateDisplay()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording
        if event.keyCode == 53 { // Escape
            stopRecording()
            return
        }

        // Capture the key combo
        guard let key = Key(carbonKeyCode: UInt32(event.keyCode)) else { return }

        // Filter modifier flags to only include relevant ones
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let combo = KeyCombo(key: key, modifiers: modifiers)

        currentCombo = combo
        onComboChanged?(combo)
        stopRecording()
    }

    override func flagsChanged(with event: NSEvent) {
        // Don't capture modifier-only presses — wait for a real key
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            stopRecording()
        }
        return super.resignFirstResponder()
    }

    // MARK: - Clear

    @objc private func clearCombo() {
        currentCombo = nil
        onComboChanged?(nil)
        updateDisplay()
    }
}
