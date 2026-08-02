import CaiActionCore
import Foundation

/// Keeps `~/Library/Application Support/Cai/bin/cai-mcp` pointing at the
/// helper inside the running app bundle.
///
/// Agent configs name that stable path rather than the app bundle, so the
/// wiring survives the user moving Cai to a different folder, renaming it, or
/// Sparkle replacing it during an update. Without it, every update would
/// silently break every agent the user had connected, and the failure would
/// show up as "the tool disappeared" inside their agent rather than as
/// anything Cai could explain.
///
/// Refreshed on every launch: last app to launch owns the link. That matters
/// while dogfooding, where a Debug build's helper lives in DerivedData and can
/// vanish under a clean build. Relaunching the app the user actually uses
/// repairs it.
enum HelperInstaller {

    /// Where the helper sits inside the bundle. Matches the Embed Helpers
    /// build phase.
    static func bundledHelper(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("cai-mcp")
    }

    /// Whether the link has to be rewritten. Pure so the decision is tested
    /// rather than inferred from filesystem state.
    ///
    /// A link that already points at the right place is left alone: rewriting
    /// it on every launch would be harmless but noisy, and an unnecessary
    /// unlink is a window in which an agent spawning the helper finds nothing.
    static func needsRefresh(currentDestination: String?, desiredPath: String) -> Bool {
        currentDestination != desiredPath
    }

    @discardableResult
    static func refreshSymlink(bundle: Bundle = .main, root: URL = CaiSupportPaths.root) -> Bool {
        let target = bundledHelper(in: bundle)
        guard FileManager.default.isExecutableFile(atPath: target.path) else {
            // A build without the helper embedded. Nothing to point at, and a
            // dangling link would be worse than none.
            print("HelperInstaller: no helper at \(target.path); leaving the symlink alone")
            return false
        }

        let link = CaiSupportPaths.helperSymlink(in: root)
        let current = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        guard needsRefresh(currentDestination: current, desiredPath: target.path) else { return true }

        do {
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            return true
        } catch {
            print("HelperInstaller: could not link \(link.path): \(error.localizedDescription)")
            return false
        }
    }
}
