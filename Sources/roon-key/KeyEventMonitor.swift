import AppKit
import CoreGraphics

/// KeyEventMonitor: intercepts media keys and F13-F19.
///
/// Uses a CGEventTap (raw type 14 = NSEventTypeSystemDefined) for media keys,
/// and NSEvent.addGlobalMonitorForEvents for F13-F19 keyDown events.
/// Requires Accessibility permission (System Settings > Privacy & Security).
///
/// At-home detection: the tap callback reads a non-isolated Bool flag
/// (atHomeFlag) which is updated from the main actor via NetworkProfile.
@MainActor
public class KeyEventMonitor {

    let bridgeClient: RoonBridgeClient
    let networkProfile: NetworkProfile
    let keyRouter: KeyRouter

    // Thread-safe flag readable from the non-isolated CGEventTap callback.
    // Updated on main actor but read safely from any thread (Bool is atomic on arm64).
    nonisolated(unsafe) var atHomeFlag: Bool = false

    private var functionMonitor: Any?
    private var consumerTap: CFMachPort?
    private var consumerRunLoopSource: CFRunLoopSource?

    public init(bridgeClient: RoonBridgeClient, networkProfile: NetworkProfile) {
        self.bridgeClient = bridgeClient
        self.networkProfile = networkProfile
        self.keyRouter = KeyRouter(bridgeClient: bridgeClient)
    }

    public func start() {
        // Sync initial at-home state
        atHomeFlag = networkProfile.isAtHome

        networkProfile.onStatusChange = { [weak self] isAtHome in
            self?.atHomeFlag = isAtHome
        }

        setupConsumerKeyTap()
        setupFunctionKeyMonitor()
    }

    public func stop() {
        if let monitor = functionMonitor {
            NSEvent.removeMonitor(monitor)
            functionMonitor = nil
        }
        if let tap = consumerTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = consumerRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            consumerTap = nil
            consumerRunLoopSource = nil
        }
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
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: consumerKeyTapCallback,
            userInfo: selfPtr
        ) else {
            print("[KeyEventMonitor] Could not create consumer key tap -- is Accessibility permission granted?")
            setupConsumerKeyMonitorFallback()
            return
        }

        self.consumerTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.consumerRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func setupConsumerKeyMonitorFallback() {
        NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined]) { [weak self] event in
            guard let self, self.atHomeFlag else { return }
            guard event.subtype.rawValue == 8 else { return }
            let data1 = Int64(event.data1)
            guard let (key, isDown) = ConsumerKey.from(data1: data1), isDown else { return }
            let flags = event.modifierFlags.toCGEventFlags
            if !flags.contains(.maskShift) {
                self.keyRouter.routeConsumerKey(key, modifiers: flags)
            }
        }
    }

    // -------------------------------------------------------------------------
    // F13-F19 via NSEvent global monitor
    // -------------------------------------------------------------------------

    private func setupFunctionKeyMonitor() {
        functionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.atHomeFlag else { return }
            let keyCode = Int(event.keyCode)
            guard KeyRouter.presetIndexForKeyCode(keyCode) != nil else { return }
            let flags = event.modifierFlags.toCGEventFlags
            if flags.contains(.maskShift) { return }
            self.keyRouter.routeFunctionKey(keyCode, modifiers: flags)
        }
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

    // kCGMouseEventSubtype (field 7) holds subtype for system-defined events.
    // Subtype 8 = NX_SUBTYPE_AUX_MOUSE_BUTTONS = consumer/media keys.
    guard let subtypeField = CGEventField(rawValue: 7) else { return Unmanaged.passRetained(event) }
    let subtype = event.getIntegerValueField(subtypeField)
    guard subtype == 8 else { return Unmanaged.passRetained(event) }

    // Read non-isolated flag (thread-safe on arm64)
    guard monitor.atHomeFlag else { return Unmanaged.passRetained(event) }

    // Wrap CGEvent as NSEvent to access data1 (NX consumer key fields)
    guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passRetained(event) }

    let data1 = Int64(nsEvent.data1)
    guard let (key, isDown) = ConsumerKey.from(data1: data1), isDown else {
        return Unmanaged.passRetained(event)
    }

    let flags = event.flags

    DispatchQueue.main.async {
        monitor.keyRouter.routeConsumerKey(key, modifiers: flags)
    }

    // Consume the event (return nil so system doesn't also handle it)
    return nil
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
