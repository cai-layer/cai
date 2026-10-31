import AppKit
import SwiftUI

/// Shows `FocusTimerPill` the way a menu opens: flush under the menu bar,
/// centred on the countdown, no arrow. NSPopover always draws an arrow and a
/// gap, and slides its body sideways near the screen edge, so the pill
/// floated away from the digits it belongs to.
@MainActor
final class FocusTimerPillPanel {
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var timerObserver: NSObjectProtocol?

    var isShown: Bool { panel != nil }

    /// `anchor` is the countdown's rect in screen coordinates.
    func show(under anchor: NSRect, on screen: NSScreen?, send: @escaping (FocusTimerEvent) -> Void) {
        close()

        let hosting = NSHostingView(rootView: FocusTimerPill(state: FocusTimerController.shared.state, send: { [weak self] event in
            send(event)
            if FocusTimerController.shared.state.phase == nil { self?.close() }
        }))
        let size = hosting.fittingSize

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        // Centred on the digits, flush under the menu bar, kept on screen.
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 1)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = effect
        panel.orderFrontRegardless()
        self.panel = panel

        // Close like a menu: a click anywhere else, Esc, or Cai losing focus.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Esc closes it only when no other Cai window has the keyboard, so it
        // never eats an Esc meant for Settings, a shortcut recorder or the
        // action panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, NSApp.keyWindow == nil else { return event }  // Esc
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
        // However the timer goes idle (a break running out, Stop Timer from
        // the menu), the pill goes with it: its controls do nothing on idle.
        timerObserver = NotificationCenter.default.addObserver(
            forName: .caiFocusTimerChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if FocusTimerController.shared.state.phase == nil { self?.close() }
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let timerObserver { NotificationCenter.default.removeObserver(timerObserver) }
        outsideClickMonitor = nil
        keyMonitor = nil
        resignObserver = nil
        timerObserver = nil
    }
}
