import AppKit
import CoreGraphics

/// KeyEventMonitor: intercepts media keys and F13-F19 via CGEventTap.
///
/// Uses a `.systemDefined` event tap (subtype 8) for consumer keys
/// (volume up/down/mute, play/pause, next/prev track).
/// Uses a `.keyDown` event tap filtered for F13-F19 keycodes.
///
/// At-home detection: if NetworkProfile.isAtHome is false, the taps pass
/// events through unchanged so the system handles them normally.
///
/// CGEventTap requires Accessibility permission in System Settings.
@MainActor
public class KeyEventMonitor {

    private let bridgeClient: RoonBridgeClient
    private let networkProfile: NetworkProfile
    private let keyRouter: KeyRouter

    private var consumerTap: CFMachPort?
    private var functionTap: CFMachPort?
    private var consumerRunLoopSource: CFRunLoopSource?
    private var functionRunLoopSource: CFRunLoopSource?

    public init(bridgeClient: RoonBridgeClient, networkProfile: NetworkProfile) {
        self.bridgeClient = bridgeClient
        self.networkProfile = networkProfile
        self.keyRouter = KeyRouter(bridgeClient: bridgeClient)
    }

    public func start() {
        setupConsumerKeyTap()
        setupFunctionKeyTap()
    }

    public func stop() {
        if let tap = consumerTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = consumerRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        if let tap = functionTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = functionRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        consumerTap = nil
        functionTap = nil
    }

    // -------------------------------------------------------------------------
    // Consumer key tap (volume, mute, play/pause, next, prev)
    // -------------------------------------------------------------------------

    private func setupConsumerKeyTap() {
        // We use an event tap on systemDefined events (subtype 8 = NX_SUBTYPE_AUX_MOUSE_BUTTONS)
        // which is how macOS delivers consumer/media keys.
        let eventMask = CGEventMask(1 << CGEventType.systemDefined.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: consumerKeyCallback,
            userInfo: selfPtr
        ) else {
            print("[KeyEventMonitor] Failed to create consumer key tap. Is Accessibility granted?")
            return
        }

        self.consumerTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.consumerRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // -------------------------------------------------------------------------
    // Function key tap (F13-F19)
    // -------------------------------------------------------------------------

    private func setupFunctionKeyTap() {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: functionKeyCallback,
            userInfo: selfPtr
        ) else {
            print("[KeyEventMonitor] Failed to create function key tap.")
            return
        }

        self.functionTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.functionRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// -------------------------------------------------------------------------
// CGEventTap callbacks (C function pointers, cannot be closures)
// -------------------------------------------------------------------------

/// Consumer key tap callback.
/// Handles .systemDefined events with subtype 8 (NX consumer key events).
private func consumerKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard
        type == .systemDefined,
        let refcon = refcon
    else {
        return Unmanaged.passRetained(event)
    }

    let monitor = Unmanaged<KeyEventMonitor>.fromOpaque(refcon).takeUnretainedValue()

    // Subtype 8 = NX_SUBTYPE_AUX_MOUSE_BUTTONS (consumer keys)
    let subtype = event.getIntegerValueField(.eventSubtype)
    guard subtype == 8 else {
        return Unmanaged.passRetained(event)
    }

    // Only act when at home
    guard monitor.networkProfile.isAtHome else {
        return Unmanaged.passRetained(event)
    }

    let data1 = event.getIntegerValueField(.eventSourceUserData)
    guard let (key, isDown) = ConsumerKey.from(data1: data1), isDown else {
        return Unmanaged.passRetained(event)
    }

    let flags = event.flags

    // Route on the main thread
    DispatchQueue.main.async {
        monitor.keyRouter.routeConsumerKey(key, modifiers: flags)
    }

    // Consume the event (return nil) so the system doesn't process it
    return nil
}

/// Function key tap callback.
/// Filters for F13-F19 keycodes and routes to presets.
private func functionKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard
        type == .keyDown,
        let refcon = refcon
    else {
        return Unmanaged.passRetained(event)
    }

    let monitor = Unmanaged<KeyEventMonitor>.fromOpaque(refcon).takeUnretainedValue()

    guard monitor.networkProfile.isAtHome else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    // Only intercept F13-F19 (mapped keycodes)
    guard KeyRouter.presetIndexForKeyCode(keyCode) != nil else {
        return Unmanaged.passRetained(event)
    }

    DispatchQueue.main.async {
        monitor.keyRouter.routeFunctionKey(keyCode, modifiers: flags)
    }

    return nil
}
