import AppKit
import CoreGraphics

/// KeyEventMonitor: intercepts F10-F19 keyDown events.
///
/// One CGEventTap at `.cghidEventTap` for keyDown events. Bare media keys
/// (consumer page 12: mute, vol+/-, play/pause, next/prev) are NOT
/// intercepted; on macOS 13+ `mediaremoted` claims those before any public
/// CGEventTap can see them. To control Roon volume, use fn+F10/F11/F12 on
/// the MacBook keyboard — that produces regular F-key keyDown events that
/// this tap handles cleanly. F13-F19 remain the preset shortcuts.
///
/// The tap returns nil to consume the event when routed; otherwise passes
/// it through unchanged. Requires Accessibility permission.
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
    // the non-isolated CGEventTap callback when the OS disables the tap.
    // The reads/writes don't race: setup completes before any callback can
    // fire, and stop() runs at terminate after all callbacks have drained.
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

        setupFunctionKeyTap()
    }

    public func stop() {
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
    // Function key tap (F10-F19 keyDown)
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
// CGEventTap callback for F10-F19 keyDown
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
    guard KeyRouter.handlesKeyCode(keyCode) else {
        return Unmanaged.passRetained(event) // not one of ours
    }

    let flags = event.flags

    guard monitor.atHomeFlag else {
        NSLog("[KeyEventMonitor] F-key arrived but not at home")
        return Unmanaged.passRetained(event)
    }

    NSLog("[KeyEventMonitor] routing F-key: \(keyCode) fn=\(flags.contains(.maskSecondaryFn))")
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
