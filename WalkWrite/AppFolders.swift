import Foundation

/// Stable, durable application paths. Directory creation is explicit and throwing.
public enum AppFolders {
    public static let notes: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Notes", isDirectory: true)
    }()

    @discardableResult
    public static func ensureNotesDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        return notes
    }

    static func isSafeAudioFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".."
            && !filename.contains("/") && !filename.contains("\\")
            && ["wav", "m4a", "caf"].contains((filename as NSString).pathExtension.lowercased())
    }

    /// Only direct audio children of the managed folder may be removed.
    /// Symlinks are deliberately excluded, even when their destination is local.
    static func isManagedAudio(_ url: URL, in directory: URL) -> Bool {
        guard url.isFileURL, isSafeAudioFilename(url.lastPathComponent) else { return false }
        let normalizedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedURL = url.standardizedFileURL
        guard normalizedURL.deletingLastPathComponent().resolvingSymlinksInPath() == normalizedDirectory else {
            return false
        }
        if let values = try? normalizedURL.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            return false
        }
        return normalizedURL.resolvingSymlinksInPath().deletingLastPathComponent() == normalizedDirectory
    }
}

extension CodingUserInfoKey {
    static let noteStorageDirectory = CodingUserInfoKey(rawValue: "noteStorageDirectory")!
}
