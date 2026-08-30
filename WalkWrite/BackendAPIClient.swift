import Foundation

protocol BackendHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward transcript bodies or the personal token to another URL.
        completionHandler(nil)
    }
}

final class BackendURLSessionTransport: BackendHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let maximumResponseBytes = 256 * 1024

    init(allowsCellular: Bool) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 110
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration,
                             delegate: RejectRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw AIServiceError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw AIServiceError.responseTooLarge
            }
            data.append(byte)
            if data.count % 4096 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return (data, response)
    }
}

struct BackendAPIClient: Sendable {
    private let configuration: BackendConfiguration
    private let transport: any BackendHTTPTransport

    init(configuration: BackendConfiguration, transport: (any BackendHTTPTransport)? = nil) {
        self.configuration = configuration
        self.transport = transport ?? BackendURLSessionTransport(allowsCellular: configuration.allowsCellular)
    }

    private struct RequestSegment: Encodable {
        let startTime: TimeInterval
        let endTime: TimeInterval?
        let text: String
    }

    private struct SummaryRequest: Encodable {
        let noteId: String
        let transcript: String
        let transcriptRevision: Int
        let segments: [RequestSegment]?
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    func summarize(noteID: UUID, transcript: String, revision: Int,
                   segments: [TranscriptSegment]) async throws -> AISummaryResult {
        guard revision >= 0, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.invalidRequest
        }
        let payload = SummaryRequest(
            noteId: noteID.uuidString, transcript: transcript, transcriptRevision: revision,
            segments: segments.isEmpty ? nil : segments.map {
                RequestSegment(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
            })
        var request = makeRequest(path: "summarize", method: "POST")
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await execute(request)
        let result: AISummaryResult
        do { result = try Self.decoder().decode(AISummaryResult.self, from: data) }
        catch { throw AIServiceError.invalidResponse }
        guard result.transcriptRevision == revision,
              !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.title.count <= 200, result.summary.count <= 20_000,
              result.keyPoints.count <= 50, result.actionItems.count <= 50,
              result.keyPoints.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 3_000 }),
              result.actionItems.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 3_000 }) else {
            throw AIServiceError.invalidResponse
        }
        return result
    }

    func status() async throws -> BackendStatus {
        let data = try await execute(makeRequest(path: "status", method: "GET"))
        do { return try Self.decoder().decode(BackendStatus.self, from: data) }
        catch { throw AIServiceError.invalidResponse }
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent("api").appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 100)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.allowsCellularAccess = configuration.allowsCellular
        return request
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
            guard data.count <= 256 * 1024 else { throw AIServiceError.responseTooLarge }
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code
            guard (200..<300).contains(http.statusCode) else {
                if code == "backend_not_configured" { throw AIServiceError.notConfigured }
                switch http.statusCode {
                case 400, 413, 422: throw AIServiceError.invalidRequest
                case 401: throw AIServiceError.unauthorized
                case 403: throw AIServiceError.forbidden
                case 408, 504: throw AIServiceError.timedOut
                case 429: throw AIServiceError.rateLimited
                case 499: throw AIServiceError.cancelled
                case 502: throw AIServiceError.upstreamFailure
                case 500...599: throw AIServiceError.backendUnavailable
                default: throw AIServiceError.httpStatus(http.statusCode)
                }
            }
            guard http.mimeType?.lowercased() == "application/json" else {
                throw AIServiceError.invalidResponse
            }
            return data
        } catch is CancellationError {
            throw AIServiceError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw AIServiceError.cancelled
            case .notConnectedToInternet: throw AIServiceError.offline
            case .timedOut: throw AIServiceError.timedOut
            case .cannotFindHost, .dnsLookupFailed: throw AIServiceError.dnsFailure
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                throw AIServiceError.tlsFailure
            case .dataNotAllowed: throw AIServiceError.cellularNotAllowed
            default: throw AIServiceError.networkFailure
            }
        } catch let error as AIServiceError {
            throw error
        } catch {
            throw AIServiceError.networkFailure
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
        }
        return decoder
    }
}
