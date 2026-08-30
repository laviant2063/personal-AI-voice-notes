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

    func testManagedAudioRejectsTraversalAndOutsidePath() {
        let directory = URL(fileURLWithPath: "/app/Notes", isDirectory: true)
        XCTAssertFalse(AppFolders.isSafeAudioFilename("../outside.wav"))
        XCTAssertFalse(AppFolders.isSafeAudioFilename("folder\\outside.wav"))
        XCTAssertFalse(AppFolders.isManagedAudio(URL(fileURLWithPath: "/outside.wav"), in: directory))
        XCTAssertTrue(AppFolders.isManagedAudio(directory.appendingPathComponent("audio.wav"), in: directory))
    }
}
