import Foundation
import Network

/// BridgeDiscovery: finds roon-bridge via mDNS (_roon-bridge._tcp.local).
///
/// On success, resolves the host/port and calls onEndpointResolved.
/// Allows manual override from user settings.
/// Falls back to static "mini.local:3100" if mDNS resolution takes >5s.
@MainActor
public class BridgeDiscovery {

    public struct Endpoint: Equatable, Sendable {
        public let host: String
        public let port: UInt16

        public var baseURL: URL? {
            URL(string: "http://\(host):\(port)")
        }

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    /// Called on the main actor when a bridge endpoint is resolved.
    public var onEndpointResolved: ((Endpoint) -> Void)?

    /// Manual override endpoint. When set, mDNS is bypassed.
    public var manualOverride: Endpoint? {
        didSet {
            if let endpoint = manualOverride {
                onEndpointResolved?(endpoint)
            }
        }
    }

    private static let serviceType = "_roon-bridge._tcp"
    private static let fallbackHost = "mini.local"
    private static let fallbackPort: UInt16 = 3100
    private static let fallbackTimeoutSeconds: TimeInterval = 5.0

    private var browser: NWBrowser?
    private var fallbackTask: Task<Void, Never>?
    private var resolved = false

    public init() {}

    public func start() {
        if let override = manualOverride {
            onEndpointResolved?(override)
            return
        }

        startMDNS()
        startFallbackTask()
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    // -------------------------------------------------------------------------

    private func startMDNS() {
        let params = NWParameters()
        params.includePeerToPeer = false

        let descriptor = NWBrowser.Descriptor.bonjour(
            type: Self.serviceType,
            domain: "local."
        )

        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.resolved else { return }

                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        await self.resolve(name: name, type: type, domain: domain)
                        break
                    }
                }
            }
        }

        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("[BridgeDiscovery] mDNS browser error: \(error)")
            }
        }

        browser.start(queue: .main)
    }

    private func resolve(name: String, type: String, domain: String) async {
        guard !resolved else { return }

        let endpoint = NWEndpoint.service(
            name: name,
            type: type,
            domain: domain,
            interface: nil
        )

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            var didResume = false

            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, !didResume else { return }

                    if case .ready = state {
                        if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                           case let .hostPort(host, port) = innerEndpoint {
                            didResume = true
                            self.resolved = true
                            self.fallbackTask?.cancel()
                            self.browser?.cancel()
                            let resolved = Endpoint(host: "\(host)", port: port.rawValue)
                            self.onEndpointResolved?(resolved)
                        }
                        connection.cancel()
                        if !didResume { continuation.resume() }
                    } else if case let .failed(error) = state {
                        print("[BridgeDiscovery] Resolve connection failed: \(error)")
                        connection.cancel()
                        if !didResume {
                            didResume = true
                            continuation.resume()
                        }
                    }
                }
            }

            connection.start(queue: .main)

            // Timeout after 2s per resolve attempt
            Task {
                try? await Task.sleep(for: .seconds(2))
                if !didResume {
                    didResume = true
                    connection.cancel()
                    continuation.resume()
                }
            }
        }
    }

    private func startFallbackTask() {
        fallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.fallbackTimeoutSeconds))
            } catch {
                return // cancelled
            }
            guard let self, !self.resolved else { return }
            self.resolved = true
            let endpoint = Endpoint(host: Self.fallbackHost, port: Self.fallbackPort)
            print("[BridgeDiscovery] mDNS timeout, falling back to \(Self.fallbackHost):\(Self.fallbackPort)")
            self.onEndpointResolved?(endpoint)
        }
    }
}
