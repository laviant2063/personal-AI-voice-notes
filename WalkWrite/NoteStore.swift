import Foundation
import Observation

enum NoteStoreError: Error, LocalizedError {
    case readOnly, noteMissing, duplicateNote, duplicateRequest, emptyTranscript
    case transcriptAlreadyCaptured, revisionExhausted, invalidResult, invalidAudio, writeFailed

    var errorDescription: String? {
        switch self {
        case .readOnly: return "The note index could not be loaded safely. Files are preserved; changes are disabled until storage is recovered."
        case .noteMissing: return "This note no longer exists."
        case .duplicateNote: return "A note with this identifier already exists."
        case .duplicateRequest: return "AI processing is already running for this note."
        case .emptyTranscript: return "A saved transcript is required before AI processing."
        case .transcriptAlreadyCaptured: return "The original transcript is already saved and will not be overwritten."
        case .revisionExhausted: return "The transcript revision limit has been reached."
        case .invalidResult: return "The AI result does not match this request."
        case .invalidAudio: return "This audio file is not in the app's managed notes folder."
        case .writeFailed: return "The note could not be saved. Existing files were preserved. Check available device storage and try again."
        }
    }
}

/// Writes commit to disk before the observable list changes. Failed reads never
/// become a writable empty index. The upstream JSON array format is preserved.
@MainActor
@Observable
public final class NoteStore {
    private(set) var notes: [Note] = []
    private(set) var storageError: String?
    private(set) var isReadOnly = false
    @ObservationIgnored var onTranscriptionSaved: ((UUID) -> Void)?
    @ObservationIgnored private var activeRequests: [UUID: AIRequestContext] = [:]
    @ObservationIgnored private var deletedAudioFilenames: Set<String> = []
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fileManager: FileManager

    private var indexURL: URL { directory.appendingPathComponent("notes.json") }
    private var backupURL: URL { directory.appendingPathComponent("notes.backup.json") }
    private var tombstoneURL: URL { directory.appendingPathComponent("deleted-audio.json") }

    init(directory: URL = AppFolders.notes, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        load()
    }

    subscript(id: UUID) -> Note? { notes.first { $0.id == id } }

    func add(_ note: Note) throws {
        guard self[note.id] == nil else { throw NoteStoreError.duplicateNote }
        guard AppFolders.isManagedAudio(note.audioURL, in: directory) else {
            throw NoteStoreError.invalidAudio
        }
        try commit(([note] + notes).sorted { $0.createdAt > $1.createdAt })
    }

    func updateRecording(id: UUID, duration: TimeInterval, completed: Bool) throws {
        guard duration.isFinite, duration >= 0 else { throw NoteStoreError.invalidAudio }
        try mutate(id) {
            $0.duration = duration
            $0.recordingComplete = completed
        }
    }

    func setTranscriptionStatus(id: UUID, status: TranscriptionStatus, error: String? = nil) throws {
        try mutate(id) {
            $0.transcriptionStatus = status
            $0.transcriptionError = error
        }
    }

