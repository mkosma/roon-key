import XCTest
import Network
@testable import roontrol

/// Tests for NetworkProfile.evaluate(interfaces:) using simulated interface lists.
/// No real NWPathMonitor is started; we test the pure classification logic.
@MainActor
final class NetworkProfileTests: XCTestCase {

    // -------------------------------------------------------------------------
    // At-home cases
    // -------------------------------------------------------------------------

    func testWiredEthernetIsHome() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("en0", .wiredEthernet),
        ]
        XCTAssertTrue(NetworkProfile.evaluate(interfaces: interfaces))
    }

    func testWifiIsHome() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("en1", .wifi),
        ]
        XCTAssertTrue(NetworkProfile.evaluate(interfaces: interfaces))
    }

    func testEthernetAndWifiIsHome() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("en0", .wiredEthernet),
            ("en1", .wifi),
        ]
        XCTAssertTrue(NetworkProfile.evaluate(interfaces: interfaces))
    }

    // -------------------------------------------------------------------------
    // Away cases
    // -------------------------------------------------------------------------

    func testWireGuardInterfaceIsAway() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("wg0", .other),
            ("en1", .wifi),
        ]
        XCTAssertFalse(NetworkProfile.evaluate(interfaces: interfaces))
    }

    func testUtunInterfaceIsAway() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("utun0", .other),
            ("en0", .wiredEthernet),
        ]
        XCTAssertFalse(NetworkProfile.evaluate(interfaces: interfaces))
    }

    func testNoInterfacesIsAway() {
        XCTAssertFalse(NetworkProfile.evaluate(interfaces: []))
    }

    func testOnlyCellularIsAway() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("pdp_ip0", .cellular),
        ]
        XCTAssertFalse(NetworkProfile.evaluate(interfaces: interfaces))
    }

    func testOnlyLoopbackIsAway() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("lo0", .loopback),
        ]
        XCTAssertFalse(NetworkProfile.evaluate(interfaces: interfaces))
    }

    // -------------------------------------------------------------------------
    // VPN takes priority over physical interfaces
    // -------------------------------------------------------------------------

    func testVPNBeatsEthernet() {
        let interfaces: [(name: String, type: NWInterface.InterfaceType)] = [
            ("en0", .wiredEthernet),
            ("utun3", .other),
        ]
        XCTAssertFalse(NetworkProfile.evaluate(interfaces: interfaces))
    }
}
