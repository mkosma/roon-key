import XCTest
import CoreGraphics
@testable import roon_key

/// Tests for KeyRouter modifier logic and F13-F19 mapping.
///
/// RoonBridgeClient is not called here -- we verify the static routing
/// decisions and keycode mapping only.
@MainActor
final class KeyRouterTests: XCTestCase {

    // -------------------------------------------------------------------------
    // F13-F19 keycode to preset index mapping
    // -------------------------------------------------------------------------

    func testF13MapsToPreset1() {
        XCTAssertEqual(KeyRouter.presetIndexForKeyCode(105), 1)
    }

    func testF14MapsToPreset2() {
        XCTAssertEqual(KeyRouter.presetIndexForKeyCode(107), 2)
    }

    func testF15MapsToPreset3() {
        XCTAssertEqual(KeyRouter.presetIndexForKeyCode(113), 3)
    }

    func testF16MapsToPreset4() {
        XCTAssertEqual(KeyRouter.presetIndexForKeyCode(106), 4)
    }

    func testF17MapsToPreset5() {
        XCTAssertEqual(KeyRouter.presetIndexForKeyCode(64), 5)
    }

    func testF18MapsToPreset6() {
        XCTAssertEqual(KeyRouter.presetIndexForKeyCode(79), 6)
    }

    func testF19MapsToPreset7() {
        XCTAssertEqual(KeyRouter.presetIndexForKeyCode(80), 7)
    }

    func testUnmappedKeycodeReturnsNil() {
        XCTAssertNil(KeyRouter.presetIndexForKeyCode(36))  // Return
        XCTAssertNil(KeyRouter.presetIndexForKeyCode(0))   // A
        XCTAssertNil(KeyRouter.presetIndexForKeyCode(122)) // F1
    }
}
