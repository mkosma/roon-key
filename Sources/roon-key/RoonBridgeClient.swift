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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        addAuth(&request)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let decoder = JSONDecoder()
        return try decoder.decode(BridgeStatus.self, from: data)
    }

    // -------------------------------------------------------------------------
    // Event stream (Server-Sent Events)
    // -------------------------------------------------------------------------

    /// Returns an async sequence of zone events pushed by the bridge.
    /// The stream terminates on connection drop or HTTP error; callers
    /// should reconnect with backoff.
    public func events() -> AsyncThrowingStream<ZoneEvent, Error> {
        let url = baseURL.appendingPathComponent("control/events")
        let token = authToken
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 60 * 60 * 24
                    if let token, !token.isEmpty {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }

                    // Dedicated config with long timeouts so the long-lived
                    // SSE stream doesn't trip the 60s default.
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 60 * 60 * 24
                    config.timeoutIntervalForResource = 60 * 60 * 24 * 7
                    let session = URLSession(configuration: config)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw RoonBridgeError.invalidResponse
                    }

                    // Parse SSE byte-by-byte. AsyncLineSequence (.lines) drops
                    // empty lines, which are the SSE event delimiter -- we'd
                    // never dispatch anything.
                    var lineBytes: [UInt8] = []
                    var dataBuffer = ""
                    func dispatchLine(_ line: String) {
                        if line.isEmpty {
                            if !dataBuffer.isEmpty,
                               let payload = dataBuffer.data(using: .utf8),
                               let event = try? JSONDecoder().decode(ZoneEvent.self, from: payload) {
                                continuation.yield(event)
                            }
                            dataBuffer = ""
                        } else if line.hasPrefix("data:") {
                            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                            dataBuffer += payload
                        }
                        // : <comment> (keep-alives) and event: lines ignored.
                    }
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A { // \n
                            // Strip trailing \r if present (CRLF).
                            if lineBytes.last == 0x0D { lineBytes.removeLast() }
                            let line = String(decoding: lineBytes, as: UTF8.self)
                            lineBytes.removeAll(keepingCapacity: true)
                            dispatchLine(line)
                        } else {
                            lineBytes.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        NotificationCenter.default.post(name: .roonKeyDidAct, object: nil)
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
    public let state: String?
    public let volume: Int?
    public let muted: Bool
    public let outputs: [OutputStatus]
    public let nowPlayingTitle: String?
    public let nowPlayingArtist: String?
    public let nowPlayingAlbum: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case state
        case volume
        case muted
        case outputs
        case nowPlayingTitle = "now_playing_title"
        case nowPlayingArtist = "now_playing_artist"
        case nowPlayingAlbum = "now_playing_album"
    }
}

public struct ZoneEvent: Codable {
    public let roonConnected: Bool
    public let zone: ZoneStatus?

    enum CodingKeys: String, CodingKey {
        case roonConnected = "roon_connected"
        case zone
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
