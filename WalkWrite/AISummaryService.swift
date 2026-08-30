import Foundation

enum AIServiceError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured, offline, cellularNotAllowed, timedOut, dnsFailure, tlsFailure
    case networkFailure, unauthorized, forbidden, rateLimited, backendUnavailable
    case upstreamFailure, invalidResponse, invalidRequest, responseTooLarge, cancelled
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "AI is not configured. Set up the personal backend and APP_TOKEN in Settings. Recordings and transcripts remain local."
        case .offline: return "No internet connection. Tap Generate again when connected; this note will not upload automatically on reconnection."
        case .cellularNotAllowed: return "AI over cellular or a metered connection is disabled. Use Wi-Fi or allow cellular in Settings."
        case .timedOut: return "The AI request timed out. Your note and any previous AI result are preserved."
        case .dnsFailure: return "The backend address could not be resolved. Check the address and network."
        case .tlsFailure: return "A secure connection to the backend could not be established."
        case .networkFailure: return "The network request failed. Your local note is safe."
        case .unauthorized: return "The backend rejected APP_TOKEN (401). Check the token in Settings."
        case .forbidden: return "The backend denied access (403)."
        case .rateLimited: return "The request limit was reached (429). Wait before trying again."
        case .backendUnavailable: return "The backend is unavailable. Your previous AI result is unchanged."
        case .upstreamFailure: return "The backend could not complete the OpenAI request. Check its configuration or try later."
        case .invalidResponse: return "The backend returned an invalid or incomplete result. Nothing was replaced."
        case .invalidRequest: return "The backend rejected this transcript. Check the configured input limits."
        case .responseTooLarge: return "The backend response exceeded the safe size limit."
        case .cancelled: return "AI processing was cancelled. The note and any previous result are preserved."
        case .httpStatus(let status): return "The backend returned HTTP \(status). Nothing was replaced."
        }
    }
}

struct BackendStatus: Codable, Sendable {
    let configured: Bool
    let requestId: String?
}

protocol AISummaryService: Sendable {
    func generateSummary(noteID: UUID, transcript: String, revision: Int,
                         segments: [TranscriptSegment]) async throws -> AISummaryResult
    func checkStatus() async throws -> BackendStatus
}

struct RemoteAISummaryService: AISummaryService {
    let client: BackendAPIClient

    func generateSummary(noteID: UUID, transcript: String, revision: Int,
                         segments: [TranscriptSegment]) async throws -> AISummaryResult {
        try await client.summarize(noteID: noteID, transcript: transcript,
                                   revision: revision, segments: segments)
    }

    func checkStatus() async throws -> BackendStatus {
        try await client.status()
    }
}
