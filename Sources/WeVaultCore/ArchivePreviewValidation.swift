import Foundation

public enum ArchivePreviewValidation {
    public static func matches(_ url: URL, file: ArchivedFile) throws -> Bool {
        let stat = try fileStat(url.path)
        guard stat.size == file.sizeBytes else { return false }
        return try sha256File(url) == file.sha256
    }
}
