import Foundation

/// Watches the pending-changes directory and calls back when it changes.
///
/// A `DispatchSource` file-system object source rather than polling: the
/// directory is usually empty and a proposal should reach the menu bar the
/// moment the agent's write lands, without a timer waking the machine.
///
/// Writes arrive as temp-file-plus-rename, which fires several events in a
/// row; the callback is debounced so a single proposal triggers one rescan.
@MainActor
final class PendingChangeWatcher {

    private let directory: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounceWork: DispatchWorkItem?
    /// Inode the descriptor is attached to, so a directory swapped out from
    /// under us can be detected.
    private var watchedInode: ino_t?

    init(directory: URL, debounce: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        // `stop()` is MainActor-isolated and deinit is not; close the
        // descriptor directly so a dropped watcher can't leak one.
        source?.cancel()
    }

    func start() {
        guard source == nil else { return }

        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            print("PendingChanges: could not watch \(directory.path) (errno \(errno))")
            return
        }
        watchedInode = Self.inode(of: directory)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRescan()
        }
        // The handle is closed exactly once, when the source is done with it.
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        source?.cancel()
        source = nil
        descriptor = -1
        watchedInode = nil
    }

    /// False once the path no longer resolves to the inode the descriptor
    /// holds.
    ///
    /// A `DispatchSource` follows the inode, not the path, so an atomic
    /// replacement of the directory (`mkdir new; mv new pending-changes`, a
    /// migration, a restore, a cleanup tool) leaves the watcher attached to an
    /// unlinked directory. `fileExists` still reports true, so nothing looks
    /// wrong while no event ever fires again and authoring is quietly dead.
    func isWatchingCurrentDirectory() -> Bool {
        guard let watchedInode else { return false }
        return Self.inode(of: directory) == watchedInode
    }

    private static func inode(of url: URL) -> ino_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_ino
    }

    private func scheduleRescan() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
