// swift-tools-version: 5.9
import PackageDescription

/// Shared substrate for authoring Cai actions.
///
/// Compiled into BOTH the Cai app and the `cai-mcp` stdio helper so the
/// validator is a single source of trust: the helper validates before writing
/// a pending change, and the app re-validates the same bytes with the same
/// code before anything reaches the approval sheet. The app never trusts the
/// helper's verdict.
///
/// Deliberately dependency-free and platform-agnostic (Foundation only): the
/// helper is a plain executable with no AppKit, and every decision function
/// here is pure so it can be table-tested without a running app.
let package = Package(
    name: "CaiActionCore",
    platforms: [.macOS(.v14)],
    products: [
        // Static deliberately. Left automatic, Xcode builds one dynamic
        // framework and hands it to both the app and the `cai-mcp` helper. The
        // app embeds it and is fine; the helper is a bare executable with
        // nowhere to embed anything, so it fails at launch with a dyld error
        // the moment it runs outside the build directory. Linking the app's
        // frameworks instead would mean embedding the MCP SDK in the app,
        // which the MLP plan rules out: the SDK belongs to the helper alone.
        .library(name: "CaiActionCore", type: .static, targets: ["CaiActionCore"])
    ],
    // No test target here: Xcode does not surface the test target of a
    // project-referenced local package in a scheme, so a package-side test
    // suite would never run under `xcodebuild -scheme Cai test`, which is the
    // command CI and CLAUDE.md use. The core's tests live in `CaiTests`
    // (`CaiActionCore*Tests.swift`) instead, importing this library like any
    // other consumer, so one command still covers the whole validator.
    targets: [
        .target(name: "CaiActionCore")
    ]
)
