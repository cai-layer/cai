import AppKit

/// Process-wide serializer for every `NSPasteboard.general` content read/write.
///
/// Why this exists: `NSPasteboard` is not thread-safe, and a synchronous content
/// read can block for seconds on the pasteboard daemon (`pbs`) when the system is
/// fetching a Universal Clipboard / Handoff item over the network, or for a large
/// or promise-backed item. Doing those reads on the main thread froze the Option+C
/// hot path and the clipboard-history poll (Sentry AppHangs on 1.5.0).
///
/// Funnelling every access onto ONE serial queue does two things at once:
///   1. moves the blocking read off the main thread, so the runloop never hangs;
///   2. guarantees a single reader/writer at a time, which the previous
///      "everything on main" workaround was protecting against -- two concurrent
///      readers crashed in `__NSFastEnumerationMutationHandler` while AppKit was
///      iterating pasteboard types.
///
/// Deliberately a serial `DispatchQueue`, NOT an `actor`: paste-back must hold the
/// pasteboard exclusively across a ~0.4s restore window, and a Swift actor releases
/// isolation at every `await` (reentrancy), so a second paste-back would interleave
/// and clobber the clipboard. A serial-queue block holds the lane from entry to
/// return. Do NOT convert this to an actor.
///
/// Invariant: every pasteboard content touch in the app goes through `read` or
/// `write`. Never call back into the queue from inside a queue block -- a serial
/// queue would self-deadlock. (Cheap `changeCount` probes may stay on the caller's
/// thread: that property is cached and does not iterate the items array.)
final class PasteboardQueue {
    static let shared = PasteboardQueue()
    private init() {}

    private let queue = DispatchQueue(label: "com.soyasis.cai.pasteboard", qos: .userInitiated)

    /// Runs `body` on the serial pasteboard queue and returns its result. The
    /// `await` suspends off the main thread, so a slow pasteboard daemon never
    /// blocks the runloop.
    func read<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Runs `body` on the serial pasteboard queue, fire-and-forget, so callers
    /// (SwiftUI views, menu actions) stay synchronous. The write still serializes
    /// against every other pasteboard operation.
    func write(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }
}
