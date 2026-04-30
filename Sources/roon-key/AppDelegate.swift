import AppKit

/// AppDelegate: lifecycle, accessibility permission check, menubar setup.
///
/// - Hides the dock icon at launch (LSUIElement in Info.plist; also set
///   programmatically here as a belt-and-suspenders measure).
/// - Checks for Accessibility permission and prompts once if missing.
/// - Starts mDNS discovery, network monitoring, and event interception.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var menubarController: MenubarController?
    private var keyEventMonitor: KeyEventMonitor?
    private var networkProfile: NetworkProfile?
    private var bridgeDiscovery: BridgeDiscovery?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Suppress dock icon at runtime
        NSApp.setActivationPolicy(.accessory)

        // Check and request Accessibility permission
        checkAccessibility()

        // Start bridge discovery (mDNS + fallback static endpoint)
        let discovery = BridgeDiscovery()
        self.bridgeDiscovery = discovery
        discovery.start()

        // Start network profile monitoring
        let profile = NetworkProfile()
        self.networkProfile = profile
        profile.start()

        // Build bridge client (updated when discovery finds an endpoint)
        let client = RoonBridgeClient()
        discovery.onEndpointResolved = { endpoint in
            Task { @MainActor in
                client.setEndpoint(endpoint)
            }
        }

        // Start menubar controller
        let menubar = MenubarController(bridgeClient: client, networkProfile: profile)
        self.menubarController = menubar
        menubar.setup()

        // Start key event monitor
        let monitor = KeyEventMonitor(
            bridgeClient: client,
            networkProfile: profile
        )
        self.keyEventMonitor = monitor
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyEventMonitor?.stop()
        bridgeDiscovery?.stop()
        networkProfile?.stop()
    }

    // -------------------------------------------------------------------------
    // Accessibility permission
    // -------------------------------------------------------------------------

    private func checkAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            // Show a one-time dialog explaining how to grant access
            showAccessibilityAlert()
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
        roon-key needs Accessibility access to intercept media keys and function keys (F13-F19).

        Please grant access in:
        System Settings > Privacy & Security > Accessibility

        Then relaunch roon-key.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
