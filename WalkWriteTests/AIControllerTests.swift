import XCTest
@testable import WalkWrite

private final class MemoryTokenStore: AppTokenStoring {
    var tokens: [URL: String] = [:]
    func read(for endpoint: URL) throws -> String? { tokens[endpoint] }
    func save(_ token: String, for endpoint: URL) throws { tokens[endpoint] = token }
    func remove(for endpoint: URL) throws { tokens[endpoint] = nil }
}

private actor ControlledSummaryService: AISummaryService {
    private var continuation: CheckedContinuation<AISummaryResult, Error>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    func generateSummary(noteID: UUID, transcript: String, revision: Int,
                         segments: [TranscriptSegment]) async throws -> AISummaryResult {
        count += 1
        // Intentionally ignores Task cancellation to test the late-response guard.
        return try await withCheckedThrowingContinuation {
            continuation = $0
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }
    func checkStatus() async throws -> BackendStatus { BackendStatus(configured: true, requestId: "test") }
    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func succeed(revision: Int) {
        continuation?.resume(returning: AISummaryResult(
            transcriptRevision: revision, title: "Test result", summary: "Test summary",
            keyPoints: [], actionItems: [], model: "test-model"))
        continuation = nil
    }
}

@MainActor
final class AIControllerTests: XCTestCase {
    private func waitForIdle(_ controller: AIController) async {
        for _ in 0..<1000 {
            if controller.processingIDs.isEmpty { return }
            await Task.yield()
        }
        XCTFail("Controller did not finish its test operation")
    }

    func testDefaultSettingsNeverEnableAutomaticOrCellularAI() async throws {
        let name = "VoiceNotesSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, tokenStore: MemoryTokenStore())
        XCTAssertFalse(settings.automaticSummary)
        XCTAssertFalse(settings.useCellularForAI)
        XCTAssertFalse(settings.isBackendConfigured)
        XCTAssertThrowsError(try settings.backendConfiguration())
    }

    func testEndpointChangesDoNotReuseTokensAndPreferencesNeverStoreToken() async throws {
        let name = "VoiceNotesSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let tokens = MemoryTokenStore()
        let settings = AppSettings(defaults: defaults, tokenStore: tokens)
        let token = "test-only-personal-token-000000000000"
        try settings.saveBackend(urlString: "https://backend.test/", newToken: token)
        XCTAssertTrue(settings.isBackendConfigured)
        XCTAssertThrowsError(try settings.saveBackend(urlString: "https://different.test", newToken: ""))
        XCTAssertThrowsError(try settings.saveBackend(urlString: "http://backend.test", newToken: token))
        XCTAssertThrowsError(try settings.saveBackend(urlString: "https://backend.test/?secret=value", newToken: token))
        XCTAssertThrowsError(try AppSettings.validateToken("sk-" + String(repeating: "x", count: 40)))
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == token })
    }

    func testUnconfiguredAndOfflineRequestsNeverUseService() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceNotesControllerTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Local text")
        try store.add(note)
        let name = "VoiceNotesSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, tokenStore: MemoryTokenStore())
        let service = ControlledSummaryService()
        let controller = AIController(store: store, settings: settings,
            network: NetworkMonitor(initialState: .offline, startMonitoring: false), makeService: { _ in service })
        controller.requestSummary(noteID: note.id)
        XCTAssertNotNil(controller.message)
        try settings.saveBackend(urlString: "https://backend.test", newToken: "test-only-personal-token-000000000000")
        controller.requestSummary(noteID: note.id)
        XCTAssertEqual(store[note.id]?.aiStatus, .waitingForInternet)
        let calls = await service.count
        XCTAssertEqual(calls, 0)
        XCTAssertNil(store[note.id]?.aiSummary)
    }

    func testControllerDropsLateRevisionThreeResultAfterRevisionFourEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceNotesControllerTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"),
                        rawTranscript: "Raw", editedTranscript: "Revision 3", transcriptRevision: 3,
                        aiSummary: "Previous", aiTranscriptRevision: 3)
        try store.add(note)
        let name = "VoiceNotesSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, tokenStore: MemoryTokenStore())
        try settings.saveBackend(urlString: "https://backend.test", newToken: "test-only-personal-token-000000000000")
        let service = ControlledSummaryService()
        let controller = AIController(store: store, settings: settings,
            network: NetworkMonitor(initialState: .wifi, startMonitoring: false), makeService: { _ in service })
        controller.requestSummary(noteID: note.id)
        await service.waitForRequest()
        controller.requestSummary(noteID: note.id)
        try store.editTranscript(id: note.id, text: "Revision 4")
        await service.succeed(revision: 3)
        await waitForIdle(controller)
        XCTAssertEqual(store[note.id]?.editedTranscript, "Revision 4")
        XCTAssertEqual(store[note.id]?.rawTranscript, "Raw")
        XCTAssertEqual(store[note.id]?.aiSummary, "Previous")
        let calls = await service.count
        XCTAssertEqual(calls, 1)
    }

    func testCancellationRetainsPreviousResultEvenWhenTransportReturnsSuccessLater() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceNotesControllerTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Raw",
                        aiSummary: "Previous", aiTranscriptRevision: 0)
        try store.add(note)
        let name = "VoiceNotesSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, tokenStore: MemoryTokenStore())
        try settings.saveBackend(urlString: "https://backend.test", newToken: "test-only-personal-token-000000000000")
        let service = ControlledSummaryService()
        let controller = AIController(store: store, settings: settings,
            network: NetworkMonitor(initialState: .wifi, startMonitoring: false), makeService: { _ in service })
        controller.requestSummary(noteID: note.id)
        await service.waitForRequest()
        controller.cancel(noteID: note.id)
        await service.succeed(revision: 0)
        await waitForIdle(controller)
        XCTAssertEqual(store[note.id]?.aiSummary, "Previous")
    }
}
