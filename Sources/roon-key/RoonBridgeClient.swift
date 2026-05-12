import Foundation

/// RoonBridgeClient: URLSession-based async HTTP client for roon-bridge.
///
/// All methods are async/throws. Callers should catch errors and handle
/// gracefully (e.g. show yellow dot in menubar if bridge unreachable).
///
/// The base endpoint is updated by BridgeDiscovery after mDNS resolution.
/// roon-key sends ONE HTTP request per keypress; the bridge handles ramping.
@MainActor
public class RoonBridgeClient {

    private var baseURL: URL
    private let session: URLSession
    private let authToken: String?
    private let timeoutInterval: TimeInterval = 3.0

    // -------------------------------------------------------------------------
    // Initialisation
    // -------------------------------------------------------------------------

    public init(session: URLSession = .shared, authToken: String? = nil) {
        self.baseURL = URL(string: "http://mini.local:3100")!
        self.session = session
        self.authToken = authToken
    }

    public func setEndpoint(_ endpoint: BridgeDiscovery.Endpoint) {
        if let url = endpoint.baseURL {
            self.baseURL = url
            NSLog("[RoonBridgeClient] Endpoint: \(url)")
        }
    }

    // -------------------------------------------------------------------------
    // Volume control
    // -------------------------------------------------------------------------

    public func volumeRamp(direction: VolumeDirection, step: Int? = nil) async throws {
        var body: [String: Any] = ["direction": direction.rawValue]
        if let step { body["step"] = step }
        try await postControl("volume_ramp", body: body)
    }

    public func volumeInstant(direction: VolumeDirection, step: Int? = nil) async throws {
        var body: [String: Any] = ["direction": direction.rawValue]
        if let step { body["step"] = step }
        try await postControl("volume_instant", body: body)
    }

    public func volumePreset(index: Int, instant: Bool = false) async throws {
        try await postControl("volume_preset", body: ["index": index, "instant": instant])
    }

    public func muteToggle() async throws {
        try await postControl("mute_toggle", body: [:])
    }

    // -------------------------------------------------------------------------
    // Transport control
    // -------------------------------------------------------------------------

    public func transport(action: TransportAction) async throws {
        try await postControl("transport", body: ["action": action.rawValue])
    }

    // -------------------------------------------------------------------------
    // Status
    // -------------------------------------------------------------------------

    public func status() async throws -> BridgeStatus {
        let url = baseURL.appendingPathComponent("control/status")
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        addAuth(&request)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let decoder = JSONDecoder()
        return try decoder.decode(BridgeStatus.self, from: data)
    }

    // -------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------

    public func getConfig() async throws -> RoonKeyConfig {
        let url = baseURL.appendingPathComponent("config/roon-key")
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        addAuth(&request)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let decoded = try JSONDecoder().decode(ConfigResponse.self, from: data)
        return decoded.config
    }

    public func setConfig(_ config: RoonKeyConfig) async throws {
        let url = baseURL.appendingPathComponent("config/roon-key")
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&request)
        request.httpBody = try JSONEncoder().encode(config)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
    }

    // -------------------------------------------------------------------------
    // Extras
    // -------------------------------------------------------------------------

    public func openRoonApp() async throws {
        try await postControl("open_roon_app", body: [:])
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    private func postControl(_ action: String, body: [String: Any]) async throws {
        let url = baseURL.appendingPathComponent("control/\(action)")
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
    }

    private func addAuth(_ request: inout URLRequest) {
        guard let authToken, !authToken.isEmpty else { return }
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RoonBridgeError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RoonBridgeError.httpError(statusCode: http.statusCode, body: body)
        }
    }
}

// -------------------------------------------------------------------------
// Supporting types
// -------------------------------------------------------------------------

public enum VolumeDirection: String, Codable {
    case up
    case down
}

public enum TransportAction: String, Codable {
    case playpause
    case next
    case prev
}

public enum RoonBridgeError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from roon-bridge"
        case let .httpError(code, body):
            return "HTTP \(code): \(body)"
        case .notConnected:
            return "Not connected to roon-bridge"
        }
    }
}

// -------------------------------------------------------------------------
// Response types
// -------------------------------------------------------------------------

public struct BridgeStatus: Codable {
    public let ok: Bool
    public let roonConnected: Bool
    public let zone: ZoneStatus?
    public let config: RoonKeyConfig?
    public let zones: [ZoneSummary]?

    enum CodingKeys: String, CodingKey {
        case ok
        case roonConnected = "roon_connected"
        case zone
        case config
        case zones
    }
}

public struct ZoneStatus: Codable {
    public let displayName: String
    public let volume: Int?
    public let muted: Bool
    public let outputs: [OutputStatus]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case volume
        case muted
        case outputs
    }
}

public struct OutputStatus: Codable {
    public let name: String
    public let volume: Int?
    public let muted: Bool
}

public struct ZoneSummary: Codable, Identifiable {
    public let displayName: String
    public let zoneId: String
    public let state: String

    public var id: String { zoneId }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case zoneId = "zone_id"
        case state
    }
}

public struct RoonKeyConfig: Codable {
    public var activeZoneDisplayName: String
    public var volumeStep: Int
    public var rampStepMs: Int
    public var presets: [Int]
    public var extras: RoonKeyExtras

    public init(
        activeZoneDisplayName: String = "WiiM + 1",
        volumeStep: Int = 8,
        rampStepMs: Int = 20,
        presets: [Int] = [32, 40, 48, 56, 64, 72, 80],
        extras: RoonKeyExtras = RoonKeyExtras()
    ) {
        self.activeZoneDisplayName = activeZoneDisplayName
        self.volumeStep = volumeStep
        self.rampStepMs = rampStepMs
        self.presets = presets
        self.extras = extras
    }

    enum CodingKeys: String, CodingKey {
        case activeZoneDisplayName = "active_zone_display_name"
        case volumeStep = "volume_step"
        case rampStepMs = "ramp_step_ms"
        case presets
        case extras
    }
}

public struct RoonKeyExtras: Codable {
    public var openRoonApp: Bool
    public var museToggle: Bool
    public var favorites: [String]

    public init(openRoonApp: Bool = true, museToggle: Bool = false, favorites: [String] = []) {
        self.openRoonApp = openRoonApp
        self.museToggle = museToggle
        self.favorites = favorites
    }

    enum CodingKeys: String, CodingKey {
        case openRoonApp = "open_roon_app"
        case museToggle = "muse_toggle"
        case favorites
    }
}

private struct ConfigResponse: Codable {
    let ok: Bool
    let config: RoonKeyConfig
}
