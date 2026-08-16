import Contacts
import EventKit
import XCTest
@testable import Cai

/// The decision logic behind the Connections screen's "System Access" tab
/// (Calendar/Contacts toggles): raw framework status → UI state, the
/// macOS-version request branch,
/// and what a toggle tap should do. Pulled out of the live app so it's verified
/// here instead of only against real system state.
final class NativeAccessTests: XCTestCase {

    typealias M = NativeAccessManager

    // MARK: - EventKit status → state

    func testEventKitNotDeterminedMapsToNotDetermined() {
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.notDetermined), .notDetermined)
    }

    func testEventKitDeniedMapsToDenied() {
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.denied), .denied)
    }

    func testEventKitRestrictedMapsToRestricted() {
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.restricted), .restricted)
    }

    func testEventKitFullAccessMapsToAuthorized() {
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.fullAccess), .authorized)
    }

    func testEventKitLegacyAuthorizedMapsToAuthorized() {
        // Pre-macOS-14 "granted".
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.authorized), .authorized)
    }

    func testEventKitWriteOnlyMapsToDenied() {
        // Cai's Calendar benefit promises reading events; write-only can't
        // satisfy it, so the toggle must read OFF and guide to full access.
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.writeOnly), .denied)
    }

    // MARK: - Contacts status → state

    func testContactsNotDeterminedMapsToNotDetermined() {
        XCTAssertEqual(M.state(from: CNAuthorizationStatus.notDetermined), .notDetermined)
    }

    func testContactsAuthorizedMapsToAuthorized() {
        XCTAssertEqual(M.state(from: CNAuthorizationStatus.authorized), .authorized)
    }

    func testContactsDeniedMapsToDenied() {
        XCTAssertEqual(M.state(from: CNAuthorizationStatus.denied), .denied)
    }

    func testContactsRestrictedMapsToRestricted() {
        XCTAssertEqual(M.state(from: CNAuthorizationStatus.restricted), .restricted)
    }

    // MARK: - macOS-version request branch

    func testLegacyBranchBelowMacOS14() {
        XCTAssertEqual(M.eventKitRequestStrategy(macOSMajorVersion: 13), .legacy)
    }

    func testFullAccessBranchOnMacOS14() {
        XCTAssertEqual(M.eventKitRequestStrategy(macOSMajorVersion: 14), .fullAccess)
    }

    func testFullAccessBranchAboveMacOS14() {
        XCTAssertEqual(M.eventKitRequestStrategy(macOSMajorVersion: 26), .fullAccess)
    }

    // MARK: - Toggle intent

    func testNotDeterminedTogglesToRequest() {
        XCTAssertEqual(M.toggleIntent(for: .notDetermined), .request)
    }

    func testAuthorizedTogglesToOpenSettings() {
        // Already granted → the OS gives no re-request API; flipping means the
        // user wants to revoke, which only System Settings can do.
        XCTAssertEqual(M.toggleIntent(for: .authorized), .openSettings)
    }

    func testDeniedTogglesToOpenSettings() {
        XCTAssertEqual(M.toggleIntent(for: .denied), .openSettings)
    }

    func testRestrictedTogglesToOpenSettings() {
        XCTAssertEqual(M.toggleIntent(for: .restricted), .openSettings)
    }

    // MARK: - isOn

    func testOnlyAuthorizedReadsAsOn() {
        XCTAssertTrue(M.AccessState.authorized.isOn)
        XCTAssertFalse(M.AccessState.notDetermined.isOn)
        XCTAssertFalse(M.AccessState.denied.isOn)
        XCTAssertFalse(M.AccessState.restricted.isOn)
    }
}