    func setTranscription(id: UUID, text: String, segments: [TranscriptSegment], words: [WordStamp]) throws {
        guard let current = self[id] else { throw NoteStoreError.noteMissing }
        guard !current.hasCapturedTranscript else { throw NoteStoreError.transcriptAlreadyCaptured }
        try mutate(id) { note in
            _ = note.captureTranscription(text: text, segments: segments, words: words)
        }
        // Only a newly saved local STT result with an eligible edited transcript
        // can trigger opt-in automatic AI. A provisional live draft is excluded.
        if self[id]?.editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            onTranscriptionSaved?(id)
        }
    }

    /// Saves best-effort on-device recognition while recording. A live draft is
    /// deliberately separate from edited/raw STT and cannot trigger remote AI.
    @discardableResult
    func setLiveTranscriptDraft(id: UUID, text: String) throws -> Bool {
        guard let note = self[id] else { throw NoteStoreError.noteMissing }
        guard !note.hasCapturedTranscript, note.transcriptRevision == 0 else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != note.liveTranscriptDraft else { return false }
        try mutate(id) { _ = $0.applyLiveTranscriptDraft(text) }
        return true
    }

    func editTranscript(id: UUID, text: String) throws {
        guard let note = self[id] else { throw NoteStoreError.noteMissing }
        guard text != note.editedTranscript || note.liveTranscriptDraft != nil else { return }
        try mutate(id) { _ = try $0.applyTranscriptEdit(text) }
    }

    func setActionCompleted(noteID: UUID, actionID: UUID, completed: Bool) throws {
        try mutate(noteID) { note in
            guard let index = note.actionItems.firstIndex(where: { $0.id == actionID }) else {
                throw NoteStoreError.noteMissing
            }
            note.actionItems[index].completed = completed
        }
    }

    func beginAIRequest(id: UUID) throws -> AIRequestContext {
        guard activeRequests[id] == nil else { throw NoteStoreError.duplicateRequest }
        guard let note = self[id] else { throw NoteStoreError.noteMissing }
        guard note.recordingComplete,
              !note.editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteStoreError.emptyTranscript
        }
        let context = AIRequestContext(
            noteID: id, revision: note.transcriptRevision, transcript: note.editedTranscript,
            segments: note.editedTranscript == note.rawTranscript ? note.transcriptSegments : [])
        try mutate(id) {
            $0.aiStatus = .processing
            $0.aiError = nil
        }
        activeRequests[id] = context
        return context
    }

    @discardableResult
    func completeAIRequest(_ context: AIRequestContext, result: AISummaryResult) throws -> Bool {
        guard activeRequests[context.noteID]?.requestID == context.requestID else { return false }
        guard let note = self[context.noteID] else {
            activeRequests[context.noteID] = nil
            return false
        }
        guard context.revision == note.transcriptRevision else {
            activeRequests[context.noteID] = nil
            try resetStaleRequest(context.noteID)
            return false
        }
        guard result.transcriptRevision == context.revision,
              !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteStoreError.invalidResult
        }
        try mutate(context.noteID) {
            $0.aiTitle = result.title
            $0.aiSummary = result.summary
            $0.keyPoints = result.keyPoints
            $0.actionItems = result.actionItems.map { ActionItem(text: $0.text) }
            $0.aiModel = result.model
            $0.aiGeneratedAt = result.generatedAt ?? .now
            $0.aiTranscriptRevision = context.revision
            $0.aiStatus = .completed
            $0.aiError = nil
        }
        activeRequests[context.noteID] = nil
        return true
    }

    func failAIRequest(_ context: AIRequestContext, status: AIProcessingStatus = .failed,
                       message: String? = nil) throws {
        guard activeRequests[context.noteID]?.requestID == context.requestID else { return }
        activeRequests[context.noteID] = nil
        guard let note = self[context.noteID] else { return }
        if note.transcriptRevision != context.revision {
            try resetStaleRequest(context.noteID)
        } else {
            try mutate(context.noteID) {
                $0.aiStatus = status
                $0.aiError = message
                // Keep the entire prior result, including completed action items.
            }
        }
    }

    func setAIWaiting(id: UUID, message: String? = nil) throws {
        guard activeRequests[id] == nil else { return }
        try mutate(id) {
            $0.aiStatus = .waitingForInternet
            $0.aiError = message
        }
    }

    func delete(id: UUID) throws {
        guard !isReadOnly else { throw NoteStoreError.readOnly }
        guard let note = self[id] else { return }
        let remaining = notes.filter { $0.id != id }
        let removeAudio = AppFolders.isManagedAudio(note.audioURL, in: directory)
            && !remaining.contains { $0.audioURL.standardizedFileURL == note.audioURL.standardizedFileURL }
        if removeAudio {
            // Persist a filename-only tombstone before deleting metadata. A crash
            // or failed cleanup must not resurrect deleted audio as an orphan.
            var tombstones = deletedAudioFilenames
            tombstones.insert(note.audioURL.lastPathComponent)
            do {
                try JSONEncoder().encode(tombstones.sorted()).write(to: tombstoneURL, options: .atomic)
                deletedAudioFilenames = tombstones
            } catch {
                storageError = NoteStoreError.writeFailed.localizedDescription
                throw NoteStoreError.writeFailed
            }
        }
        try commit(remaining)
        activeRequests[id] = nil
        if removeAudio, fileManager.fileExists(atPath: note.audioURL.path) {
            do { try fileManager.removeItem(at: note.audioURL) }
            catch { storageError = "The note was deleted, but its audio file could not be removed. It is retained locally and will not reappear as a recovered note." }
        }
    }

    private func resetStaleRequest(_ id: UUID) throws {
        try mutate(id) {
            $0.aiStatus = $0.hasAIResult ? .completed : .notRequested
            $0.aiError = "The transcript changed. The older AI response was discarded."
        }
    }

    private func mutate(_ id: UUID, change: (inout Note) throws -> Void) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { throw NoteStoreError.noteMissing }
        var candidate = notes
        try change(&candidate[index])
        candidate[index].updatedAt = .now
        try commit(candidate)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.noteStorageDirectory] = directory
        return decoder
    }

    private func readIndex(at url: URL) throws -> [Note] {
        let result = try decoder().decode([Note].self, from: Data(contentsOf: url))
        guard Set(result.map(\.id)).count == result.count else { throw NoteStoreError.duplicateNote }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func load() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: indexURL.path) {
                notes = try readIndex(at: indexURL)
            }
            if fileManager.fileExists(atPath: tombstoneURL.path) {
                let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: tombstoneURL))
                guard names.allSatisfy(AppFolders.isSafeAudioFilename) else { throw NoteStoreError.invalidAudio }
                deletedAudioFilenames = Set(names)
            }
            var recovered = notes
            var changed = false
            for index in recovered.indices {
                if !recovered[index].recordingComplete {
                    recovered[index].recordingComplete = true
                    recovered[index].transcriptionStatus = .failed
                    recovered[index].transcriptionError = "Recording was interrupted. The available audio is preserved; listen before transcribing."
                    changed = true
                } else if recovered[index].transcriptionStatus == .processing {
                    recovered[index].transcriptionStatus = .failed
                    recovered[index].transcriptionError = "Transcription was interrupted. Retry locally when ready."
                    changed = true
                }
                if recovered[index].aiStatus == .processing {
                    recovered[index].aiStatus = .failed
                    recovered[index].aiError = "AI processing was interrupted. Retry manually; no automatic upload was queued."
                    changed = true
                }
            }
            let existingPaths = Set(recovered.map { $0.audioURL.standardizedFileURL })
            let files = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
            for file in files where file.pathExtension.lowercased() == "wav" {
                guard AppFolders.isManagedAudio(file, in: directory),
                      !existingPaths.contains(file.standardizedFileURL),
                      !deletedAudioFilenames.contains(file.lastPathComponent) else { continue }
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 44 else { continue }
                recovered.append(Note(
                    createdAt: values.creationDate ?? .now,
                    audioURL: file, transcriptionStatus: .failed,
                    transcriptionError: "Recovered audio. Listen to it, then retry local transcription."))
                changed = true
            }
            if changed {
                // Recovery never triggers onTranscriptionSaved or remote work.
                try commit(recovered.sorted { $0.createdAt > $1.createdAt })
            }
        } catch {
            isReadOnly = true
            if notes.isEmpty, let backup = try? readIndex(at: backupURL) { notes = backup }
            storageError = "Storage could not be loaded or recovered safely. Original files are preserved; a readable index or backup is shown read-only. No files will be overwritten."
        }
    }

    private func commit(_ candidate: [Note]) throws {
        guard !isReadOnly else { throw NoteStoreError.readOnly }
        do {
            let encoder = JSONEncoder()
            encoder.userInfo[.noteStorageDirectory] = directory
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(candidate)
            if fileManager.fileExists(atPath: indexURL.path) {
                let previous = try Data(contentsOf: indexURL)
                try previous.write(to: backupURL, options: .atomic)
            }
            try data.write(to: indexURL, options: .atomic)
            notes = candidate
            storageError = nil
        } catch {
            storageError = NoteStoreError.writeFailed.localizedDescription
            throw NoteStoreError.writeFailed
        }
    }
}
