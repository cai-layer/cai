import AppKit

/// Real app icons for clipboard rows, looked up from the installed app. Only
/// the bundle id is stored on an entry; the icon comes from LaunchServices.
/// Lookups (misses included) are cached until `refresh()`, which the status
/// menu calls on open and the ⌘0 list on close, so an updated or deleted
/// app shows correctly on the next open without a lookup per hover.
enum AppIcon {
    private static var cache: [String: NSImage?] = [:]

    static func refresh() {
        cache.removeAll()
    }

    /// The installed app's icon sized to `size` points, or nil when no app
    /// with that bundle id is installed. Main thread only (menu and view code).
    static func image(forBundleId bundleId: String?, size: CGFloat = 16) -> NSImage? {
        guard let bundleId else { return nil }
        let key = "\(bundleId)@\(size)"
        if let cached = cache[key] { return cached }
        // icon(forFile:) returns a shared multi-representation image; copy
        // before resizing so other callers keep their own size.
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .flatMap { NSWorkspace.shared.icon(forFile: $0.path).copy() as? NSImage }
        icon?.size = NSSize(width: size, height: size)
        cache[key] = .some(icon)  // a miss is cached too
        return icon
    }
}
