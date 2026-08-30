import XCTest
@testable import WalkWrite

private actor StubHTTPTransport: BackendHTTPTransport {
    let response: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private(set) var requests: [URLRequest] = []
    init(response: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) { self.response = response }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await response(request)
    }
}

final class BackendClientTests: XCTestCase {
    private let endpoint = URL(string: "https://backend.test")!
    private let sample = """
    {"transcriptRevision":3,"title":"회의","summary":"금요일 SDK 2.0 검토","keyPoints":["SDK 2.0"],"actionItems":[{"text":"검토 공유"}],"model":"test-model","generatedAt":"2026-08-28T10:20:30.123Z","requestId":"test-request"}
    """

    private func client(_ transport: any BackendHTTPTransport) -> BackendAPIClient {
        BackendAPIClient(configuration: BackendConfiguration(
            baseURL: endpoint, appToken: "test-only-personal-token-000000000000", allowsCellular: false),
                         transport: transport)
    }

    private func generate(_ client: BackendAPIClient) async throws -> AISummaryResult {
        try await client.summarize(noteID: UUID(), transcript: "한국어 日本語 Español SDK",
                                   revision: 3, segments: [])
    }

    func testRequestCarriesEditedTextRevisionAndDecodesAllStructuredFields() async throws {
        let data = Data(sample.utf8)
        let transport = StubHTTPTransport { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!)
        }
        let result = try await generate(client(transport))
        XCTAssertEqual(result.title, "회의")
        XCTAssertEqual(result.actionItems.first?.text, "검토 공유")
        XCTAssertNotNil(result.generatedAt)
        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://backend.test/api/summarize")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertFalse(sent.allowsCellularAccess)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["transcriptRevision"] as? Int, 3)
        XCTAssertEqual(body["transcript"] as? String, "한국어 日本語 Español SDK")
        XCTAssertNil(body["model"])
        XCTAssertNil(body["segments"])
    }

    func testNetworkFailuresAreClassified() async throws {
        let errors: [(URLError.Code, AIServiceError)] = [
            (.notConnectedToInternet, .offline), (.timedOut, .timedOut),
            (.cannotFindHost, .dnsFailure), (.dnsLookupFailed, .dnsFailure),
            (.secureConnectionFailed, .tlsFailure), (.networkConnectionLost, .networkFailure),
            (.cancelled, .cancelled), (.dataNotAllowed, .cellularNotAllowed)
        ]
        for (code, expected) in errors {
            let transport = StubHTTPTransport { _ in throw URLError(code) }
            do { _ = try await generate(client(transport)); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? AIServiceError, expected) }
        }
    }

    func testHTTPAndBackendConfigurationErrorsAreClassified() async throws {
        let errors: [(Int, AIServiceError)] = [
            (401, .unauthorized), (403, .forbidden), (429, .rateLimited),
            (500, .backendUnavailable), (502, .upstreamFailure), (504, .timedOut),
            (413, .invalidRequest), (302, .httpStatus(302))
        ]
        for (code, expected) in errors {
            let transport = StubHTTPTransport { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await generate(client(transport)); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? AIServiceError, expected) }
        }
        let missing = StubHTTPTransport { request in
            (Data(#"{"error":{"code":"backend_not_configured"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await generate(client(missing)); XCTFail("Expected missing configuration") }
        catch { XCTAssertEqual(error as? AIServiceError, .notConfigured) }
    }

    func testInvalidJSONAndWrongRevisionCannotBeReturnedAsSummary() async throws {
        for response in ["not JSON", sample.replacingOccurrences(of: #""transcriptRevision":3"#, with: #""transcriptRevision":2"#),
                         sample.replacingOccurrences(of: #""title":"회의""#, with: #""title":""""#)] {
            let transport = StubHTTPTransport { request in
                (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"])!)
            }
            do { _ = try await generate(client(transport)); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? AIServiceError, .invalidResponse) }
        }
    }
}
