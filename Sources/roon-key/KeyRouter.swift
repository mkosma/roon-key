import Foundation
import CoreGraphics

/// KeyRouter: single source of routing decisions.
///
/// Takes a parsed key event + modifier flags + at-home state and calls
/// the appropriate RoonBridgeClient method, or returns false to let the
/// event pass through.
///
/// Modifier semantics:
/// - F10/F11/F12 are NOT routed: macOS dispatches them as consumer
///   media keys (mute / vol- / vol+) in parallel with the F-key
///   keycode, and the consumer-page event is reserved by mediaremoted
///   on macOS 13+ so we can't suppress it. Intercepting the F-key
///   would just produce a duplicate Roon action alongside the system
///   volume change. Use F13-F19 presets (or the popover) instead.
/// - F13-F19 (presets):
///     - No modifier    : preset (ramp)
///     - Ctrl modifier  : preset (instant jump)
///   (fn is unusable as a modifier here: many keyboards set the fn flag
///   automatically on F13+ so it can't be distinguished from "no modifier".)
/// - Consumer keys (bare mute, vol+/-, etc.) are NOT intercepted; macOS
///   handles them locally. `mediaremoted` claims them before any public
///   CGEventTap can see them on macOS 13+. Use fn+F10/F11/F12 instead.
///
/// All routing goes through roon-bridge over HTTP.
/// No direct Roon Core connection from mbp.
@MainActor
public class KeyRouter {

    private let bridgeClient: RoonBridgeClient

    public init(bridgeClient: RoonBridgeClient) {
        self.bridgeClient = bridgeClient
    }

    // -------------------------------------------------------------------------
    // Route an F10-F19 keyDown event
    // -------------------------------------------------------------------------

    /// Returns true if the key was consumed, false to pass through.
    @discardableResult
    public func routeFunctionKey(_ keyCode: Int, modifiers: CGEventFlags) -> Bool {
        // F13-F19 are presets. Ctrl modifier selects instant jump.
        guard let index = Self.presetIndexForKeyCode(keyCode) else { return false }
        let isInstant = modifiers.contains(.maskControl)

        if !isInstant {
            // Preset ramps over time. Tell the menubar to start an
            // optimistic local animation (and burst-poll) so the displayed
            // number tracks the ramp without waiting on the bridge.
            NotificationCenter.default.post(
                name: .roonKeyDidRamp,
                object: nil,
                userInfo: ["presetIndex": index]
            )
        }
        Task {
            do {
                try await bridgeClient.volumePreset(index: index, instant: isInstant)
            } catch {
                NSLog("[KeyRouter] Preset call failed: \(error.localizedDescription)")
            }
        }

        return true
    }

    /// True if this keycode is one roon-key routes (F13-F19 presets).
    public nonisolated static func handlesKeyCode(_ keyCode: Int) -> Bool {
        presetIndexForKeyCode(keyCode) != nil
    }

    // -------------------------------------------------------------------------
    // Key code to preset index mapping
    // -------------------------------------------------------------------------

    /// Maps F13-F19 keycodes to preset indices 1-7.
    /// Returns nil if the keycode is not a mapped function key.
    public nonisolated static func presetIndexForKeyCode(_ keyCode: Int) -> Int? {
        // F13=105, F14=107, F15=113, F16=106, F17=64, F18=79, F19=80
        let mapping: [Int: Int] = [
            105: 1, // F13
            107: 2, // F14
            113: 3, // F15
            106: 4, // F16
            64:  5, // F17
            79:  6, // F18
            80:  7, // F19
        ]
        return mapping[keyCode]
    }
}

