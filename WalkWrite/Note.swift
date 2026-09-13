import Foundation

/// Word-level timestamps produced locally by whisper.cpp.
public struct WordStamp: Codable, Hashable, Sendable {
    public let word: String
    public let start: Double
    public let end: Double

    public init(word: String, start: Double, end: Double) {
        self.word = word
        self.start = start
        self.end = end
    }
}

public enum TranscriptionStatus: String, Codable, Hashable, Sendable {
    case notStarted
    case processing
    case completed
    case failed
}

/// Additive JSON model. Raw STT and the user's edited transcript are independent.
public struct Note: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var duration: TimeInterval
    public var audioURL: URL
    public var recordingComplete: Bool

    public private(set) var rawTranscript: String
    public private(set) var editedTranscript: String
    /// Best-effort on-device speech text shown while recording. This is not
    /// final STT and must never be used as AI input or treated as immutable raw text.
    public private(set) var liveTranscriptDraft: String?
    public private(set) var transcriptSegments: [TranscriptSegment]
    public private(set) var transcriptRevision: Int
    public private(set) var words: [WordStamp]
    private var rawTranscriptCaptured: Bool

    public var transcriptionStatus: TranscriptionStatus
    public var transcriptionError: String?

    public var aiTitle: String?
    public var aiSummary: String?
    public var keyPoints: [String]
    public var actionItems: [ActionItem]
    public var aiStatus: AIProcessingStatus
    public var aiModel: String?
    public var aiGeneratedAt: Date?
    public var aiTranscriptRevision: Int?
    public var aiError: String?

    // Legacy results stay available during migration. They never become raw STT.
    public var cleanedTranscript: String?
    public var summary: String?
    public var keyIdeas: [String]?
    public var enhancementFailed: Bool?

    /// Read compatibility for sharing and existing presentation code.
    /// Editing must go through NoteStore.editTranscript so revisions cannot be lost.
    public var transcript: String { editedTranscript }
    public var displayTranscript: String {
        editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (liveTranscriptDraft ?? "")
            : editedTranscript
    }
    public var hasCapturedTranscript: Bool { rawTranscriptCaptured }
    public var hasAIResult: Bool {
        aiTitle != nil || aiSummary != nil || !keyPoints.isEmpty || !actionItems.isEmpty
    }
    public var isAIResultStale: Bool {
        hasAIResult && aiTranscriptRevision != transcriptRevision
    }
    public var displayTitle: String {
        if let title = aiTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let firstLine = displayTranscript.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled Note" : String(firstLine.prefix(80))
    }
    public var searchText: String {
        ([aiTitle ?? "", editedTranscript, liveTranscriptDraft ?? "", aiSummary ?? "", summary ?? ""] + keyPoints + (keyIdeas ?? []))
            .joined(separator: "\n")
    }

    public func matchesSearch(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || searchText.localizedStandardContains(trimmed)
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        audioURL: URL,
        transcript: String = "",
        words: [WordStamp] = [],
        cleanedTranscript: String? = nil,
        summary: String? = nil,
        keyIdeas: [String]? = nil,
        enhancementFailed: Bool? = nil,
        recordingComplete: Bool = true,
        rawTranscript: String? = nil,
        editedTranscript: String? = nil,
        liveTranscriptDraft: String? = nil,
        transcriptSegments: [TranscriptSegment] = [],
        transcriptRevision: Int = 0,
        transcriptionStatus: TranscriptionStatus? = nil,
        transcriptionError: String? = nil,
        updatedAt: Date? = nil,
        aiTitle: String? = nil,
        aiSummary: String? = nil,
        keyPoints: [String] = [],
        actionItems: [ActionItem] = [],
        aiStatus: AIProcessingStatus? = nil,
        aiModel: String? = nil,
        aiGeneratedAt: Date? = nil,
        aiTranscriptRevision: Int? = nil,
        aiError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.duration = duration
        self.audioURL = audioURL
        self.recordingComplete = recordingComplete
        self.rawTranscript = rawTranscript ?? transcript
        self.editedTranscript = editedTranscript ?? rawTranscript ?? transcript
        self.liveTranscriptDraft = nil
        self.transcriptSegments = transcriptSegments
        self.transcriptRevision = max(0, transcriptRevision)
        self.words = words
        self.rawTranscriptCaptured = !(rawTranscript ?? transcript).isEmpty || transcriptionStatus == .completed
        if self.transcriptRevision == 0,
           self.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           self.editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let liveTranscriptDraft,
           !liveTranscriptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.liveTranscriptDraft = liveTranscriptDraft
        }
        self.transcriptionStatus = transcriptionStatus ?? (self.rawTranscriptCaptured ? .completed : .notStarted)
        self.transcriptionError = transcriptionError
        self.cleanedTranscript = cleanedTranscript
        self.summary = summary
        self.keyIdeas = keyIdeas
        self.enhancementFailed = enhancementFailed
        self.aiTitle = aiTitle
        self.aiSummary = aiSummary ?? summary
        self.keyPoints = keyPoints.isEmpty ? (keyIdeas ?? []) : keyPoints
        self.actionItems = actionItems
        let legacyResult = aiSummary == nil && (summary != nil || !(keyIdeas ?? []).isEmpty)
        let anyResult = aiTitle != nil || self.aiSummary != nil || !self.keyPoints.isEmpty || !actionItems.isEmpty
        self.aiStatus = aiStatus ?? (enhancementFailed == true ? .failed : (anyResult ? .completed : .notRequested))
        self.aiModel = aiModel ?? (legacyResult ? "legacy-local-llm" : nil)
        self.aiGeneratedAt = aiGeneratedAt
        self.aiTranscriptRevision = aiTranscriptRevision ?? (legacyResult ? 0 : nil)
        self.aiError = aiError
    }

    /// Accept exactly one successful STT result, including a successful empty result.
    /// A draft edited while STT was running is not replaced by the late result.
    @discardableResult
    mutating func captureTranscription(text: String, segments: [TranscriptSegment], words: [WordStamp]) -> Bool {
        guard !rawTranscriptCaptured else { return false }
        rawTranscript = text
        rawTranscriptCaptured = true
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            liveTranscriptDraft = nil
        }
        transcriptSegments = segments
        self.words = words
        if transcriptRevision == 0 {
            editedTranscript = text
        }
        transcriptionStatus = .completed
        transcriptionError = nil
        return true
    }

    /// Persist provisional on-device recognition without promoting it to raw STT
    /// or advancing the user-edit revision. Empty callbacks cannot erase useful text.
    @discardableResult
    mutating func applyLiveTranscriptDraft(_ text: String) -> Bool {
        guard !rawTranscriptCaptured, transcriptRevision == 0 else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text != liveTranscriptDraft else { return false }
        liveTranscriptDraft = text
        return true
    }

    @discardableResult
    mutating func applyTranscriptEdit(_ text: String) throws -> Bool {
        guard text != editedTranscript || liveTranscriptDraft != nil else { return false }
        guard transcriptRevision < Int.max else { throw NoteStoreError.revisionExhausted }
        editedTranscript = text
        liveTranscriptDraft = nil
        transcriptRevision += 1
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, duration, audioURL, audioFilename, recordingComplete
        case transcript, words, rawTranscript, editedTranscript, liveTranscriptDraft, transcriptSegments, transcriptRevision, rawTranscriptCaptured
        case transcriptionStatus, transcriptionError
        case aiTitle, aiSummary, keyPoints, actionItems, aiStatus, aiModel, aiGeneratedAt, aiTranscriptRevision, aiError
        case cleanedTranscript, summary, keyIdeas, enhancementFailed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        recordingComplete = try values.decodeIfPresent(Bool.self, forKey: .recordingComplete) ?? true
        let storageDirectory = (decoder.userInfo[.noteStorageDirectory] as? URL) ?? AppFolders.notes
        if let filename = try values.decodeIfPresent(String.self, forKey: .audioFilename) {
            guard AppFolders.isSafeAudioFilename(filename) else {
                throw DecodingError.dataCorruptedError(forKey: .audioFilename, in: values, debugDescription: "Invalid managed audio filename.")
            }
            audioURL = storageDirectory.appendingPathComponent(filename)
        } else {
            let storedURL = try values.decode(URL.self, forKey: .audioURL)
            // Historic iOS container IDs change after restore/reinstallation.
            // Only legacy Notes-folder paths are remapped; arbitrary external files are not.
            if storedURL.isFileURL,
               AppFolders.isSafeAudioFilename(storedURL.lastPathComponent),
               storedURL.deletingLastPathComponent().lastPathComponent == "Notes" {
                audioURL = storageDirectory.appendingPathComponent(storedURL.lastPathComponent)
            } else {
                audioURL = storedURL
            }
        }
        let legacyTranscript = try values.decodeIfPresent(String.self, forKey: .transcript)
        rawTranscript = try values.decodeIfPresent(String.self, forKey: .rawTranscript) ?? legacyTranscript ?? ""
        editedTranscript = try values.decodeIfPresent(String.self, forKey: .editedTranscript) ?? legacyTranscript ?? rawTranscript
        liveTranscriptDraft = try values.decodeIfPresent(String.self, forKey: .liveTranscriptDraft)
        transcriptRevision = try values.decodeIfPresent(Int.self, forKey: .transcriptRevision) ?? 0
        guard transcriptRevision >= 0, duration.isFinite, duration >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .transcriptRevision, in: values, debugDescription: "Invalid note revision or duration.")
        }
        words = try values.decodeIfPresent([WordStamp].self, forKey: .words) ?? []
        transcriptSegments = try values.decodeIfPresent([TranscriptSegment].self, forKey: .transcriptSegments)
            ?? words.map { TranscriptSegment(startTime: $0.start, endTime: $0.end, text: $0.word) }
        let savedSTTStatus = try values.decodeIfPresent(TranscriptionStatus.self, forKey: .transcriptionStatus)
        rawTranscriptCaptured = try values.decodeIfPresent(Bool.self, forKey: .rawTranscriptCaptured)
            ?? (!rawTranscript.isEmpty || savedSTTStatus == .completed)
        if (rawTranscriptCaptured && !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
            !editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            transcriptRevision != 0 ||
            liveTranscriptDraft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            liveTranscriptDraft = nil
        }
        transcriptionStatus = savedSTTStatus ?? (rawTranscriptCaptured ? .completed : .notStarted)
        transcriptionError = try values.decodeIfPresent(String.self, forKey: .transcriptionError)
        cleanedTranscript = try values.decodeIfPresent(String.self, forKey: .cleanedTranscript)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        keyIdeas = try values.decodeIfPresent([String].self, forKey: .keyIdeas)
        enhancementFailed = try values.decodeIfPresent(Bool.self, forKey: .enhancementFailed)
        aiTitle = try values.decodeIfPresent(String.self, forKey: .aiTitle)
        let savedAISummary = try values.decodeIfPresent(String.self, forKey: .aiSummary)
        aiSummary = savedAISummary ?? summary
        keyPoints = try values.decodeIfPresent([String].self, forKey: .keyPoints) ?? keyIdeas ?? []
        actionItems = try values.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        let legacyResult = savedAISummary == nil && (summary != nil || !(keyIdeas ?? []).isEmpty)
        let anyResult = aiTitle != nil || aiSummary != nil || !keyPoints.isEmpty || !actionItems.isEmpty
        aiStatus = try values.decodeIfPresent(AIProcessingStatus.self, forKey: .aiStatus)
            ?? (enhancementFailed == true ? .failed : (anyResult ? .completed : .notRequested))
        aiModel = try values.decodeIfPresent(String.self, forKey: .aiModel) ?? (legacyResult ? "legacy-local-llm" : nil)
        aiGeneratedAt = try values.decodeIfPresent(Date.self, forKey: .aiGeneratedAt)
        aiTranscriptRevision = try values.decodeIfPresent(Int.self, forKey: .aiTranscriptRevision) ?? (legacyResult ? 0 : nil)
        aiError = try values.decodeIfPresent(String.self, forKey: .aiError)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(duration, forKey: .duration)
        try values.encode(audioURL, forKey: .audioURL)
        let storageDirectory = (encoder.userInfo[.noteStorageDirectory] as? URL) ?? AppFolders.notes
        if AppFolders.isManagedAudio(audioURL, in: storageDirectory) {
            try values.encode(audioURL.lastPathComponent, forKey: .audioFilename)
        }
        try values.encode(recordingComplete, forKey: .recordingComplete)
        try values.encode(editedTranscript, forKey: .transcript)
        try values.encode(rawTranscript, forKey: .rawTranscript)
        try values.encode(editedTranscript, forKey: .editedTranscript)
        try values.encodeIfPresent(liveTranscriptDraft, forKey: .liveTranscriptDraft)
        try values.encode(transcriptSegments, forKey: .transcriptSegments)
        try values.encode(transcriptRevision, forKey: .transcriptRevision)
        try values.encode(rawTranscriptCaptured, forKey: .rawTranscriptCaptured)
        try values.encode(words, forKey: .words)
        try values.encode(transcriptionStatus, forKey: .transcriptionStatus)
        try values.encodeIfPresent(transcriptionError, forKey: .transcriptionError)
        try values.encodeIfPresent(aiTitle, forKey: .aiTitle)
        try values.encodeIfPresent(aiSummary, forKey: .aiSummary)
        try values.encode(keyPoints, forKey: .keyPoints)
        try values.encode(actionItems, forKey: .actionItems)
        try values.encode(aiStatus, forKey: .aiStatus)
        try values.encodeIfPresent(aiModel, forKey: .aiModel)
        try values.encodeIfPresent(aiGeneratedAt, forKey: .aiGeneratedAt)
        try values.encodeIfPresent(aiTranscriptRevision, forKey: .aiTranscriptRevision)
        try values.encodeIfPresent(aiError, forKey: .aiError)
        try values.encodeIfPresent(cleanedTranscript, forKey: .cleanedTranscript)
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encodeIfPresent(keyIdeas, forKey: .keyIdeas)
        try values.encodeIfPresent(enhancementFailed, forKey: .enhancementFailed)
    }

    static var indexFile: URL {
        AppFolders.notes.appendingPathComponent("notes.json")
    }
}
