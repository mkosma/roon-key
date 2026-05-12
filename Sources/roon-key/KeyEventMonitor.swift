import AppKit
import CoreGraphics

/// KeyEventMonitor: intercepts media keys and F13-F19.
///
/// Uses two CGEventTaps at `.cghidEventTap` (raw HID level so the system
/// hasn't yet handled the events):
///   - systemDefined tap for media keys (mute, vol+/-, play/pause, next/prev)
///   - keyDown tap for F13-F19 preset keys
///
/// Both taps return nil to consume the event when routed; otherwise pass it
/// through unchanged. Requires Accessibility permission.
///
/// At-home detection: the tap callbacks read a non-isolated Bool flag
/// (atHomeFlag) which is updated from the main actor via NetworkProfile.
@MainActor
public class KeyEventMonitor {

    let bridgeClient: RoonBridgeClient
    let networkProfile: NetworkProfile
    let keyRouter: KeyRouter

    // Thread-safe flag readable from the non-isolated CGEventTap callbacks.
    // Updated on main actor but read safely from any thread (Bool is atomic on arm64).
    nonisolated(unsafe) var atHomeFlag: Bool = false

    // Tap handles are written from the MainActor (setup/stop) and read from
    // the non-isolated CGEventTap callbacks when the OS disables a tap.
    // The reads/writes don't race: setup completes before any callback can
    // fire, and stop() runs at terminate after all callbacks have drained.
    nonisolated(unsafe) fileprivate var consumerTap: CFMachPort?
    nonisolated(unsafe) fileprivate var consumerRunLoopSource: CFRunLoopSource?
    nonisolated(unsafe) fileprivate var functionTap: CFMachPort?
    nonisolated(unsafe) fileprivate var functionRunLoopSource: CFRunLoopSource?

    public init(bridgeClient: RoonBridgeClient, networkProfile: NetworkProfile) {
        self.bridgeClient = bridgeClient
        self.networkProfile = networkProfile
        self.keyRouter = KeyRouter(bridgeClient: bridgeClient)
    }

    public func start() {
        atHomeFlag = networkProfile.isAtHome

        networkProfile.onStatusChange = { [weak self] isAtHome in
            self?.atHomeFlag = isAtHome
        }

        setupConsumerKeyTap()
        setupFunctionKeyTap()
    }

    public func stop() {
        teardownTap(&consumerTap, &consumerRunLoopSource)
        teardownTap(&functionTap, &functionRunLoopSource)
    }

    private func teardownTap(_ tap: inout CFMachPort?, _ source: inout CFRunLoopSource?) {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let s = source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            }
        }
        tap = nil
        source = nil
    }

    // -------------------------------------------------------------------------
    // Consumer key tap (volume, mute, play/pause, next, prev)
    // NSEventTypeSystemDefined = 14
    // -------------------------------------------------------------------------

    private func setupConsumerKeyTap() {
        guard let systemDefinedType = CGEventType(rawValue: 14) else { return }
        let eventMask = CGEventMask(1 << systemDefinedType.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: consumerKeyTapCallback,
            userInfo: selfPtr
        ) else {
            NSLog("[KeyEventMonitor] Could not create consumer key tap -- is Accessibility permission granted?")
            return
        }

        self.consumerTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.consumerRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[KeyEventMonitor] Consumer key tap installed at cghidEventTap")
    }

    // -------------------------------------------------------------------------
    // Function key tap (F13-F19 -> presets)
    // -------------------------------------------------------------------------

    private func setupFunctionKeyTap() {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: functionKeyTapCallback,
            userInfo: selfPtr
        ) else {
            NSLog("[KeyEventMonitor] Could not create function key tap -- is Accessibility permission granted?")
            return
        }

        self.functionTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.functionRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[KeyEventMonitor] Function key tap installed at cghidEventTap")
    }
}

// -------------------------------------------------------------------------
// CGEventTap callback for consumer keys (C callback, non-isolated)
// -------------------------------------------------------------------------

private func consumerKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let monitor = Unmanaged<KeyEventMonitor>.fromOpaque(refcon).takeUnretainedValue()

    // Re-enable the tap if the system disabled it (timeout/user input).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.consumerTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[KeyEventMonitor] consumer tap re-enabled after \(type.rawValue)")
        }
        return Unmanaged.passRetained(event)
    }

    // kCGMouseEventSubtype (field 7) carries subtype for system-defined events.
    // Subtype 8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS = consumer/media keys.
    guard let subtypeField = CGEventField(rawValue: 7) else { return Unmanaged.passRetained(event) }
    let subtype = event.getIntegerValueField(subtypeField)
    guard subtype == 8 else { return Unmanaged.passRetained(event) }

    guard monitor.atHomeFlag else {
        NSLog("[KeyEventMonitor] consumer event arrived but not at home")
        return Unmanaged.passRetained(event)
    }

    // Shift is the "send to Roon" trigger for consumer keys. Without shift,
    // let the Mac handle the key locally (system volume, mute, etc.).
    let flags = event.flags
    NSLog("[KeyEventMonitor] consumer event flags=0x\(String(flags.rawValue, radix: 16)) shift=\(flags.contains(.maskShift)) ctrl=\(flags.contains(.maskControl))")
    guard flags.contains(.maskShift) else {
        return Unmanaged.passRetained(event)
    }

    guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passRetained(event) }
    let data1 = Int64(nsEvent.data1)
    let keyCode = (data1 & 0xFFFF0000) >> 16
    guard let (key, isDown) = ConsumerKey.from(data1: data1) else {
        NSLog("[KeyEventMonitor] unmapped consumer keyCode=\(keyCode)")
        return Unmanaged.passRetained(event)
    }
    guard isDown else { return nil } // also consume key-up so the system doesn't act

    NSLog("[KeyEventMonitor] routing consumer key: \(key)")

    DispatchQueue.main.async {
        monitor.keyRouter.routeConsumerKey(key, modifiers: flags)
    }

    return nil // consume
}

// -------------------------------------------------------------------------
// CGEventTap callback for F13-F19 keyDown
// -------------------------------------------------------------------------

private func functionKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let monitor = Unmanaged<KeyEventMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.functionTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[KeyEventMonitor] function tap re-enabled after \(type.rawValue)")
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else { return Unmanaged.passRetained(event) }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    guard KeyRouter.presetIndexForKeyCode(keyCode) != nil else {
        return Unmanaged.passRetained(event) // not one of ours
    }

    let flags = event.flags
    // Ctrl = pass through (so user can still send F-keys to focused apps).
    if flags.contains(.maskControl) { return Unmanaged.passRetained(event) }

    guard monitor.atHomeFlag else {
        NSLog("[KeyEventMonitor] F-key arrived but not at home")
        return Unmanaged.passRetained(event)
    }

    NSLog("[KeyEventMonitor] routing F-key: \(keyCode) shift=\(flags.contains(.maskShift))")
    DispatchQueue.main.async {
        monitor.keyRouter.routeFunctionKey(keyCode, modifiers: flags)
    }

    return nil // consume so the foreground app doesn't also receive F13...
}

// -------------------------------------------------------------------------
// Helper: NSEventModifierFlags -> CGEventFlags
// -------------------------------------------------------------------------

extension NSEvent.ModifierFlags {
    var toCGEventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
