import CaiActionCore
import XCTest
@testable import Cai

/// "Show in Cai" is a destination that is deliberately NOT persisted.
///
/// Adding a `DestinationType` case adds a presence key, and an OLDER binary
/// decoding a store that contains it throws from `DestinationType.init(from:)`,
/// which nils the whole array through `try?` in `CaiSettings.init` and falls
/// back to `BuiltInDestinations.all` — every custom webhook and AppleScript
/// reads as gone, and the wipe becomes permanent on the next destination edit.
/// This app has real downgrade events, so the guarantee is worth pinning:
/// the destination must be reachable by name without ever entering the store.
final class SyntheticDestinationTests: XCTestCase {

    func testNotSeededIntoThePersistedStore() {
        XCTAssertFalse(
            BuiltInDestinations.all.contains { $0.type == .showInCai },
            "showInCai must stay out of `all` — `all` is what gets written to UserDefaults"
        )
    }
}
