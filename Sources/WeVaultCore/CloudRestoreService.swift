import Foundation
import Darwin

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
        try await restore(snapshot: snapshot, destination: destination, client: clientFactory(config), objectKey: snapshot.object.objectKey, store: store)
    }

    public func restore(
        snapshot: ArchivedFileSnapshot,
        destination: RestoreDestination = .defaultDownloads,
        client: any ObjectStorageClient,
        objectKey: String,
        store: ManifestStore
    ) async throws -> CloudRestoreResult {
        let operationKey = OperationCoordinator.bindingKey(snapshot.binding.bindingID, store: store)
        try OperationCoordinator.shared.acquire(operationKey)
        defer { OperationCoordinator.shared.release(operationKey) }
        if case .originalPath = destination, try store.hasPendingRelease(bindingID: snapshot.binding.bindingID) {
            // Infer the configured quarantine root from the durable journal for isolated stores.
            let journal = try store.workGet(ReleaseJournal.self, scope: "release-journal", key: snapshot.binding.bindingID)!
            let root = URL(fileURLWithPath: journal.quarantinePath).deletingLastPathComponent().deletingLastPathComponent()
            try LocalReleaseService(quarantineRoot: root).prepareForRestore(bindingID: snapshot.binding.bindingID, store: store)
        }
        guard let snapshot = try store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID) else {
            throw WeVaultError.fileSystem("归档绑定不存在")
        }
        guard snapshot.object.verifyStatus == .verified,
              snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored || snapshot.binding.archiveState == .localReleased || snapshot.binding.archiveState == .restoreFailed || snapshot.binding.archiveState == .restorePending else {
            throw WeVaultError.cloud("Only verified cloud objects can be restored")
        }
        guard snapshot.binding.cloudObjectID == snapshot.object.cloudObjectID,
              snapshot.binding.filePath == snapshot.archivedFile.filePath,
              snapshot.object.sha256 == snapshot.archivedFile.sha256,
              snapshot.object.sizeBytes == snapshot.archivedFile.sizeBytes else {
            throw WeVaultError.cloud("Archive binding does not match cloud object")
        }

        let targetURL = try resolvedTargetURL(for: snapshot.archivedFile, destination: destination)
        let restoreToOriginalPath = {
            if case .originalPath = destination { return true }
            return false
        }()
        let previousLocalState = reconciledLocalState(snapshot)
        let now = Date()
        try store.updateRestoreState(
            bindingID: snapshot.binding.bindingID,
            archiveState: .restorePending,
            localState: previousLocalState,
            restoredAt: snapshot.binding.restoredAt,
            lastRestoreCheckAt: now
        )
        try store.logOperation("RESTORE_STARTED", detail: targetURL.path)

        do {
            let finalURL = try await downloadAndVerify(snapshot: snapshot, targetURL: targetURL, restoreToOriginalPath: restoreToOriginalPath, client: client, objectKey: objectKey)
            let digest = try sha256File(finalURL)
            let completedAt = Date()
            try store.updateRestoreState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .restored,
                localState: restoreToOriginalPath ? .restored : previousLocalState,
                restoredAt: completedAt,
                lastRestoreCheckAt: completedAt
            )
            if restoreToOriginalPath {
                try removeMatchingQuarantineCopyIfNeeded(snapshot: snapshot, restoredURL: finalURL, store: store)
                try store.clearPlaceholderState(bindingID: snapshot.binding.bindingID)
            }
            try store.logOperation("RESTORE_FINISHED", detail: finalURL.path)
            return CloudRestoreResult(destinationURL: finalURL, sha256: digest)
        } catch {
            try? store.updateRestoreState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .restoreFailed,
                localState: previousLocalState,
                restoredAt: snapshot.binding.restoredAt,
                lastRestoreCheckAt: Date()
            )
            try? store.logOperation("RESTORE_FAILED", detail: "\(targetURL.path): \(error.localizedDescription)")
            throw error
        }
    }

    private func downloadAndVerify(snapshot: ArchivedFileSnapshot, targetURL: URL, restoreToOriginalPath: Bool, client: any ObjectStorageClient, objectKey: String) async throws -> URL {
        let fileManager = FileManager.default
        if restoreToOriginalPath { try validateRetainedLayers(snapshot) }
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try validateTargetType(targetURL)
        if fileManager.fileExists(atPath: targetURL.path) {
            let existingHash = try sha256File(targetURL)
            if existingHash == snapshot.archivedFile.sha256 {
                return targetURL
            }
            if restoreToOriginalPath {
                try Tombstone.validatePlaceholder(at: targetURL, binding: snapshot.binding)
                // Keep the placeholder until the download is verified.
            } else {
                throw WeVaultError.fileSystem("Refusing to overwrite existing file at \(targetURL.path)")
            }
        }

        let temporaryURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).wevault-download-\(UUID().uuidString)")
        var preserveTemporary = false
        defer {
            if !preserveTemporary && fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try await client.getObject(objectKey: objectKey, destinationURL: temporaryURL)
        let stat = try fileStat(temporaryURL.path)
        guard stat.size == snapshot.archivedFile.sizeBytes else {
            throw WeVaultError.cloud("Restored size mismatch for \(snapshot.archivedFile.originalFilename)")
        }
        let digest = try sha256File(temporaryURL)
        guard digest == snapshot.archivedFile.sha256 else {
            throw WeVaultError.cloud("Restored SHA-256 mismatch for \(snapshot.archivedFile.originalFilename)")
        }
        try Task.checkCancellation()
        if restoreToOriginalPath { try validateRetainedLayers(snapshot) }
        try validateTargetType(targetURL)
        if fileManager.fileExists(atPath: targetURL.path) {
            guard restoreToOriginalPath else { throw WeVaultError.fileSystem("恢复目标已存在，请重试以选择新文件名") }
            if try sha256File(targetURL) == snapshot.archivedFile.sha256 { return targetURL }
            try Tombstone.validatePlaceholder(at: targetURL, binding: snapshot.binding)
            // Swap atomically, retaining the displaced file until its identity is checked.
            let status = temporaryURL.path.withCString { source in
                targetURL.path.withCString { target in renamex_np(source, target, UInt32(RENAME_SWAP)) }
            }
            guard status == 0 else { throw WeVaultError.fileSystem("无法安全替换占位文件") }
            do {
                try validateTargetType(temporaryURL)
                guard try sha256File(temporaryURL) == snapshot.binding.placeholderSHA256,
                      Tombstone.isTombstone(temporaryURL) else {
                    throw WeVaultError.fileSystem("占位文件在替换时发生变化")
                }
            } catch {
                let rollback = temporaryURL.path.withCString { source in
                    targetURL.path.withCString { target in renamex_np(source, target, UInt32(RENAME_SWAP)) }
                }
                if rollback != 0 { preserveTemporary = true }
                throw WeVaultError.fileSystem("替换时目标发生变化，已尝试回滚；保留恢复入口和冲突副本")
            }
        } else {
            let status = temporaryURL.path.withCString { source in
                targetURL.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
            }
            guard status == 0 else { throw WeVaultError.fileSystem("目标已变化或无法写入，未覆盖现有文件") }
        }
        let finalDigest = try sha256File(targetURL)
        guard finalDigest == snapshot.archivedFile.sha256 else {
            throw WeVaultError.cloud("Final restored SHA-256 mismatch for \(snapshot.archivedFile.originalFilename)")
        }
        return targetURL
    }

    /// Earlier versions wrote RESTORE_FAILED into the local state even when the
    /// original/placeholder was untouched. Repair only that legacy failure state.
    private func reconciledLocalState(_ snapshot: ArchivedFileSnapshot) -> LocalArchiveState {
        guard snapshot.binding.localState == .restoreFailed else { return snapshot.binding.localState }
        let target = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        if (try? Tombstone.validatePlaceholder(at: target, binding: snapshot.binding)) != nil { return .tombstoned }
        if (try? sha256File(target)) == snapshot.archivedFile.sha256 { return .localPresent }
        if let path = snapshot.binding.quarantinePath, FileManager.default.fileExists(atPath: path) { return .quarantined }
        if !FileManager.default.fileExists(atPath: target.path) { return .localReleased }
        return .restoreFailed
    }

    private func validateTargetType(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw WeVaultError.fileSystem("恢复目标不是普通文件，拒绝覆盖或跟随符号链接")
            }
        } else if errno != ENOENT { throw WeVaultError.fileSystem("无法检查恢复目标") }
    }

    private func validateRetainedLayers(_ snapshot: ArchivedFileSnapshot) throws {
        guard snapshot.archivedFile.objectType != .ordinaryFile else { return }
        let file = snapshot.archivedFile
        guard let display = file.displayOrPlaybackPath,
              FileManager.default.fileExists(atPath: display) else {
            throw WeVaultError.fileSystem("普通查看或播放层缺失，请改为下载目录恢复")
        }
        if file.objectType == .videoRawLayer {
            guard let thumb = file.bubbleOrThumbPath, FileManager.default.fileExists(atPath: thumb) else {
                throw WeVaultError.fileSystem("视频封面或缩略图缺失，请改为下载目录恢复")
            }
        }
    }

    private func removeMatchingQuarantineCopyIfNeeded(snapshot: ArchivedFileSnapshot, restoredURL: URL, store: ManifestStore) throws {
        guard let quarantinePath = snapshot.binding.quarantinePath else { return }
        let quarantineURL = URL(fileURLWithPath: quarantinePath)
        guard FileManager.default.fileExists(atPath: quarantineURL.path) else { return }

        let restoredDigest = try sha256File(restoredURL)
        let quarantineDigest = try sha256File(quarantineURL)
        guard restoredDigest == snapshot.archivedFile.sha256,
              quarantineDigest == snapshot.archivedFile.sha256 else {
            throw WeVaultError.fileSystem("Refusing to remove quarantine copy because SHA-256 does not match manifest")
        }

        try FileManager.default.removeItem(at: quarantineURL)
        try store.logOperation("RESTORE_REMOVED_MATCHING_QUARANTINE", detail: quarantineURL.path)
    }

    private func resolvedTargetURL(for archivedFile: ArchivedFile, destination: RestoreDestination) throws -> URL {
        guard !archivedFile.originalFilename.isEmpty,
              archivedFile.originalFilename != ".", archivedFile.originalFilename != "..",
              !archivedFile.originalFilename.contains("/"), !archivedFile.originalFilename.contains("\u{0}") else {
            throw WeVaultError.fileSystem("归档文件名无效")
        }
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
