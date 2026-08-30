import Foundation
import Combine

/// UI state only. WhisperEngine owns the synchronous admission gate and its context.
@MainActor
public final class WhisperStateManager: ObservableObject {
    public static let shared = WhisperStateManager()

    @Published public private(set) var isTranscribing = false
    @Published public private(set) var isReleasingContext = false
    private var activeJobID: UUID?

    private init() {}

    func beginJob(_ id: UUID) {
        activeJobID = id
        isTranscribing = true
    }

    func finishJob(_ id: UUID) {
        guard activeJobID == id else { return }
        activeJobID = nil
        isTranscribing = false
        isReleasingContext = false
    }

    public func canAcceptNewJob() -> Bool {
        !isTranscribing && !isReleasingContext
    }
}
