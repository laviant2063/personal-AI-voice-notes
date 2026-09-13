import AVFoundation

/// Owns the single microphone capture path used by both durable audio storage
/// and optional live transcription. The audio file is authoritative: a live
/// speech-recognition failure never stops or mutates it.
final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var recordedFrames: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var recordingChannelCount: AVAudioChannelCount = 0
    private var recordingCommonFormat: AVAudioCommonFormat = .otherFormat
    private var recordingInterleaved = false
    private var tapInstalled = false
    private var reportedWriteFailure = false
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var levelHandler: ((Float) -> Void)?
    private var failureHandler: ((String) -> Void)?

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard recordingSampleRate > 0 else { return 0 }
        return Double(recordedFrames) / recordingSampleRate
    }

    var isRunning: Bool { engine.isRunning }

    func start(
        writingTo url: URL,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Float) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws {
        guard !tapInstalled else { throw AudioCaptureError.alreadyRunning }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }

        // Keep the hardware input format for the most reliable capture path.
        // WhisperEngine performs bounded, streaming conversion to 16 kHz mono.
        guard format.commonFormat != .otherFormat else { throw AudioCaptureError.inputUnavailable }
        // Store 16-bit PCM even when the engine's client buffers are Float32.
        // This keeps long recordings at half the size of native Float32 WAV
        // without introducing a second microphone path or a lossy codec.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleavedKey: false
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: fileSettings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // Platform-default container protection remains in force. Failing a
            // best-effort attribute must never prevent the microphone capture.
        }

        lock.lock()
        audioFile = file
        recordedFrames = 0
        recordingSampleRate = format.sampleRate
        recordingChannelCount = format.channelCount
        recordingCommonFormat = format.commonFormat
        recordingInterleaved = format.isInterleaved
        reportedWriteFailure = false
        bufferHandler = onBuffer
        levelHandler = onLevel
        failureHandler = onFailure
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func pause() {
        guard engine.isRunning else { return }
        engine.pause()
    }

    func resume() throws {
        guard tapInstalled, !engine.isRunning else { return }
        let current = engine.inputNode.outputFormat(forBus: 0)
        guard current.sampleRate == recordingSampleRate,
              current.channelCount == recordingChannelCount,
              current.commonFormat == recordingCommonFormat,
              current.isInterleaved == recordingInterleaved else {
            throw AudioCaptureError.routeFormatChanged
        }
        try engine.start()
    }

    @discardableResult
    func stop() -> TimeInterval {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        lock.lock()
        let finalDuration = recordingSampleRate > 0
            ? Double(recordedFrames) / recordingSampleRate
            : 0
        // Releasing AVAudioFile flushes/finalizes the WAV header before local
        // Whisper is allowed to open the file.
        audioFile = nil
        bufferHandler = nil
        levelHandler = nil
        failureHandler = nil
        lock.unlock()
        return finalDuration
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        var bufferCallback: ((AVAudioPCMBuffer) -> Void)?
        var levelCallback: ((Float) -> Void)?
        var failureCallback: ((String) -> Void)?

        lock.lock()
        if let audioFile {
            do {
                try audioFile.write(from: buffer)
                recordedFrames += AVAudioFramePosition(buffer.frameLength)
                bufferCallback = bufferHandler
                levelCallback = levelHandler
            } catch where !reportedWriteFailure {
                reportedWriteFailure = true
                failureCallback = failureHandler
            } catch {
                // The first failure already schedules a safe finalization.
            }
        }
        lock.unlock()

        // Speech receives only buffers that were successfully written.
        bufferCallback?(buffer)
        if let levelCallback { levelCallback(Self.normalizedLevel(in: buffer)) }
        failureCallback?("Audio could no longer be written. The available recording will be saved.")
    }

    private static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = samples[index]
            sum += value * value
        }
        return min(1, max(0, sqrt(sum / Float(buffer.frameLength)) * 5))
    }
}

private enum AudioCaptureError: LocalizedError {
    case alreadyRunning
    case inputUnavailable
    case routeFormatChanged

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A recording is already active."
        case .inputUnavailable:
            return "The microphone input format is unavailable. Check the current audio route."
        case .routeFormatChanged:
            return "The microphone format changed with the audio route. Stop now to preserve this recording, then start a new note."
        }
    }
}
