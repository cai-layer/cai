import Foundation

#if DEBUG
/// Dev-only main-thread watchdog. Pings the main queue from a background
/// queue; if a ping isn't serviced within `threshold`, the main thread is
/// blocked (the beachball class of bug: sync pasteboard reads, blocking
/// network, MLX work on main). Once the main thread recovers, prints how long
/// it was blocked so hangs surface during development instead of in prod.
/// Compiled out of Release builds entirely. Logs locally only.
enum MainThreadWatchdog {
    /// Anything past this is a hang worth knowing about. Sub-100ms stalls are
    /// normal (window creation, first SwiftUI render).
    private static let threshold: TimeInterval = 0.25
    private static let pingInterval: TimeInterval = 0.1
    private static let queue = DispatchQueue(label: "com.soyasis.cai.watchdog", qos: .utility)
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        queue.async { loop() }
    }

    private static func loop() {
        while true {
            let sent = DispatchTime.now()
            let pong = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { pong.signal() }
            if pong.wait(timeout: sent + threshold) == .timedOut {
                pong.wait()  // block until the main thread services the ping
                let blockedMs = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
                print(String(format: "🐶 Watchdog: main thread was blocked for %.0f ms", blockedMs))
            }
            Thread.sleep(forTimeInterval: pingInterval)
        }
    }
}
#endif
