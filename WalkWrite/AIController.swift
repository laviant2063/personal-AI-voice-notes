import Foundation
import Observation

/// Owns user-authorized AI operations. Network-monitor events never enter here.
@MainActor
@Observable
final class AIController {
    private(set) var processingIDs: Set<UUID> = []
    private(set) var backendStatusText = "Not checked"
    private(set) var isCheckingBackend = false
    var message: String?

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let makeService: (BackendConfiguration) -> any AISummaryService
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var contexts: [UUID: AIRequestContext] = [:]
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var configurationGeneration = 0

    init(store: NoteStore, settings: AppSettings, network: NetworkMonitor,
         makeService: @escaping (BackendConfiguration) -> any AISummaryService = {
             RemoteAISummaryService(client: BackendAPIClient(configuration: $0))
         }) {
        self.store = store
        self.settings = settings
        self.network = network
        self.makeService = makeService
    }

    /// Called once after a *new local STT result* has been durably saved.
    /// Never called when loading notes, saving an edit, or reconnecting.
    func transcriptSaved(noteID: UUID) {
        guard settings.automaticSummary, settings.isBackendConfigured else { return }
        guard network.isAvailable else {
            setWaiting(noteID: noteID, reason: AIServiceError.offline.localizedDescription)
            return
        }
        requestSummary(noteID: noteID)
    }

    func requestSummary(noteID: UUID) {
        guard tasks[noteID] == nil, let note = store[noteID] else { return }
        guard !note.editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Save a transcript before requesting AI processing."
            return
        }
        let configuration: BackendConfiguration
        do {
            configuration = try settings.backendConfiguration()
        } catch {
            backendStatusText = "Not Configured"
            message = error.localizedDescription
            return
        }
        if network.state == .offline {
            setWaiting(noteID: noteID, reason: AIServiceError.offline.localizedDescription)
            return
        }
        if !configuration.allowsCellular && network.needsCellularPermission {
            setWaiting(noteID: noteID, reason: AIServiceError.cellularNotAllowed.localizedDescription)
            return
        }
        let context: AIRequestContext
        do { context = try store.beginAIRequest(id: noteID) }
        catch {
            message = error.localizedDescription
            return
        }
        contexts[noteID] = context
        processingIDs.insert(noteID)
        let service = makeService(configuration)
        tasks[noteID] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.tasks[noteID] = nil
                self.contexts[noteID] = nil
                self.processingIDs.remove(noteID)
            }
            do {
                let result = try await service.generateSummary(
                    noteID: context.noteID, transcript: context.transcript,
                    revision: context.revision, segments: context.segments)
                try Task.checkCancellation()
                let applied = try self.store.completeAIRequest(context, result: result)
                if !applied, self.store[noteID] != nil {
                    self.message = "The transcript changed while AI was processing. The older response was discarded; any previous result is unchanged."
                }
            } catch {
                let failure: AIServiceError
                if Task.isCancelled || error is CancellationError {
                    failure = .cancelled
                } else {
                    failure = (error as? AIServiceError) ?? .backendUnavailable
                }
                if failure == .notConfigured { self.backendStatusText = "Not Configured" }
                let status: AIProcessingStatus =
                    (failure == .offline || failure == .cellularNotAllowed) ? .waitingForInternet : .failed
                do {
                    try self.store.failAIRequest(context, status: status,
                                                 message: failure.localizedDescription)
                } catch {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func cancel(noteID: UUID) {
        tasks[noteID]?.cancel()
        // Invalidate the store's request token immediately. Even an uncooperative
        // transport cannot later save a cancelled response with the same revision.
        if let context = contexts[noteID] {
            do {
                try store.failAIRequest(context, status: .failed,
                                        message: AIServiceError.cancelled.localizedDescription)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func cancelAll() {
        for noteID in Array(tasks.keys) { cancel(noteID: noteID) }
        statusTask?.cancel()
    }

    func configurationChanged() {
        configurationGeneration += 1
        cancelAll()
        isCheckingBackend = false
        backendStatusText = settings.isBackendConfigured ? "Configured locally; not checked" : "Not Configured"
    }

    func checkBackendStatus() {
        guard !isCheckingBackend else { return }
        let configuration: BackendConfiguration
        do { configuration = try settings.backendConfiguration() }
        catch {
            backendStatusText = "Not Configured"
            message = error.localizedDescription
            return
        }
        let generation = configurationGeneration
        let service = makeService(configuration)
        isCheckingBackend = true
        statusTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.configurationGeneration == generation { self.isCheckingBackend = false }
            }
            do {
                // Only an authenticated readiness request; no transcript and no
                // upstream model request are sent by this endpoint.
                let status = try await service.checkStatus()
                try Task.checkCancellation()
                guard self.configurationGeneration == generation else { return }
                self.backendStatusText = status.configured ? "Configured — backend reports ready" : "Not Configured — backend AI settings missing"
            } catch {
                guard self.configurationGeneration == generation, !Task.isCancelled else { return }
                self.backendStatusText = error.localizedDescription
            }
        }
    }

    private func setWaiting(noteID: UUID, reason: String) {
        do { try store.setAIWaiting(id: noteID, message: reason) }
        catch { message = error.localizedDescription }
    }
}
