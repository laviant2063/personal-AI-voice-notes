import Foundation
import Combine

public enum WhisperLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case ko
    case en
    case ja
    case es

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Detect automatically"
        case .ko: return "한국어"
        case .en: return "English"
        case .ja: return "日本語"
        case .es: return "Español"
        }
    }
}

enum WhisperModelError: LocalizedError, Equatable {
    case missing
    case gitLFSPointer
    case invalidModel
    case englishOnly
    case busy

    var errorDescription: String? {
        switch self {
        case .missing:
            return "Whisper model missing. Import a multilingual GGML .bin model in Settings. Audio is saved and can be transcribed later."
        case .gitLFSPointer:
            return "This file is a Git LFS pointer, not a Whisper model. Download the actual multilingual GGML .bin file before importing it."
        case .invalidModel:
            return "This is not a supported multilingual Whisper GGML model, or the file is incomplete. Import a model from the official whisper.cpp model collection."
        case .englishOnly:
            return "This is an English-only model. Use a multilingual model without .en in its name for Korean, English, Japanese, and Spanish."
        case .busy:
            return "Wait for transcription or the current model import to finish before installing another model."
        }
    }
}

/// A lightweight file/header check, not an inference or full tensor validation.
/// The GGML header layout is documented by whisper.cpp's convert-pt-to-ggml.py.
enum WhisperModelValidator {
    static let minimumFileSize = 1_000_000

    static func validate(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw WhisperModelError.invalidModel
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256) ?? Data()
        try validateHeader(prefix, fileSize: size)
    }

    static func validateHeader(_ prefix: Data, fileSize: Int) throws {
        if prefix.starts(with: Data("version https://git-lfs.github.com/spec/v1".utf8)) {
            throw WhisperModelError.gitLFSPointer
        }
        guard fileSize >= minimumFileSize, prefix.count >= 48 else {
            throw WhisperModelError.invalidModel
        }
        // Decode explicitly, without assuming the Data buffer is UInt32-aligned.
        func integer(at offset: Int) -> UInt32 {
            let bytes = Array(prefix[offset..<(offset + 4)])
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
        guard integer(at: 0) == 0x67676D6C else { throw WhisperModelError.invalidModel }
        let vocabulary = integer(at: 4)
        guard vocabulary >= 51_865 else { throw WhisperModelError.englishOnly }
        guard vocabulary <= 60_000,
              integer(at: 8) == 1_500,
              (1...1_280).contains(integer(at: 12)),
              (1...20).contains(integer(at: 16)),
              (1...32).contains(integer(at: 20)),
              integer(at: 24) == 448,
              integer(at: 28) == integer(at: 12),
              (1...20).contains(integer(at: 32)),
              (1...32).contains(integer(at: 36)),
              [80, 128].contains(integer(at: 40)) else {
            throw WhisperModelError.invalidModel
        }
    }
}

@MainActor
final class WhisperModelManager: ObservableObject {
    enum Status: String { case missing, installed }

    static let shared = WhisperModelManager()
    private static let selectedFilenameKey = "installedWhisperModelFilename"

    @Published private(set) var status: Status = .missing
    @Published private(set) var installedModelURL: URL?
    @Published private(set) var isInstalling = false
    @Published private(set) var errorMessage: String?

    private let directory: URL
    private let defaults: UserDefaults
    private let bundledModelURL: URL?

    var statusDescription: String {
        switch status {
        case .missing: return "Missing"
        case .installed: return "Installed"
        }
    }

    init(directory: URL? = nil,
         defaults: UserDefaults = .standard,
         bundledModelURL: URL? = Bundle.main.url(forResource: "ggml-large-v3-turbo-q5_0", withExtension: "bin")) {
        self.directory = directory ?? AppFolders.notes.deletingLastPathComponent()
            .appendingPathComponent("Models", isDirectory: true)
        self.defaults = defaults
        self.bundledModelURL = bundledModelURL
        refresh()
    }

    func refresh() {
        var candidates: [URL] = []
        if let name = defaults.string(forKey: Self.selectedFilenameKey),
           name == URL(fileURLWithPath: name).lastPathComponent,
           name.hasSuffix(".bin") {
            candidates.append(directory.appendingPathComponent(name))
        }
        if let bundledModelURL { candidates.append(bundledModelURL) }

        var lastError: Error = WhisperModelError.missing
        for candidate in candidates {
            do {
                try WhisperModelValidator.validate(at: candidate)
                installedModelURL = candidate
                status = .installed
                errorMessage = nil
                return
            } catch {
                lastError = error
            }
        }
        installedModelURL = nil
        status = .missing
        errorMessage = lastError.localizedDescription
    }

    /// The user explicitly chooses a file. This never downloads a model or touches notes.
    /// Each install gets a unique filename; an interrupted copy cannot replace a good model.
    func importModel(from sourceURL: URL) async throws {
        guard !isInstalling, WhisperStateManager.shared.canAcceptNewJob() else {
            throw WhisperModelError.busy
        }
        isInstalling = true
        errorMessage = nil
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            isInstalling = false
        }
        let destinationDirectory = directory
        do {
            let filename = try await Task.detached(priority: .utility) {
                try WhisperModelValidator.validate(at: sourceURL)
                let manager = FileManager.default
                try manager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                let id = UUID().uuidString
                let temporary = destinationDirectory.appendingPathComponent("\(id).partial")
                let destination = destinationDirectory.appendingPathComponent("whisper-\(id).bin")
                do {
                    try manager.copyItem(at: sourceURL, to: temporary)
                    try WhisperModelValidator.validate(at: temporary)
                    try manager.moveItem(at: temporary, to: destination)
                    return destination.lastPathComponent
                } catch {
                    // Only this operation's unique, incomplete copy is disposable.
                    if manager.fileExists(atPath: temporary.path) {
                        do { try manager.removeItem(at: temporary) }
                        catch { NSLog("Whisper model import: incomplete copy cleanup failed.") }
                    }
                    throw error
                }
            }.value
            defaults.set(filename, forKey: Self.selectedFilenameKey)
            refresh()
        } catch {
            // Leave the previous installedModelURL and selected filename unchanged.
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
