import Foundation

public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval?
    public let text: String

    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval? = nil, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct GeneratedActionItem: Codable, Hashable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ActionItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var completed: Bool

    public init(id: UUID = UUID(), text: String, completed: Bool = false) {
        self.id = id
        self.text = text
        self.completed = completed
    }
}

public enum AIProcessingStatus: String, Codable, Hashable, Sendable {
    case notRequested
    case waitingForInternet
    case processing
    case completed
    case failed
}

/// A complete backend response. Production code never substitutes a mock value.
public struct AISummaryResult: Codable, Hashable, Sendable {
    public let transcriptRevision: Int
    public let title: String
    public let summary: String
    public let keyPoints: [String]
    public let actionItems: [GeneratedActionItem]
    public let model: String?
    public let generatedAt: Date?
    public let requestId: String?

    public init(
        transcriptRevision: Int,
        title: String,
        summary: String,
        keyPoints: [String],
        actionItems: [GeneratedActionItem],
        model: String? = nil,
        generatedAt: Date? = nil,
        requestId: String? = nil
    ) {
        self.transcriptRevision = transcriptRevision
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.model = model
        self.generatedAt = generatedAt
        self.requestId = requestId
    }
}

/// Immutable snapshot and cancellation token for one logical AI operation.
public struct AIRequestContext: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let noteID: UUID
    public let revision: Int
    public let transcript: String
    public let segments: [TranscriptSegment]

    public init(
        requestID: UUID = UUID(),
        noteID: UUID,
        revision: Int,
        transcript: String,
        segments: [TranscriptSegment]
    ) {
        self.requestID = requestID
        self.noteID = noteID
        self.revision = revision
        self.transcript = transcript
        self.segments = segments
    }
}
