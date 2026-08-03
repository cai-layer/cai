import CaiActionCore
import Foundation

/// Publishes what the app knows about its actions, for the `cai-mcp` helper.
///
/// The helper cannot ask the app anything, so the app tells it: this file is
/// the entire outbound half of the handoff. It is rewritten whenever the
/// user's actions change, which is what lets an agent see a rename before it
/// proposes a chain step against the old name.
///
/// Debounced, because `caiInvalidateActionCache` fires on every keystroke-level
/// change in the shortcuts editor and this does file IO.
@MainActor
final class ActionsSnapshotPublisher {

    static let shared = ActionsSnapshotPublisher()

    private let root: URL
    private var observer: NSObjectProtocol?
    private var pendingWrite: DispatchWorkItem?
    private let debounce: TimeInterval

    init(root: URL = CaiSupportPaths.root, debounce: TimeInterval = 0.5) {
        self.root = root
        self.debounce = debounce
    }

    /// Writes once now, then keeps the file current.
    ///
    /// Published even when the kill switch is off: the flag travels inside the
    /// snapshot, so the helper can tell an agent "the user turned this off"
    /// instead of "Cai has never run", which are very different things to act on.
    func start() {
        publishNow()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .caiInvalidateActionCache,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePublish() }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        pendingWrite?.cancel()
        pendingWrite = nil
    }

    private func schedulePublish() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.publishNow() }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func publishNow() {
        let settings = CaiSettings.shared
        let known = settings.knownActions
        let snapshot = ActionsSnapshot(
            generatedAt: Date(),
            actions: known.shortcuts,
            destinations: known.destinations,
            builtInActionNames: known.builtInActionNames,
            agentAuthoringEnabled: settings.allowAgentProposals
        )

        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = CaiSupportPaths.actionsSnapshot(in: root)
            try ActionCoding.encoder.encode(snapshot).write(to: url, options: [.atomic])
            // The user's own prompts and commands, so the same 0600 as
            // everything else in this directory.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("Snapshot: could not publish actions: \(error.localizedDescription)")
        }
    }
}
