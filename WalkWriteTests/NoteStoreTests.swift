import XCTest
@testable import WalkWrite

@MainActor
final class NoteStoreTests: XCTestCase {
    private func fixture() throws -> (URL, NoteStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceNotesTests-\(UUID().uuidString)")
        return (directory, NoteStore(directory: directory))
    }

    private func result(revision: Int, summary: String = "New summary") -> AISummaryResult {
        AISummaryResult(transcriptRevision: revision, title: "Title", summary: summary,
                        keyPoints: ["Point"], actionItems: [GeneratedActionItem(text: "Explicit task")],
                        model: "test-model", generatedAt: Date(timeIntervalSinceReferenceDate: 10))
    }

    func testLegacyMigrationPreservesRawAndLegacyAISeparately() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let legacy: [[String: Any]] = [[
            "id": id.uuidString, "createdAt": 0.0, "duration": 12.0,
            "audioURL": "file:///old-container/Library/Application%20Support/Notes/old.wav",
            "transcript": "원본 STT 日本語 123", "words": [],
            "cleanedTranscript": "AI changed this", "summary": "Legacy summary", "keyIdeas": ["Legacy idea"]
        ]]
        let index = directory.appendingPathComponent("notes.json")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try original.write(to: index)
        let store = NoteStore(directory: directory)
        let note = try XCTUnwrap(store[id])
        XCTAssertEqual(note.rawTranscript, "원본 STT 日本語 123")
        XCTAssertEqual(note.editedTranscript, note.rawTranscript)
        XCTAssertEqual(note.cleanedTranscript, "AI changed this")
        XCTAssertEqual(note.aiModel, "legacy-local-llm")
        XCTAssertEqual(note.audioURL, directory.appendingPathComponent("old.wav"))
        XCTAssertEqual(note.transcriptRevision, 0)
        XCTAssertNil(note.liveTranscriptDraft)
        XCTAssertEqual(try Data(contentsOf: index), original, "Loading must not rewrite the index")
    }

    func testRawSTTCannotBeOverwrittenAndEditsIncreaseRevisionOnlyWhenChanged() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        try store.setTranscription(id: note.id, text: "原文 그대로",
                                   segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "原文 그대로")], words: [])
        try store.editTranscript(id: note.id, text: "수정된 transcript")
        try store.editTranscript(id: note.id, text: "수정된 transcript")
        XCTAssertEqual(store[note.id]?.rawTranscript, "原文 그대로")
        XCTAssertEqual(store[note.id]?.transcriptRevision, 1)
        XCTAssertThrowsError(try store.setTranscription(id: note.id, text: "replace", segments: [], words: []))
        XCTAssertEqual(store[note.id]?.rawTranscript, "原文 그대로")
    }

    func testDraftEditedBeforeSTTCompletionIsNotReplaced() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        try store.editTranscript(id: note.id, text: "User draft")
        try store.setTranscription(id: note.id, text: "Local STT", segments: [], words: [])
        XCTAssertEqual(store[note.id]?.rawTranscript, "Local STT")
        XCTAssertEqual(store[note.id]?.editedTranscript, "User draft")
    }

    func testLiveTranscriptDraftSurvivesInterruptedRecordingRelaunch() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), recordingComplete: false)
        try store.add(note)

        XCTAssertTrue(try store.setLiveTranscriptDraft(id: note.id, text: "첫 번째 실시간 문장"))
        XCTAssertTrue(try store.setLiveTranscriptDraft(id: note.id, text: "첫 번째 실시간 문장 두 번째 문장"))
        XCTAssertFalse(try store.setLiveTranscriptDraft(id: note.id, text: ""))

        let reopened = try XCTUnwrap(NoteStore(directory: directory)[note.id])
        XCTAssertEqual(reopened.liveTranscriptDraft, "첫 번째 실시간 문장 두 번째 문장")
        XCTAssertEqual(reopened.displayTranscript, "첫 번째 실시간 문장 두 번째 문장")
        XCTAssertEqual(reopened.rawTranscript, "")
        XCTAssertEqual(reopened.editedTranscript, "")
        XCTAssertEqual(reopened.transcriptRevision, 0)
        XCTAssertFalse(reopened.hasCapturedTranscript)
        XCTAssertEqual(reopened.transcriptionStatus, .failed)
    }

    func testFinalWhisperReplacesAndClearsLiveDraftAtRevisionZero() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        try store.setLiveTranscriptDraft(id: note.id, text: "Provisional words")

        try store.setTranscription(id: note.id, text: "Final local Whisper",
                                   segments: [TranscriptSegment(startTime: 0, text: "Final local Whisper")], words: [])

        let finalized = try XCTUnwrap(store[note.id])
        XCTAssertNil(finalized.liveTranscriptDraft)
        XCTAssertEqual(finalized.rawTranscript, "Final local Whisper")
        XCTAssertEqual(finalized.editedTranscript, "Final local Whisper")
        XCTAssertEqual(finalized.transcriptRevision, 0)
        XCTAssertTrue(finalized.hasCapturedTranscript)
        XCTAssertFalse(try store.setLiveTranscriptDraft(id: note.id, text: "Late callback"))
    }

    func testEmptyFinalWhisperKeepsLiveDraftAsClearlyProvisionalFallback() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        var automaticAIEvents: [UUID] = []
        store.onTranscriptionSaved = { automaticAIEvents.append($0) }
        try store.setLiveTranscriptDraft(id: note.id, text: "기기 내 임시 대본")

        try store.setTranscription(id: note.id, text: "", segments: [], words: [])

        let reopened = try XCTUnwrap(NoteStore(directory: directory)[note.id])
        XCTAssertTrue(reopened.hasCapturedTranscript)
        XCTAssertEqual(reopened.rawTranscript, "")
        XCTAssertEqual(reopened.editedTranscript, "")
        XCTAssertEqual(reopened.liveTranscriptDraft, "기기 내 임시 대본")
        XCTAssertEqual(reopened.displayTranscript, "기기 내 임시 대본")
        XCTAssertThrowsError(try store.beginAIRequest(id: note.id))
        XCTAssertTrue(automaticAIEvents.isEmpty)
    }

    func testUserCanExplicitlyClearAProvisionalLiveDraft() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        try store.setLiveTranscriptDraft(id: note.id, text: "잘못 인식된 임시 대본")

        try store.editTranscript(id: note.id, text: "")

        XCTAssertNil(store[note.id]?.liveTranscriptDraft)
        XCTAssertEqual(store[note.id]?.editedTranscript, "")
        XCTAssertEqual(store[note.id]?.transcriptRevision, 1)
    }

    func testUserCanAdoptAnUnchangedProvisionalLiveDraft() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        try store.setLiveTranscriptDraft(id: note.id, text: "채택할 임시 대본")

        try store.editTranscript(id: note.id, text: "채택할 임시 대본")

        XCTAssertNil(store[note.id]?.liveTranscriptDraft)
        XCTAssertEqual(store[note.id]?.editedTranscript, "채택할 임시 대본")
        XCTAssertEqual(store[note.id]?.transcriptRevision, 1)
    }

    func testUserEditStillWinsWhenFinalWhisperClearsLiveDraft() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        try store.setLiveTranscriptDraft(id: note.id, text: "Live words")
        try store.editTranscript(id: note.id, text: "User correction")

        XCTAssertNil(store[note.id]?.liveTranscriptDraft)
        XCTAssertFalse(try store.setLiveTranscriptDraft(id: note.id, text: "Ignored later partial"))
        try store.setTranscription(id: note.id, text: "Final local Whisper", segments: [], words: [])

        let finalized = try XCTUnwrap(store[note.id])
        XCTAssertNil(finalized.liveTranscriptDraft)
        XCTAssertEqual(finalized.rawTranscript, "Final local Whisper")
        XCTAssertEqual(finalized.editedTranscript, "User correction")
        XCTAssertEqual(finalized.transcriptRevision, 1)
    }

    func testLiveTranscriptDraftCannotStartAIRequest() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        var automaticAIEvents: [UUID] = []
        store.onTranscriptionSaved = { automaticAIEvents.append($0) }
        try store.setLiveTranscriptDraft(id: note.id, text: "Not final STT")

        XCTAssertThrowsError(try store.beginAIRequest(id: note.id)) { error in
            guard let storeError = error as? NoteStoreError else {
                return XCTFail("Expected NoteStoreError.emptyTranscript")
            }
            guard case .emptyTranscript = storeError else {
                return XCTFail("Expected NoteStoreError.emptyTranscript, got \(storeError)")
            }
        }
        XCTAssertEqual(store[note.id]?.aiStatus, .notRequested)
        XCTAssertTrue(automaticAIEvents.isEmpty)
    }

    func testRevisionThreeResponseCannotOverwriteRevisionFourOrPreviousResult() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"),
                        rawTranscript: "Raw original", editedTranscript: "Revision 3", transcriptRevision: 3,
                        aiTitle: "Old title", aiSummary: "Old result", aiTranscriptRevision: 3)
        try store.add(note)
        let request = try store.beginAIRequest(id: note.id)
        try store.editTranscript(id: note.id, text: "Revision 4")
        XCTAssertFalse(try store.completeAIRequest(request, result: result(revision: 3)))
        let current = try XCTUnwrap(store[note.id])
        XCTAssertEqual(current.transcriptRevision, 4)
        XCTAssertEqual(current.editedTranscript, "Revision 4")
        XCTAssertEqual(current.rawTranscript, "Raw original")
        XCTAssertEqual(current.aiSummary, "Old result")
        XCTAssertEqual(current.aiTitle, "Old title")
        XCTAssertTrue(current.isAIResultStale)
    }

    func testFailedRegenerationKeepsResultAndActionCompletionAcrossRelaunch() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let action = ActionItem(text: "Keep completed", completed: true)
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Transcript",
                        aiTitle: "Old title", aiSummary: "Old summary", keyPoints: ["Keep point"],
                        actionItems: [action], aiModel: "old-model", aiTranscriptRevision: 0)
        try store.add(note)
        let request = try store.beginAIRequest(id: note.id)
        try store.failAIRequest(request, message: "Timeout")
        let reopened = try XCTUnwrap(NoteStore(directory: directory)[note.id])
        XCTAssertEqual(reopened.aiSummary, "Old summary")
        XCTAssertEqual(reopened.aiTitle, "Old title")
        XCTAssertEqual(reopened.keyPoints, ["Keep point"])
        XCTAssertEqual(reopened.actionItems, [action])
        XCTAssertEqual(reopened.rawTranscript, "Transcript")
        XCTAssertEqual(reopened.aiStatus, .failed)
    }

    func testDuplicateRequestBlockedAndCancelledTokenCannotApplyToSameRevision() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Transcript")
        try store.add(note)
        let first = try store.beginAIRequest(id: note.id)
        XCTAssertThrowsError(try store.beginAIRequest(id: note.id))
        try store.failAIRequest(first, message: "Cancelled")
        let second = try store.beginAIRequest(id: note.id)
        XCTAssertFalse(try store.completeAIRequest(first, result: result(revision: 0)))
        XCTAssertTrue(try store.completeAIRequest(second, result: result(revision: 0)))
    }

    func testResponseRevisionMismatchIsRejected() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Transcript")
        try store.add(note)
        let request = try store.beginAIRequest(id: note.id)
        XCTAssertThrowsError(try store.completeAIRequest(request, result: result(revision: 99)))
        XCTAssertNil(store[note.id]?.aiSummary)
    }

    func testFilteredDeletionUsesIDAndPreservesUnrelatedAudio() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = Note(audioURL: directory.appendingPathComponent("keep.wav"), transcript: "Keep")
        let remove = Note(audioURL: directory.appendingPathComponent("delete.wav"), transcript: "Search match")
        try Data(repeating: 0, count: 100).write(to: keep.audioURL)
        try Data(repeating: 0, count: 100).write(to: remove.audioURL)
        try store.add(remove)
        try store.add(keep)
        let filtered = store.notes.filter { $0.matchesSearch("Search") }
        try store.delete(id: XCTUnwrap(filtered.first).id)
        XCTAssertNotNil(store[keep.id])
        XCTAssertNil(store[remove.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remove.audioURL.path))
    }

    func testCorruptIndexIsPreservedAndCannotBeOverwrittenByAdd() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("notes.json")
        let corrupt = Data("{bad json".utf8)
        try corrupt.write(to: index)
        let store = NoteStore(directory: directory)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.storageError)
        XCTAssertThrowsError(try store.add(Note(audioURL: directory.appendingPathComponent("new.wav"))))
        XCTAssertEqual(try Data(contentsOf: index), corrupt)
    }

    func testFailedWriteDoesNotCommitAnInMemoryEdit() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Original")
        try store.add(note)
        let index = directory.appendingPathComponent("notes.json")
        let saved = try Data(contentsOf: index)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("notes.backup.json"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.editTranscript(id: note.id, text: "Must not commit"))
        XCTAssertEqual(store[note.id]?.editedTranscript, "Original")
        XCTAssertEqual(try Data(contentsOf: index), saved)
    }

    func testRelaunchRecoversInterruptedStatusesWithoutUploading() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Transcript",
                        aiSummary: "Keep", aiStatus: .processing, aiTranscriptRevision: 0)
        try store.add(note)
        let reloaded = NoteStore(directory: directory)
        XCTAssertEqual(reloaded[note.id]?.aiStatus, .failed)
        XCTAssertEqual(reloaded[note.id]?.aiSummary, "Keep")
        XCTAssertNil(reloaded.onTranscriptionSaved)
    }

    func testOnlySuccessfulNewTranscriptionEmitsAutomaticAIEvent() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var events: [UUID] = []
        store.onTranscriptionSaved = { events.append($0) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"))
        try store.add(note)
        try store.setTranscription(id: note.id, text: "New STT", segments: [], words: [])
        try store.editTranscript(id: note.id, text: "An edit")
        try store.setAIWaiting(id: note.id, message: "Offline")
        XCTAssertEqual(events, [note.id])
    }

    func testLexicalSearchIncludesLocalNotesAndAllAIFields() async throws {
        let note = Note(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"), transcript: "로컬 내용",
                        aiTitle: "Budget", aiSummary: "Resumen español", keyPoints: ["日本語"])
        for query in ["로컬", "budget", "español", "日本語", ""] { XCTAssertTrue(note.matchesSearch(query)) }
        XCTAssertFalse(note.matchesSearch("missing"))
    }

    func testEditedTranscriptDoesNotUploadStaleOriginalSegments() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Original",
                        transcriptSegments: [TranscriptSegment(startTime: 0, text: "Original")])
        try store.add(note)
        try store.editTranscript(id: note.id, text: "Edited")
        XCTAssertTrue(try store.beginAIRequest(id: note.id).segments.isEmpty)
    }

    func testSuccessfulResultAndActionStateRoundTrip() async throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(audioURL: directory.appendingPathComponent("audio.wav"), transcript: "Saved transcript")
        try store.add(note)
        let request = try store.beginAIRequest(id: note.id)
        XCTAssertTrue(try store.completeAIRequest(request, result: result(revision: 0)))
        let action = try XCTUnwrap(store[note.id]?.actionItems.first)
        try store.setActionCompleted(noteID: note.id, actionID: action.id, completed: true)
        let reopened = try XCTUnwrap(NoteStore(directory: directory)[note.id])
        XCTAssertEqual(reopened.aiSummary, "New summary")
        XCTAssertEqual(reopened.aiModel, "test-model")
        XCTAssertEqual(reopened.actionItems.first?.completed, true)
        XCTAssertEqual(reopened.audioURL, note.audioURL)
        XCTAssertEqual(reopened.rawTranscript, "Saved transcript")
    }
}
