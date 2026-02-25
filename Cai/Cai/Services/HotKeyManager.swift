import Foundation
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
