import XCTest
import Foundation
@testable import roon_key

/// Tests for RoonBridgeClient request encoding and error handling.
/// Uses a MockURLProtocol to intercept URLSession requests without
/// making real network calls.
@MainActor
final class RoonBridgeClientTests: XCTestCase {

    private var session: URLSession!
    private var client: RoonBridgeClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = RoonBridgeClient(session: session)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // -------------------------------------------------------------------------
    // Encoding tests
    // -------------------------------------------------------------------------

    func testVolumeRampEncodesDirectionAndStep() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true,"direction":"up","step":8}"#.utf8))
        }

        try await client.volumeRamp(direction: .up, step: 8)

        XCTAssertNotNil(capturedRequest)
        let body = try JSONSerialization.jsonObject(with: capturedRequest!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["direction"] as? String, "up")
        XCTAssertEqual(body["step"] as? Int, 8)
        XCTAssertTrue(capturedRequest!.url!.path.contains("volume_ramp"))
    }

    func testVolumeInstantDownEncoding() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }

        try await client.volumeInstant(direction: .down, step: 5)

        let body = try JSONSerialization.jsonObject(with: capturedRequest!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["direction"] as? String, "down")
        XCTAssertEqual(body["step"] as? Int, 5)
    }

    func testTransportEncoding() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }

        try await client.transport(action: .playpause)

        let body = try JSONSerialization.jsonObject(with: capturedRequest!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["action"] as? String, "playpause")
        XCTAssertTrue(capturedRequest!.url!.path.contains("transport"))
    }

    func testVolumePresetEncoding() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }

        try await client.volumePreset(index: 3, instant: true)

        let body = try JSONSerialization.jsonObject(with: capturedRequest!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["index"] as? Int, 3)
        XCTAssertEqual(body["instant"] as? Bool, true)
    }

    // -------------------------------------------------------------------------
    // Error handling
    // -------------------------------------------------------------------------

    func testHTTP400ThrowsHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":false,"error":"test"}"#.utf8))
        }

        do {
            try await client.volumeRamp(direction: .up)
            XCTFail("Expected error not thrown")
        } catch let error as RoonBridgeError {
            if case let .httpError(code, _) = error {
                XCTAssertEqual(code, 400)
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTP500ThrowsHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":false,"error":"internal"}"#.utf8))
        }

        do {
            try await client.muteToggle()
            XCTFail("Expected error not thrown")
        } catch let error as RoonBridgeError {
            if case let .httpError(code, _) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // -------------------------------------------------------------------------
    // Status decoding
    // -------------------------------------------------------------------------

    func testStatusResponseDecoding() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = #"""
            {
                "ok": true,
                "roon_connected": true,
                "zone": {
                    "display_name": "WiiM + 1",
                    "volume": 64,
                    "muted": false,
                    "outputs": [{"name": "WiiM", "volume": 64, "muted": false}]
                },
                "config": {
                    "active_zone_display_name": "WiiM + 1",
                    "volume_step": 8,
                    "ramp_step_ms": 20,
                    "presets": [32, 40, 48, 56, 64, 72, 80],
                    "extras": {"open_roon_app": true, "muse_toggle": false, "favorites": []}
                },
                "zones": []
            }
            """#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }

        let status = try await client.status()
        XCTAssertTrue(status.ok)
        XCTAssertTrue(status.roonConnected)
        XCTAssertEqual(status.zone?.displayName, "WiiM + 1")
        XCTAssertEqual(status.zone?.volume, 64)
        XCTAssertFalse(status.zone?.muted ?? true)
        XCTAssertEqual(status.config?.volumeStep, 8)
        XCTAssertEqual(status.config?.presets, [32, 40, 48, 56, 64, 72, 80])
    }

    // -------------------------------------------------------------------------
    // setEndpoint
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Auth header
    // -------------------------------------------------------------------------

    func testAuthHeaderAttachedWhenTokenProvided() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let authedSession = URLSession(configuration: config)
        let authedClient = RoonBridgeClient(session: authedSession, authToken: "test-token-abc")

        var capturedHeader: String?
        MockURLProtocol.requestHandler = { request in
            capturedHeader = request.value(forHTTPHeaderField: "Authorization")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }

        try await authedClient.volumeRamp(direction: .up, step: 4)
        XCTAssertEqual(capturedHeader, "Bearer test-token-abc")
    }

    func testNoAuthHeaderWhenTokenNil() async throws {
        var capturedHeader: String?
        MockURLProtocol.requestHandler = { request in
            capturedHeader = request.value(forHTTPHeaderField: "Authorization")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }

        try await client.volumeRamp(direction: .up)
        XCTAssertNil(capturedHeader)
    }

    func testAuthHeaderOnGetRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let authedSession = URLSession(configuration: config)
        let authedClient = RoonBridgeClient(session: authedSession, authToken: "tok")

        var capturedHeader: String?
        MockURLProtocol.requestHandler = { request in
            capturedHeader = request.value(forHTTPHeaderField: "Authorization")
            let json = #"{"ok":true,"roon_connected":true}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }

        _ = try await authedClient.status()
        XCTAssertEqual(capturedHeader, "Bearer tok")
    }

    // -------------------------------------------------------------------------
    // setEndpoint
    // -------------------------------------------------------------------------

    func testSetEndpointUpdatesBaseURL() async throws {
        var capturedURL: URL?

        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }

        let endpoint = BridgeDiscovery.Endpoint(host: "192.168.1.10", port: 3100)
        client.setEndpoint(endpoint)

        try await client.muteToggle()

        XCTAssertEqual(capturedURL?.host, "192.168.1.10")
        XCTAssertEqual(capturedURL?.port, 3100)
    }
}

// -------------------------------------------------------------------------
// MockURLProtocol
// -------------------------------------------------------------------------

class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockError", code: -1))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
