import XCTest
@testable import Cai

// MARK: - Mock URL Protocol

/// URLProtocol subclass that returns predefined responses in sequence.
/// Each call to `startLoading()` pops the next response from the queue.
final class MockURLProtocol: URLProtocol {

    /// Queue of responses to return. Each `startLoading()` pops the first item.
    /// Thread-safe via a lock since URLSession may call from different threads.
    nonisolated(unsafe) static var responses: [MockResponse] = []
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    struct MockResponse {
        let statusCode: Int?       // nil = throw URLError
        let urlErrorCode: URLError.Code?
        let body: Data
        let headers: [String: String]

        /// Successful JSON-RPC response
        static func success(_ json: [String: Any] = [:]) -> MockResponse {
            let result: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": json]
            let data = try! JSONSerialization.data(withJSONObject: result)
            return MockResponse(statusCode: 200, urlErrorCode: nil, body: data, headers: ["Content-Type": "application/json"])
        }

        /// HTTP error response
        static func httpError(_ statusCode: Int, body: String = "") -> MockResponse {
            MockResponse(statusCode: statusCode, urlErrorCode: nil, body: body.data(using: .utf8) ?? Data(), headers: [:])
        }

        /// Network error (URLError)
        static func networkError(_ code: URLError.Code) -> MockResponse {
            MockResponse(statusCode: nil, urlErrorCode: code, body: Data(), headers: [:])
        }
    }

    static func reset() {
        lock.lock()
        responses = []
        requestCount = 0
        lock.unlock()
    }

    private static func popResponse() -> MockResponse? {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = Self.popResponse() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        if let errorCode = response.urlErrorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode ?? 200,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class MCPTransportClientTests: XCTestCase {

    private func makeClient() -> MCPTransportClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = 2
        return MCPTransportClient(
            endpoint: URL(string: "https://test.example.com/mcp")!,
            session: URLSession(configuration: config)
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Retry on transient errors

    func testRetriesOnServerError() async throws {
        // 2x 503 then success
        MockURLProtocol.responses = [
            .httpError(503, body: "Service Unavailable"),
            .httpError(503, body: "Service Unavailable"),
            .success(["tools": []]),
        ]

        let client = makeClient()
        let tools = try await client.listTools()

        XCTAssertEqual(tools.count, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "Should have made 3 attempts")
    }

    func testRetriesOnTimeout() async throws {
        // 2x timeout then success
        MockURLProtocol.responses = [
            .networkError(.timedOut),
            .networkError(.timedOut),
            .success(["tools": []]),
        ]

        let client = makeClient()
        let tools = try await client.listTools()

        XCTAssertEqual(tools.count, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "Should have made 3 attempts")
    }

    func testFailsImmediatelyOnOffline() async {
        // -1009 not connected — should NOT retry
        MockURLProtocol.responses = [
            .networkError(.notConnectedToInternet),
            .success(["tools": []]),  // should never reach this
        ]

        let client = makeClient()
        do {
            _ = try await client.listTools()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(MockURLProtocol.requestCount, 1, "Should NOT retry when offline")
        }
    }

    func testFailsImmediatelyOnConnectionLost() async {
        // -1005 connection lost — should NOT retry
        MockURLProtocol.responses = [
            .networkError(.networkConnectionLost),
            .success(["tools": []]),
        ]

        let client = makeClient()
        do {
            _ = try await client.listTools()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(MockURLProtocol.requestCount, 1, "Should NOT retry on connection lost")
        }
    }

    // MARK: - No retry on auth/client errors

    func testFailsImmediatelyOnAuth() async {
        MockURLProtocol.responses = [
            .httpError(401, body: "Unauthorized"),
            .success(["tools": []]),
        ]

        let client = makeClient()
        do {
            _ = try await client.listTools()
            XCTFail("Should have thrown")
        } catch let error as MCPError {
            if case .authMissing = error {
                // expected
            } else {
                XCTFail("Expected authMissing, got \(error)")
            }
            XCTAssertEqual(MockURLProtocol.requestCount, 1, "Should NOT retry on 401")
        } catch {
            XCTFail("Expected MCPError, got \(error)")
        }
    }

    func testFailsImmediatelyOnClientError() async {
        MockURLProtocol.responses = [
            .httpError(422, body: "Unprocessable"),
            .success(["tools": []]),
        ]

        let client = makeClient()
        do {
            _ = try await client.listTools()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(MockURLProtocol.requestCount, 1, "Should NOT retry on 422")
        }
    }

    // MARK: - Exhausted retries

    func testThrowsAfterAllRetriesExhausted() async {
        MockURLProtocol.responses = [
            .httpError(503),
            .httpError(502),
            .httpError(504),
        ]

        let client = makeClient()
        do {
            _ = try await client.listTools()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(MockURLProtocol.requestCount, 3, "Should exhaust all 3 attempts")
        }
    }
}
