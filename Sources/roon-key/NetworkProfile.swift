import Foundation
import Network

/// NetworkProfile: detects whether the mbp is on the home LAN.
///
/// At-home = the route to roon-bridge goes via eth* or en* (not a VPN tunnel).
/// Away = route goes via wg*, utun* (WireGuard / VPN tunnel).
///
/// The verdict is cached and refreshed on NWPathMonitor path change events.
/// KeyEventMonitor reads .isAtHome on each keypress (zero overhead).
@MainActor
public class NetworkProfile {

    /// True when the mbp is on the home LAN and roon-key should intercept keys.
    public private(set) var isAtHome: Bool = false

    /// Called whenever the at-home verdict changes.
    public var onStatusChange: ((Bool) -> Void)?

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.kosma.roon-key.network", qos: .utility)

    public init() {}

    public func start() {
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let atHome = Self.evaluatePath(path)
            Task { @MainActor in
                if atHome != self.isAtHome {
                    self.isAtHome = atHome
                    self.onStatusChange?(atHome)
                }
            }
        }

        monitor.start(queue: monitorQueue)
    }

    public func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // -------------------------------------------------------------------------
    // At-home classification logic
    // -------------------------------------------------------------------------

    /// Returns true iff the active interfaces suggest we are on the home LAN.
    ///
    /// Rules (in order):
    /// 1. If any tunnel interface (wg*, utun*) is present and used for routing,
    ///    classify away.
    /// 2. If a physical ethernet (en0, eth0) or non-VPN wifi (en*) is active,
    ///    classify home.
    /// 3. If none of the above, classify away (graceful degradation).
    nonisolated static func evaluatePath(_ path: NWPath) -> Bool {
        // Check for VPN tunnel interfaces
        let hasVPNInterface = path.availableInterfaces.contains { iface in
            let name = iface.name
            return name.hasPrefix("wg") || name.hasPrefix("utun")
        }

        if hasVPNInterface {
            return false
        }

        // Check for physical ethernet or wifi
        let hasHomeInterface = path.availableInterfaces.contains { iface in
            let name = iface.name
            let isEthernet = iface.type == .wiredEthernet
            let isWifi = iface.type == .wifi
            return isEthernet || (isWifi && !name.hasPrefix("wg") && !name.hasPrefix("utun"))
        }

        return hasHomeInterface && path.status == .satisfied
    }

    /// Synchronous nonisolated check for use in tests via dependency injection.
    public nonisolated static func evaluate(interfaces: [(name: String, type: NWInterface.InterfaceType)]) -> Bool {
        let hasVPN = interfaces.contains { name, _ in
            name.hasPrefix("wg") || name.hasPrefix("utun")
        }
        if hasVPN { return false }

        let hasHome = interfaces.contains { _, type_ in
            type_ == .wiredEthernet || type_ == .wifi
        }
        return hasHome
    }
}
