import Foundation

public enum RestoreDestination: Sendable {
    case defaultDownloads
    case directory(URL)
    case originalPath
}

public struct CloudRestoreResult: Sendable {
    public let destinationURL: URL
    public let sha256: String

    public init(destinationURL: URL, sha256: String) {
        self.destinationURL = destinationURL
        self.sha256 = sha256
    }
}

public final class CloudRestoreService: Sendable {
    public typealias ClientFactory = @Sendable (S3CompatibleStorageConfig) -> any ObjectStorageClient

    private let clientFactory: ClientFactory

    public init(clientFactory: @escaping ClientFactory = { S3CompatibleObjectStorageClient(config: $0) }) {
        self.clientFactory = clientFactory
    }

    public static func defaultRestoreDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WeChat Archive Restores", isDirectory: true)
    }

    public func restore(
        snapshot: ArchivedFileSnapshot,
        destination: RestoreDestination = .defaultDownloads,
        config: S3CompatibleStorageConfig,
        store: ManifestStore
    ) async throws -> CloudRestoreResult {
        guard snapshot.object.verifyStatus == .verified, snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored else {
            throw WeVaultError.cloud("Only verified cloud objects can be restored")
        }
        guard snapshot.binding.cloudObjectID == snapshot.object.cloudObjectID else {
            throw WeVaultError.cloud("Archive binding does not match cloud object")
        }

        let targetURL = try resolvedTargetURL(for: snapshot.archivedFile, destination: destination)
        let now = Date()
        try store.updateRestoreState(
            bindingID: snapshot.binding.bindingID,
            archiveState: .restorePending,
            localState: snapshot.binding.localState,
            restoredAt: snapshot.binding.restoredAt,
            lastRestoreCheckAt: now
        )
        try store.logOperation("RESTORE_STARTED", detail: targetURL.path)

        do {
            let finalURL = try await downloadAndVerify(snapshot: snapshot, targetURL: targetURL, config: config)
            let digest = try sha256File(finalURL)
            let completedAt = Date()
            try store.updateRestoreState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .restored,
                localState: .restored,
                restoredAt: completedAt,
                lastRestoreCheckAt: completedAt
            )
            try store.logOperation("RESTORE_FINISHED", detail: finalURL.path)
            return CloudRestoreResult(destinationURL: finalURL, sha256: digest)
        } catch {
            try? store.updateRestoreState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .restoreFailed,
                localState: .restoreFailed,
                restoredAt: snapshot.binding.restoredAt,
                lastRestoreCheckAt: Date()
            )
            try? store.logOperation("RESTORE_FAILED", detail: "\(targetURL.path): \(error.localizedDescription)")
            throw error
        }
    }

    private func downloadAndVerify(snapshot: ArchivedFileSnapshot, targetURL: URL, config: S3CompatibleStorageConfig) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: targetURL.path) {
            let existingHash = try sha256File(targetURL)
            guard existingHash == snapshot.archivedFile.sha256 else {
                throw WeVaultError.fileSystem("Refusing to overwrite existing file at \(targetURL.path)")
            }
            return targetURL
        }

        let temporaryURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).wevault-download-\(UUID().uuidString)")
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try await clientFactory(config).getObject(objectKey: snapshot.object.objectKey, destinationURL: temporaryURL)
        let stat = try fileStat(temporaryURL.path)
        guard stat.size == snapshot.archivedFile.sizeBytes else {
            throw WeVaultError.cloud("Restored size mismatch for \(snapshot.archivedFile.originalFilename)")
        }
        let digest = try sha256File(temporaryURL)
        guard digest == snapshot.archivedFile.sha256 else {
            throw WeVaultError.cloud("Restored SHA-256 mismatch for \(snapshot.archivedFile.originalFilename)")
        }
        try fileManager.moveItem(at: temporaryURL, to: targetURL)
        let finalDigest = try sha256File(targetURL)
        guard finalDigest == snapshot.archivedFile.sha256 else {
            throw WeVaultError.cloud("Final restored SHA-256 mismatch for \(snapshot.archivedFile.originalFilename)")
        }
        return targetURL
    }

    private func resolvedTargetURL(for archivedFile: ArchivedFile, destination: RestoreDestination) throws -> URL {
        switch destination {
        case .defaultDownloads:
            return uniqueURL(in: Self.defaultRestoreDirectory(), filename: archivedFile.originalFilename)
        case .directory(let directory):
            return uniqueURL(in: directory, filename: archivedFile.originalFilename)
        case .originalPath:
            let targetURL = URL(fileURLWithPath: archivedFile.filePath)
            guard targetURL.lastPathComponent == archivedFile.originalFilename else {
                throw WeVaultError.fileSystem("Manifest filename does not match original path")
            }
            return targetURL
        }
    }

    private func uniqueURL(in directory: URL, filename: String) -> URL {
        let fileManager = FileManager.default
        let baseURL = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: baseURL.path) else { return baseURL }

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for index in 1...999 {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(stem)-restored-\(index)"
            } else {
                candidateName = "\(stem)-restored-\(index).\(ext)"
            }
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }
}
