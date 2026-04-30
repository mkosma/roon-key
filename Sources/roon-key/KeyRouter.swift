import Foundation
import CoreGraphics

/// KeyRouter: single source of routing decisions.
///
/// Takes a parsed key event + modifier flags + at-home state and calls
/// the appropriate RoonBridgeClient method, or returns false to let the
/// event pass through.
///
/// Modifier semantics:
/// - No modifier        : ramp/preset variant (smooth)
/// - Ctrl (controlKey)  : instant variant (single API call)
/// - Shift (shiftKey)   : pass through (system handles it)
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
    // Route a consumer key event (volume up/down/mute, play/pause, next, prev)
    // -------------------------------------------------------------------------

    /// Returns true if the key was consumed (bridge call issued), false to pass through.
    @discardableResult
    public func routeConsumerKey(_ key: ConsumerKey, modifiers: CGEventFlags) -> Bool {
        let isShift = modifiers.contains(.maskShift)
        let isCtrl = modifiers.contains(.maskControl)

        // Shift = pass through to system
        if isShift { return false }

        Task {
            do {
                switch key {
                case .volumeUp:
                    if isCtrl {
                        try await bridgeClient.volumeInstant(direction: .up)
                    } else {
                        try await bridgeClient.volumeRamp(direction: .up)
                    }

                case .volumeDown:
                    if isCtrl {
                        try await bridgeClient.volumeInstant(direction: .down)
                    } else {
                        try await bridgeClient.volumeRamp(direction: .down)
                    }

                case .mute:
                    try await bridgeClient.muteToggle()

                case .playPause:
                    try await bridgeClient.transport(action: .playpause)

                case .nextTrack:
                    try await bridgeClient.transport(action: .next)

                case .prevTrack:
                    try await bridgeClient.transport(action: .prev)
                }
            } catch {
                print("[KeyRouter] Bridge call failed: \(error.localizedDescription)")
            }
        }

        return true
    }

    // -------------------------------------------------------------------------
    // Route a function key (F13-F19 -> presets 1-7)
    // -------------------------------------------------------------------------

    /// Returns true if the key was consumed, false to pass through.
    @discardableResult
    public func routeFunctionKey(_ keyCode: Int, modifiers: CGEventFlags) -> Bool {
        let isShift = modifiers.contains(.maskShift)
        let isCtrl = modifiers.contains(.maskControl)

        if isShift { return false }

        // F13=keycode 105, F14=107, F15=113, F16=106, F17=64, F18=79, F19=80
        let presetIndex = Self.presetIndexForKeyCode(keyCode)
        guard let index = presetIndex else { return false }

        Task {
            do {
                try await bridgeClient.volumePreset(index: index, instant: isCtrl)
            } catch {
                print("[KeyRouter] Preset call failed: \(error.localizedDescription)")
            }
        }

        return true
    }

    // -------------------------------------------------------------------------
    // Key code to preset index mapping
    // -------------------------------------------------------------------------

    /// Maps F13-F19 keycodes to preset indices 1-7.
    /// Returns nil if the keycode is not a mapped function key.
    public static func presetIndexForKeyCode(_ keyCode: Int) -> Int? {
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

// -------------------------------------------------------------------------
// ConsumerKey enum
// -------------------------------------------------------------------------

/// Consumer (media) key identifiers from IOKit HID subtype 8 events.
public enum ConsumerKey {
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case nextTrack
    case prevTrack

    /// Parse from the NX subtype 8 event's data1 field.
    /// data1 layout: bits 16-31 = key code, bit 0 of key code = key-down.
    public static func from(data1: Int64) -> (key: ConsumerKey, isDown: Bool)? {
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let isDown = (data1 & 0xFF00) >> 8 == 0x0A

        switch keyCode {
        case 0x00:   return (isDown: isDown, key: .volumeUp).swapped
        case 0x01:   return (isDown: isDown, key: .volumeDown).swapped
        case 0x02:   return (isDown: isDown, key: .mute).swapped
        case 0x10:   return (isDown: isDown, key: .playPause).swapped
        case 0x11:   return (isDown: isDown, key: .nextTrack).swapped
        case 0x12:   return (isDown: isDown, key: .prevTrack).swapped
        default:     return nil
        }
    }
}

private extension (key: ConsumerKey, isDown: Bool) {
    var swapped: (key: ConsumerKey, isDown: Bool) { self }
}
