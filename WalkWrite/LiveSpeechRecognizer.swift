import AVFoundation
import Speech

enum LiveSpeechStartResult: Equatable {
    case started(localeIdentifier: String)
    case unavailable(message: String)
}

enum LiveSpeechLocale {
    static func identifier(
        for language: WhisperLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch language {
        case .ko: return "ko-KR"
        case .en: return "en-US"
        case .ja: return "ja-JP"
        case .es: return "es-ES"
        case .automatic:
            return preferredLanguages.first ?? Locale.current.identifier
        }
    }
}

/// Optional, on-device-only live text. This object never owns the microphone;
/// it consumes the exact buffers already accepted by AudioCaptureEngine.
final class LiveSpeechRecognizer: @unchecked Sendable {
    private let input = LockedSpeechInput()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var committedTranscript = ""
    private var currentTranscript = ""
    private var active = false
    private var paused = false
    private var onUpdate: (@MainActor (String) -> Void)?
    private var onFailure: (@MainActor (String) -> Void)?

    deinit {
        input.detach(endingAudio: true)
        recognitionTask?.cancel()
    }

    @MainActor
    func start(
        language: WhisperLanguage,
        initialTranscript: String = "",
        onUpdate: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) async -> LiveSpeechStartResult {
        precondition(Thread.isMainThread)
        stop()
        self.onUpdate = onUpdate
        self.onFailure = onFailure

        let authorization = await Self.authorizationStatus()
        guard !Task.isCancelled else {
            return .unavailable(message: "Live transcription was cancelled. Recording continues normally.")
        }
        guard authorization == .authorized else {
            return .unavailable(message: Self.authorizationMessage(authorization))
        }

        let identifier = LiveSpeechLocale.identifier(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            return .unavailable(message:
                "On-device live transcription is unavailable for \(identifier). Audio is still recording and local Whisper will run after Stop.")
        }

        self.recognizer = recognizer
        committedTranscript = initialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        currentTranscript = ""
        active = true
        paused = false
        beginRequest()
        return .started(localeIdentifier: identifier)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.append(buffer)
    }

    @MainActor
    @discardableResult
    func pause() -> String {
        precondition(Thread.isMainThread)
        guard active, !paused else { return combinedTranscript }
        paused = true
        commitCurrentTranscript()
        invalidateRequest(endingAudio: true)
        return committedTranscript
    }

    @MainActor
    func resume() {
        precondition(Thread.isMainThread)
        guard active, paused, recognizer != nil else { return }
        paused = false
        beginRequest()
    }

    /// Legacy SFSpeechRecognizer tasks can end around the one-minute mark.
    /// Rotate while the audio engine keeps recording; final Whisper removes any
    /// tiny boundary uncertainty from the stored transcript.
    @MainActor
    func rollover() {
        precondition(Thread.isMainThread)
        guard active, !paused, recognizer != nil else { return }
        commitCurrentTranscript()
        invalidateRequest(endingAudio: true)
        beginRequest()
    }

    @discardableResult
    @MainActor
    func stop() -> String {
        precondition(Thread.isMainThread)
        commitCurrentTranscript()
        active = false
        paused = false
        invalidateRequest(endingAudio: true)
        recognizer = nil
        let transcript = committedTranscript
        onUpdate = nil
        onFailure = nil
        return transcript
    }

    @MainActor
    private func beginRequest() {
        precondition(Thread.isMainThread)
        guard active, !paused, let recognizer else { return }
        invalidateRequest(endingAudio: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) { request.addsPunctuation = true }

        let requestGeneration = UUID()
        generation = requestGeneration
        input.replace(with: request)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.receive(text: text, isFinal: isFinal, errorMessage: errorMessage,
                              generation: requestGeneration)
            }
        }
    }

    @MainActor
    private func receive(text: String?, isFinal: Bool, errorMessage: String?, generation: UUID) {
        precondition(Thread.isMainThread)
        guard generation == self.generation else { return }
        if let text {
            currentTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            onUpdate?(combinedTranscript)
        }
        if isFinal {
            commitCurrentTranscript()
            invalidateRequest(endingAudio: false)
            if active, !paused { beginRequest() }
            return
        }
        if errorMessage != nil, active, !paused {
            // Live recognition is best-effort. Do not repeatedly restart an
            // unavailable recognizer or let it affect authoritative recording.
            active = false
            invalidateRequest(endingAudio: false)
            onFailure?("On-device live transcription stopped. Audio is still recording and local Whisper will run after Stop.")
        }
    }

    @MainActor
    private var combinedTranscript: String {
        Self.join(committedTranscript, currentTranscript)
    }

    @MainActor
    private func commitCurrentTranscript() {
        let trimmed = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { committedTranscript = Self.join(committedTranscript, trimmed) }
        currentTranscript = ""
        if !committedTranscript.isEmpty { onUpdate?(committedTranscript) }
    }

    @MainActor
    private func invalidateRequest(endingAudio: Bool) {
        generation = UUID()
        input.detach(endingAudio: endingAudio)
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private static func join(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        return prefix + (prefix.last?.isWhitespace == true ? "" : " ") + suffix
    }

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func authorizationMessage(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "Speech Recognition permission is off. Audio is still recording; enable it in iOS Settings for live text."
        case .restricted:
            return "Speech Recognition is restricted on this device. Audio is still recording and local Whisper will run after Stop."
        case .notDetermined:
            return "Speech Recognition permission was not completed. Audio is still recording and local Whisper will run after Stop."
        case .authorized:
            return ""
        @unknown default:
            return "Live transcription is unavailable. Audio is still recording and local Whisper will run after Stop."
        }
    }
}

private final class LockedSpeechInput: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func replace(with request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }

    /// Detach first so a concurrently arriving audio buffer can never append to
    /// a request after endAudio has been sent.
    func detach(endingAudio: Bool) {
        lock.lock()
        let detached = request
        request = nil
        lock.unlock()
        if endingAudio { detached?.endAudio() }
    }
}
