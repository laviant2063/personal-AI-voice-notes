import AVFoundation
import XCTest
@testable import WalkWrite

final class AudioSafetyTests: XCTestCase {
    private func header(vocabulary: UInt32 = 51_865) -> Data {
        let values: [UInt32] = [0x67676D6C, vocabulary, 1500, 512, 8, 6, 448, 512, 8, 6, 80, 1]
        var data = Data()
        for var value in values.map(\.littleEndian) {
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testModelValidatorRejectsLFSPointerAndTruncatedFile() throws {
        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:example".utf8)
        XCTAssertThrowsError(try WhisperModelValidator.validateHeader(pointer, fileSize: 134)) {
            XCTAssertEqual($0 as? WhisperModelError, .gitLFSPointer)
        }
        XCTAssertThrowsError(try WhisperModelValidator.validateHeader(header(), fileSize: 100))
        XCTAssertThrowsError(try WhisperModelValidator.validateHeader(Data(repeating: 0, count: 48), fileSize: 2_000_000))
    }

    func testModelValidatorRequiresMultilingualHeader() throws {
        XCTAssertNoThrow(try WhisperModelValidator.validateHeader(header(), fileSize: 2_000_000))
        XCTAssertThrowsError(try WhisperModelValidator.validateHeader(header(vocabulary: 51_864), fileSize: 2_000_000)) {
            XCTAssertEqual($0 as? WhisperModelError, .englishOnly)
        }
    }

    func testManagedAudioRejectsTraversalAndOutsidePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedAudioTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managedAudio = directory.appendingPathComponent("audio.wav")
        try Data(repeating: 0, count: 64).write(to: managedAudio)
        XCTAssertFalse(AppFolders.isSafeAudioFilename("../outside.wav"))
        XCTAssertFalse(AppFolders.isSafeAudioFilename("folder\\outside.wav"))
        XCTAssertFalse(AppFolders.isManagedAudio(root.appendingPathComponent("outside.wav"), in: directory))
        XCTAssertTrue(AppFolders.isManagedAudio(managedAudio, in: directory))
    }

    func testLiveSpeechLocalesAreExplicitAndAutomaticUsesPreferredLanguage() {
        XCTAssertEqual(LiveSpeechLocale.identifier(for: .ko), "ko-KR")
        XCTAssertEqual(LiveSpeechLocale.identifier(for: .en), "en-US")
        XCTAssertEqual(LiveSpeechLocale.identifier(for: .ja), "ja-JP")
        XCTAssertEqual(LiveSpeechLocale.identifier(for: .es), "es-ES")
        XCTAssertEqual(
            LiveSpeechLocale.identifier(for: .automatic, preferredLanguages: ["ko-KR", "en-US"]),
            "ko-KR"
        )
    }

    func testWhisperReaderDownmixesAndResamples48kStereoInBoundedChunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperAudioReader-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: false))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        input.frameLength = 48_000
        let channels = try XCTUnwrap(input.floatChannelData)
        for frame in 0..<Int(input.frameLength) {
            let sample = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.25
            channels[0][frame] = sample
            channels[1][frame] = -sample
        }
        try XCTUnwrap(file).write(from: input)
        file = nil // Finalize the WAV header before the reader opens it.

        var converted: [Float] = []
        try WhisperAudioChunkReader.read(audioFileURL: url) { samples, _ in
            XCTAssertLessThanOrEqual(samples.count, 30 * 16_000)
            converted.append(contentsOf: samples)
        }

        XCTAssertLessThanOrEqual(Swift.abs(converted.count - 16_000), 128)
        XCTAssertLessThan(converted.map { Swift.abs($0) }.max() ?? 1, 0.02,
                          "Opposite stereo channels should cancel when downmixed, not remap one channel")
    }
}
