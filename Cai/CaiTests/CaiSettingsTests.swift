import XCTest
@testable import Cai

/// Regression tests for the "explicit provider" guard that stops launch-time
/// auto-detect from silently reverting a chosen provider that is merely
/// unavailable at launch (issue #35). Exercises `CaiSettings.providerIsExplicit`,
/// the pure predicate behind `hasExplicitProvider` and the early-return guard in
/// `autoDetectProvider()`.
final class CaiSettingsTests: XCTestCase {

    func testFreshInstallHasNoExplicitProvider() {
        // No provider key ever persisted → not explicit → first-launch auto-detect may run.
        XCTAssertFalse(
            CaiSettings.providerIsExplicit(persistedValue: nil),
            "A fresh install (no persisted provider) must allow first-launch auto-detect."
        )
    }

    func testPersistedProviderIsExplicit() {
        // User picked (or onboarding/auto-detect established) a provider.
        XCTAssertTrue(
            CaiSettings.providerIsExplicit(persistedValue: CaiSettings.ModelProvider.lmstudio.rawValue),
            "A persisted provider must be treated as explicit so auto-detect is skipped."
        )
    }

    func testPersistedBuiltInIsExplicit() {
        // The subtle #35 case: a persisted Built-in still counts as explicit, so a
        // provider that is only transiently unavailable is never re-detected and reverted.
        XCTAssertTrue(
            CaiSettings.providerIsExplicit(persistedValue: CaiSettings.ModelProvider.builtIn.rawValue),
            "Even a persisted Built-in must be explicit — presence, not value, decides."
        )
    }
}
