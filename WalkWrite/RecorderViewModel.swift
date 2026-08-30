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
    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var transcribingNoteID: UUID?
    @Published var transcriptionLanguage: WhisperLanguage = .automatic

    private weak var store: NoteStore?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var transcriptionTask: Task<Void, Never>?

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
                self?.cancelTranscription()
            }
        })
    }

    deinit {
        timer?.invalidate()
        recorder?.stop()
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
        elapsed = 0
        let id = UUID()
        do {
            let directory = try AppFolders.ensureNotesDirectory()
            let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("wav")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.prepareToRecord() else { throw RecordingError.startFailed }
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            } catch {
                // The app container still has platform-default protection.
                // A best-effort attribute must never prevent audio capture.
                errorMessage = "Recording started, but the preferred file-protection attribute was unavailable."
            }
            // Metadata exists BEFORE the microphone starts writing user audio.
            try store.add(Note(id: id, audioURL: url, recordingComplete: false))
            activeNoteID = id
            self.recorder = recorder
            guard recorder.record() else {
                try store.updateRecording(id: id, duration: 0, completed: true)
                try store.setTranscriptionStatus(id: id, status: .failed, error: RecordingError.startFailed.localizedDescription)
                throw RecordingError.startFailed
            }
            isRecording = true
            isPaused = false
            startTimer()
        } catch {
            recorder?.delegate = nil
            recorder?.stop()
            recorder = nil
            isRecording = false
            isPaused = false
            activeNoteID = nil
            errorMessage = error.localizedDescription
            deactivateSession()
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused, let recorder else { return }
        elapsed = max(elapsed, recorder.currentTime)
        recorder.pause()
        isPaused = true
        audioLevel = 0
        timer?.invalidate()
        checkpoint()
    }

    func resumeRecording() {
        guard isRecording, isPaused, let recorder else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard recorder.record() else { throw RecordingError.resumeFailed }
            isPaused = false
            errorMessage = nil
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
            // Remain paused. Stopping still preserves this same file.
        }
    }

    func stopRecording() { finishRecording(transcribe: true, warning: nil) }

    private func finishRecording(transcribe: Bool, warning: String?) {
        guard isRecording, let recorder else { return }
        let duration = max(elapsed, recorder.currentTime)
        let noteID = activeNoteID
        self.recorder = nil
        recorder.delegate = nil
        recorder.stop()
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

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isRecording, !isPaused, let recorder else { return }
        if !recorder.isRecording {
            pauseRecording()
            errorMessage = "Recording stopped receiving audio and was paused. Resume or Stop to preserve the file."
            return
        }
        elapsed = max(elapsed, recorder.currentTime)
        recorder.updateMeters()
        audioLevel = max(0, min(1, pow(10, recorder.averagePower(forChannel: 0) / 20)))
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

extension RecorderViewModel: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            self.finishRecording(transcribe: false,
                warning: flag ? "Recording ended. The audio was saved; you can transcribe it from the note."
                    : "Recording ended unexpectedly. The available audio was saved; listen before retrying.")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            self.finishRecording(transcribe: false,
                warning: "An audio encoding error occurred. The available file was preserved.")
        }
    }
}
