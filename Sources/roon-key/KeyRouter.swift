import Foundation
import CoreGraphics

/// KeyRouter: single source of routing decisions.
///
/// Takes a parsed key event + modifier flags + at-home state and calls
/// the appropriate RoonBridgeClient method, or returns false to let the
/// event pass through.
///
/// Modifier semantics:
/// - F10/F11/F12 (reached via fn on a MacBook keyboard):
///     - F10            : mute toggle (instant)
///     - F11            : volume down (instant, -1)
///     - F12            : volume up   (instant, +1)
/// - F13-F19 (presets):
///     - No modifier    : preset (ramp)
///     - Fn modifier    : preset (instant jump)
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
        // F10/F11/F12 are volume controls (reached via fn on a MacBook).
        if let volumeAction = Self.volumeActionForKeyCode(keyCode) {
            Task {
                do {
                    switch volumeAction {
                    case .mute:
                        try await bridgeClient.muteToggle()
                    case .down:
                        try await bridgeClient.volumeInstant(direction: .down, step: 1)
                    case .up:
                        try await bridgeClient.volumeInstant(direction: .up, step: 1)
                    }
                } catch {
                    NSLog("[KeyRouter] Volume call failed: \(error.localizedDescription)")
                }
            }
            return true
        }

        // F13-F19 are presets. Fn modifier selects instant jump.
        guard let index = Self.presetIndexForKeyCode(keyCode) else { return false }
        let isFn = modifiers.contains(.maskSecondaryFn)

        if !isFn {
            // Preset ramps over time; signal the menubar to poll faster
            // so the displayed number tracks the ramp visibly.
            NotificationCenter.default.post(name: .roonKeyDidRamp, object: nil)
        }
        Task {
            do {
                try await bridgeClient.volumePreset(index: index, instant: isFn)
            } catch {
                NSLog("[KeyRouter] Preset call failed: \(error.localizedDescription)")
            }
        }

        return true
    }

    private enum VolumeAction { case mute, down, up }

    private nonisolated static func volumeActionForKeyCode(_ keyCode: Int) -> VolumeAction? {
        switch keyCode {
        case 109: return .mute  // F10
        case 103: return .down  // F11
        case 111: return .up    // F12
        default:  return nil
        }
    }

    /// True if this keycode is one roon-key routes (F10-F12 or F13-F19).
    public nonisolated static func handlesKeyCode(_ keyCode: Int) -> Bool {
        volumeActionForKeyCode(keyCode) != nil || presetIndexForKeyCode(keyCode) != nil
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

