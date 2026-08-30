import Foundation
import AVFoundation
#if canImport(whisper)
import whisper
#endif

public enum WhisperError: Error, LocalizedError {
    case runtimeMissing, modelLoadFailed, audioFileReadFailed, audioFormatError
    case encodeFailed(status: Int32), busy, emptyAudio

    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The whisper.cpp runtime is not linked. Build the XCFramework on macOS and rebuild the app. Audio is preserved."
        case .modelLoadFailed: return "Whisper could not load this model. The file may be incomplete or too large for the device. Audio is preserved."
        case .audioFileReadFailed: return "The saved audio could not be read. The original file has not been changed."
        case .audioFormatError: return "Local STT expects the app's 16 kHz mono audio. The original audio is preserved."
        case .encodeFailed(let status): return "Local transcription failed (code \(status)). Audio is preserved; retry when ready."
        case .busy: return "Another local transcription is already running."
        case .emptyAudio: return "No audio samples were found. The audio file has been preserved."
        }
    }
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let segments: [TranscriptSegment]
    public let words: [WordStamp]
}

/// C inference may block an actor executor. Cancellation must be readable from
/// its C abort callback without waiting for another actor turn.
private final class WhisperCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// All pointer ownership and native inference are serialized by one actor.
/// No model is initialized at app launch or while starting a recording.
public actor WhisperEngine {
    public static let shared = WhisperEngine()
    private var isBusy = false

    public static var isAvailable: Bool {
        #if canImport(whisper)
        return true
        #else
        return false
        #endif
    }

    public func transcribe(
        audioFileURL: URL, language: WhisperLanguage = .automatic,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        guard !isBusy else { throw WhisperError.busy }
        isBusy = true
        let jobID = UUID()
        await WhisperStateManager.shared.beginJob(jobID)
        let cancellation = WhisperCancellationFlag()
        do {
            try Task.checkCancellation()
            let modelURL = await MainActor.run { () -> URL? in
                let manager = WhisperModelManager.shared
                guard !manager.isInstalling else { return nil }
                manager.refresh()
                return manager.installedModelURL
            }
            guard let modelURL else { throw WhisperModelError.missing }
            let result = try await withTaskCancellationHandler {
                try run(audioURL: audioFileURL, modelURL: modelURL, language: language,
                        cancellation: cancellation, progress: progressHandler)
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            await WhisperStateManager.shared.finishJob(jobID)
            isBusy = false
            return result
        } catch {
            await WhisperStateManager.shared.finishJob(jobID)
            isBusy = false
            throw error
        }
    }

    private func run(
        audioURL: URL, modelURL: URL, language: WhisperLanguage,
        cancellation: WhisperCancellationFlag, progress: @Sendable (Double) -> Void
    ) throws -> TranscriptionResult {
        #if canImport(whisper)
        try WhisperModelValidator.validate(at: modelURL)
        var contextParameters = whisper_context_default_params()
        #if targetEnvironment(simulator)
        contextParameters.use_gpu = false
        #endif
        guard let context = modelURL.path.withCString({
            whisper_init_from_file_with_params($0, contextParameters)
        }) else { throw WhisperError.modelLoadFailed }
        // Context is freed synchronously, before the admission gate opens again.
        defer { whisper_free(context) }
        if cancellation.isCancelled() { throw CancellationError() }

        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw WhisperError.audioFileReadFailed }
        let format = audio.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1 else {
            throw WhisperError.audioFormatError
        }
        guard audio.length > 0 else { throw WhisperError.emptyAudio }
        let chunkFrames: AVAudioFrameCount = 30 * 16_000
        var segments: [TranscriptSegment] = []
        var words: [WordStamp] = []
        var position: AVAudioFramePosition = 0
        while position < audio.length {
            if cancellation.isCancelled() { throw CancellationError() }
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), audio.length - position))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw WhisperError.audioFileReadFailed
            }
            do { try audio.read(into: buffer, frameCount: count) }
            catch { throw WhisperError.audioFileReadFailed }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw WhisperError.audioFileReadFailed
            }
            let offset = Double(position) / format.sampleRate
            let chunkEnd = offset + Double(buffer.frameLength) / format.sampleRate
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))
            parameters.translate = false
            parameters.no_context = true
            parameters.print_special = false
            parameters.print_progress = false
            parameters.print_realtime = false
            parameters.print_timestamps = false
            parameters.token_timestamps = true
            parameters.max_len = 0
            parameters.split_on_word = false
            parameters.suppress_blank = true
            parameters.abort_callback = { pointer in
                guard let pointer else { return false }
                return Unmanaged<WhisperCancellationFlag>.fromOpaque(pointer).takeUnretainedValue().isCancelled()
            }
            parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            let status = language.rawValue.withCString { languagePointer in
                parameters.language = languagePointer
                return whisper_full(context, parameters, channels[0], Int32(buffer.frameLength))
            }
            if cancellation.isCancelled() { throw CancellationError() }
            guard status == 0 else { throw WhisperError.encodeFailed(status: status) }

            for index in 0..<whisper_full_n_segments(context) {
                guard let textPointer = whisper_full_get_segment_text(context, index) else { continue }
                let text = String(cString: textPointer)
                let start = min(chunkEnd, max(offset, offset + Double(whisper_full_get_segment_t0(context, index)) / 100))
                let end = min(chunkEnd, max(start, offset + Double(whisper_full_get_segment_t1(context, index)) / 100))
                segments.append(TranscriptSegment(startTime: start, endTime: end, text: text))
                for tokenIndex in 0..<whisper_full_n_tokens(context, index) {
                    let token = whisper_full_get_token_data(context, index, tokenIndex)
                    guard token.id < whisper_token_eot(context), token.t0 >= 0, token.t1 >= token.t0,
                          let pointer = whisper_full_get_token_text(context, index, tokenIndex),
                          let word = String(validatingUTF8: pointer) else { continue }
                    words.append(WordStamp(word: word,
                                           start: max(start, min(end, offset + Double(token.t0) / 100)),
                                           end: max(start, min(end, offset + Double(token.t1) / 100))))
                }
            }
            position += AVAudioFramePosition(buffer.frameLength)
            progress(Double(position) / Double(audio.length))
        }
        // Store the exact native segment text. Never reconstruct raw STT with
        // English spacing rules or send it through an LLM cleanup pass.
        return TranscriptionResult(text: segments.map(\.text).joined(), segments: segments, words: words)
        #else
        throw WhisperError.runtimeMissing
        #endif
    }
}
