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
        .library(name: "CaiActionCore", targets: ["CaiActionCore"])
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
