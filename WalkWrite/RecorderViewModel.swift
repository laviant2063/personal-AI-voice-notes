import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
final class RecorderViewModel: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var isProcessing = false
    @Published private(set) var finishedNote: Note?
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var transcriptionProgress: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var liveTranscript = ""
    @Published private(set) var liveSpeechMessage: String?
    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var transcribingNoteID: UUID?
    @Published var transcriptionLanguage: WhisperLanguage = .automatic

    private weak var store: NoteStore?
    private var captureEngine: AudioCaptureEngine?
    private let liveSpeechRecognizer = LiveSpeechRecognizer()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var transcriptionTask: Task<Void, Never>?
    private var liveSpeechTask: Task<Void, Never>?
    private var liveSpeechStartGeneration = UUID()
    private var lastLiveDraftCheckpoint: TimeInterval = 0
    private var lastLiveSpeechRollover: TimeInterval = 0
    private var lastSavedLiveDraft = ""
    private var lastObservedCaptureDuration: TimeInterval = 0
    private var lastCaptureProgressAt = Date()

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    self.pauseRecording()
                    if self.isRecording { self.errorMessage = "Recording was interrupted and paused. Resume when ready." }
                } else if self.isRecording && self.isPaused {
                    self.errorMessage = "The interruption ended. Tap Resume to continue this recording."
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory else { return }
                self.pauseRecording()
                if self.isRecording { self.errorMessage = "The audio route changed. Recording is paused; check the microphone and resume." }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.finishRecording(transcribe: false,
                    warning: "Audio services restarted. The available recording was saved; listen before retrying.")
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Existing background recording remains enabled. Heavy STT is
                // foreground-only and is always retryable from preserved audio.
                self?.suspendLiveSpeechForBackground()
                self?.cancelTranscription()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeLiveSpeechAfterBackground() }
        })
    }

    deinit {
        timer?.invalidate()
        captureEngine?.stop()
        liveSpeechTask?.cancel()
        transcriptionTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attachStore(_ store: NoteStore) { self.store = store }
    func clearError() { errorMessage = nil }

    @discardableResult
    func ensurePermission() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        permissionDenied = !granted
        return granted
    }

    func startRecording() {
        guard !isRecording, !isProcessing, !isPreparingModel else { return }
        guard let store, !store.isReadOnly else {
            errorMessage = NoteStoreError.readOnly.localizedDescription
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            permissionDenied = true
            errorMessage = "Microphone access is required. Enable it in iOS Settings."
            return
        }
        guard WhisperStateManager.shared.canAcceptNewJob() else {
            errorMessage = "Wait for local transcription to finish before starting another recording."
            return
        }
        finishedNote = nil
        errorMessage = nil
        liveTranscript = ""
        liveSpeechMessage = nil
        elapsed = 0
        lastLiveDraftCheckpoint = 0
        lastLiveSpeechRollover = 0
        lastSavedLiveDraft = ""
        lastObservedCaptureDuration = 0
        lastCaptureProgressAt = .now
        let id = UUID()
        var noteWasAdded = false
        do {
            let directory = try AppFolders.ensureNotesDirectory()
            let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("wav")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            // These are preferences, not assumptions. The authoritative file
            // uses the actual hardware format and Whisper resamples after Stop.
            try? session.setPreferredSampleRate(16_000)
            try? session.setPreferredInputNumberOfChannels(1)
            try session.setActive(true)
            // Metadata exists BEFORE the microphone starts writing user audio.
            try store.add(Note(id: id, audioURL: url, recordingComplete: false))
            noteWasAdded = true
            activeNoteID = id

            let capture = AudioCaptureEngine()
            let liveSpeech = liveSpeechRecognizer
            try capture.start(
                writingTo: url,
                onBuffer: { buffer in liveSpeech.append(buffer) },
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.isRecording, !self.isPaused else { return }
                        self.audioLevel = level
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor in
                        self?.finishRecording(transcribe: false, warning: message)
                    }
                }
            )
            captureEngine = capture
            isRecording = true
            isPaused = false
            lastCaptureProgressAt = .now
            startTimer()
            startLiveSpeechRecognition()
        } catch {
            captureEngine?.stop()
            captureEngine = nil
            isRecording = false
            isPaused = false
            activeNoteID = nil
            errorMessage = error.localizedDescription
            if noteWasAdded {
                try? store.updateRecording(id: id, duration: 0, completed: true)
                try? store.setTranscriptionStatus(
                    id: id, status: .failed, error: RecordingError.startFailed.localizedDescription)
                finishedNote = store[id]
            }
            deactivateSession()
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused, let captureEngine else { return }
        elapsed = max(elapsed, captureEngine.duration)
        captureEngine.pause()
        let pausedTranscript = liveSpeechRecognizer.pause()
        if !pausedTranscript.isEmpty { liveTranscript = pausedTranscript }
        isPaused = true
        audioLevel = 0
        timer?.invalidate()
        checkpointLiveTranscript(force: true)
        checkpoint()
    }

    func resumeRecording() {
        guard isRecording, isPaused, let captureEngine else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try captureEngine.resume()
            liveSpeechRecognizer.resume()
            isPaused = false
            errorMessage = nil
            lastObservedCaptureDuration = captureEngine.duration
            lastCaptureProgressAt = .now
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
            // Remain paused. Stopping still preserves this same file.
        }
    }

    func stopRecording() { finishRecording(transcribe: true, warning: nil) }

    private func finishRecording(transcribe: Bool, warning: String?) {
        guard isRecording, let captureEngine else { return }
        let noteID = activeNoteID
        self.captureEngine = nil
        let capturedDuration = captureEngine.stop()
        let duration = max(elapsed, capturedDuration)
        liveSpeechStartGeneration = UUID()
        liveSpeechTask?.cancel()
        liveSpeechTask = nil
        let finalLiveTranscript = liveSpeechRecognizer.stop()
        if !finalLiveTranscript.isEmpty { liveTranscript = finalLiveTranscript }
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        audioLevel = 0
        elapsed = duration
        activeNoteID = nil
        deactivateSession()
        guard let noteID, let store else { return }
        do {
            checkpointLiveTranscript(noteID: noteID, force: true)
            try store.updateRecording(id: noteID, duration: duration, completed: true)
            if let warning {
                errorMessage = warning
                try store.setTranscriptionStatus(id: noteID, status: .failed, error: warning)
            }
        } catch {
            errorMessage = error.localizedDescription
            finishedNote = store[noteID]
            return
        }
        if transcribe {
            isPreparingModel = true
            Task { await self.transcribe(noteID: noteID) }
        } else {
            finishedNote = store[noteID]
        }
    }

    func transcribe(noteID: UUID) async {
        guard !isRecording, !isProcessing, let store, let note = store[noteID] else { return }
        isPreparingModel = false
        guard !note.hasCapturedTranscript else {
            errorMessage = NoteStoreError.transcriptAlreadyCaptured.localizedDescription
            return
        }
        guard WhisperStateManager.shared.canAcceptNewJob() else {
            errorMessage = WhisperError.busy.localizedDescription
            return
        }
        do { try store.setTranscriptionStatus(id: noteID, status: .processing) }
        catch { errorMessage = error.localizedDescription; return }
        isProcessing = true
        isPreparingModel = true
        transcribingNoteID = noteID
        transcriptionProgress = 0
        errorMessage = nil
        let language = transcriptionLanguage
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await WhisperEngine.shared.transcribe(
                    audioFileURL: note.audioURL, language: language) { [weak self] progress in
                        Task { @MainActor in
                            self?.isPreparingModel = false
                            self?.transcriptionProgress = progress
                        }
                    }
                try Task.checkCancellation()
                try store.setTranscription(id: noteID, text: result.text,
                                           segments: result.segments, words: result.words)
            } catch {
                let message = (error is CancellationError || Task.isCancelled)
                    ? "Local transcription was cancelled. Audio is preserved; retry from the note when ready."
                    : error.localizedDescription
                self.errorMessage = message
                do { try store.setTranscriptionStatus(id: noteID, status: .failed, error: message) }
                catch { self.errorMessage = error.localizedDescription }
            }
        }
        transcriptionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        transcriptionTask = nil
        isProcessing = false
        isPreparingModel = false
        transcribingNoteID = nil
        finishedNote = store[noteID]
    }

    func cancelTranscription() { transcriptionTask?.cancel() }

    func changeTranscriptionLanguage(_ language: WhisperLanguage) {
        guard transcriptionLanguage != language else { return }
        transcriptionLanguage = language
        guard isRecording else { return }
        liveSpeechStartGeneration = UUID()
        liveSpeechTask?.cancel()
        let previousTranscript = liveSpeechRecognizer.stop()
        if !previousTranscript.isEmpty { liveTranscript = previousTranscript }
        liveSpeechMessage = nil
        startLiveSpeechRecognition()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isRecording, !isPaused, let captureEngine else { return }
        if !captureEngine.isRunning {
            pauseRecording()
            errorMessage = "Recording stopped receiving audio and was paused. Resume or Stop to preserve the file."
            return
        }
        let captureDuration = captureEngine.duration
        elapsed = max(elapsed, captureDuration)
        if captureDuration > lastObservedCaptureDuration {
            lastObservedCaptureDuration = captureDuration
            lastCaptureProgressAt = .now
        } else if Date().timeIntervalSince(lastCaptureProgressAt) > 2 {
            pauseRecording()
            errorMessage = "The microphone stopped delivering audio. Recording is paused; Stop now to preserve the available file."
            return
        }
        if elapsed - lastLiveDraftCheckpoint >= 5 {
            checkpointLiveTranscript(force: false)
            lastLiveDraftCheckpoint = elapsed
        }
        if elapsed - lastLiveSpeechRollover >= 50 {
            liveSpeechRecognizer.rollover()
            lastLiveSpeechRollover = elapsed
        }
    }

    private func startLiveSpeechRecognition() {
        liveSpeechTask?.cancel()
        let startGeneration = UUID()
        liveSpeechStartGeneration = startGeneration
        liveSpeechMessage = "기기 내 실시간 음성 인식을 준비하고 있습니다…"
        let language = transcriptionLanguage
        liveSpeechTask = Task { [weak self] in
            guard let self else { return }
            let result = await liveSpeechRecognizer.start(
                language: language,
                initialTranscript: liveTranscript,
                onUpdate: { [weak self] text in
                    guard let self, self.isRecording,
                          self.liveSpeechStartGeneration == startGeneration else { return }
                    self.liveTranscript = text
                    self.liveSpeechMessage = nil
                },
                onFailure: { [weak self] message in
                    guard let self, self.isRecording,
                          self.liveSpeechStartGeneration == startGeneration else { return }
                    self.liveSpeechMessage = message
                }
            )
            // A cancelled permission request may return after a newer language
            // or foreground start has succeeded. It must never stop that newer
            // shared recognizer instance.
            guard !Task.isCancelled, liveSpeechStartGeneration == startGeneration,
                  isRecording, transcriptionLanguage == language else { return }
            switch result {
            case .started(let localeIdentifier):
                liveSpeechMessage = language == .automatic
                    ? "실시간 인식 언어: \(localeIdentifier) · 최종 Whisper는 자동 감지"
                    : nil
                lastLiveSpeechRollover = elapsed
            case .unavailable(let message):
                liveSpeechMessage = message
            }
        }
    }

    private func suspendLiveSpeechForBackground() {
        guard isRecording else { return }
        liveSpeechStartGeneration = UUID()
        liveSpeechTask?.cancel()
        liveSpeechTask = nil
        let transcript = liveSpeechRecognizer.stop()
        if !transcript.isEmpty { liveTranscript = transcript }
        checkpointLiveTranscript(force: true)
        liveSpeechMessage = "백그라운드에서는 실시간 받아쓰기가 일시 중단됩니다. 오디오 녹음은 계속됩니다."
    }

    private func resumeLiveSpeechAfterBackground() {
        guard isRecording, !isPaused, liveSpeechTask == nil else { return }
        startLiveSpeechRecognition()
    }

    private func checkpointLiveTranscript(force: Bool) {
        guard let noteID = activeNoteID else { return }
        checkpointLiveTranscript(noteID: noteID, force: force)
    }

    private func checkpointLiveTranscript(noteID: UUID, force: Bool) {
        let draft = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, (force || draft != lastSavedLiveDraft) else { return }
        do {
            try store?.setLiveTranscriptDraft(id: noteID, text: draft)
            lastSavedLiveDraft = draft
        } catch {
            if errorMessage == nil { errorMessage = error.localizedDescription }
        }
    }

    private func checkpoint() {
        guard let id = activeNoteID else { return }
        do { try store?.updateRecording(id: id, duration: elapsed, completed: false) }
        catch { errorMessage = error.localizedDescription }
    }

    private func deactivateSession() {
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { if errorMessage == nil { errorMessage = "Audio was saved, but the audio session could not be released normally." } }
    }
}

private enum RecordingError: LocalizedError {
    case startFailed, resumeFailed
    var errorDescription: String? {
        switch self {
        case .startFailed: return "Recording could not start. Check the microphone and available device storage."
        case .resumeFailed: return "Recording could not resume. It is still paused; Stop will save the available audio."
        }
    }
}
