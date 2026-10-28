import AppKit
import HotKey

class HotKeyManager {
    private var hotKey: HotKey?
    private var handler: (() -> Void)?

    init() {
        // Re-register when user changes the hotkey in Settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotKeySettingChanged),
            name: .caiHotKeyChanged,
            object: nil
        )
    }

    func register(handler: @escaping () -> Void) {
        // Only register if we don't already have a hotkey
        guard hotKey == nil else {
            print("⚠️ HotKey already registered")
            return
        }

        // Check if accessibility permission is granted
        guard PermissionsManager.shared.hasAccessibilityPermission else {
            print("❌ Cannot register hotkey: Accessibility permission not granted")
            return
        }

        let combo = CaiSettings.shared.keyCombo
        hotKey = HotKey(keyCombo: combo)
        self.handler = handler

        hotKey?.keyDownHandler = { [weak self] in
            print("⌨️ Hotkey triggered: \(combo)")
            self?.handler?()
        }

        print("✅ Global hotkey registered: \(combo)")
    }

    func unregister() {
        hotKey = nil
        print("🔕 Global hotkey unregistered")
    }

    // MARK: - Pre-panel digit slots

    /// Transient ⌥0–9 hotkeys, live only between the main hotkey firing and the
    /// panel's key monitor coming up (the ⌘C capture can take up to 500 ms).
    /// Without them a fast ⌥C ⌥2 types "™" into the source app, over the very
    /// selection the user meant to act on. The first digit is buffered for replay.
    private var slotHotKeys: [HotKey] = []
    private var bufferedSlot: Int?

    func armSlotKeys(modifiers: NSEvent.ModifierFlags) {
        disarmSlotKeys()
        for (slot, key) in Self.digitKeys.enumerated() {
            // If another app already owns the combo, that app may keep it; the
            // digit then just isn't replayed, and ⌘digit in the panel still works.
            let hotKey = HotKey(key: key, modifiers: modifiers)
            hotKey.keyDownHandler = { [weak self] in
                if self?.bufferedSlot == nil { self?.bufferedSlot = slot }
            }
            slotHotKeys.append(hotKey)
        }
    }

    /// Unregisters the transient digit hotkeys and returns the buffered slot, if any.
    @discardableResult
    func disarmSlotKeys() -> Int? {
        slotHotKeys.removeAll()  // HotKey unregisters in deinit
        defer { bufferedSlot = nil }
        return bufferedSlot
    }

    private static let digitKeys: [Key] = [.zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine]

    func isRegistered() -> Bool {
        return hotKey != nil
    }

    /// Re-registers with the current settings combo, preserving the existing handler.
    @objc private func hotKeySettingChanged() {
        guard let handler = handler else { return }
        unregister()
        register(handler: handler)
    }
}
