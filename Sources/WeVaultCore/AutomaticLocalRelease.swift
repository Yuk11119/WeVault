import Foundation
import Darwin
import CryptoKit

public enum ReleaseAuthorization: Sendable {
    case manual(confirmed: Bool, skipRestoreTest: Bool)
    case automatic(settings: ProductSettings, root: URL, now: Date)
}

struct ReleaseJournal: Codable, Sendable {
    let snapshot: ArchivedFileSnapshot
    let quarantinePath: String
    let deletionPath: String?
    let createdAt: Date
    let placeholder: Data?
    let format: String?
    let inode: UInt64
}

extension LocalReleaseService {
    public func isolate(snapshot: ArchivedFileSnapshot, store: ManifestStore, authorization: ReleaseAuthorization,
                        createTombstone: Bool = true) throws -> LocalReleaseResult {
        let key = OperationCoordinator.bindingKey(snapshot.binding.bindingID, store: store)
        try OperationCoordinator.shared.acquire(key); defer { OperationCoordinator.shared.release(key) }
        try recoverPendingRelease(bindingID: snapshot.binding.bindingID, store: store, authorization: authorization)
        guard let current = try store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID) else { throw WeVaultError.fileSystem("归档绑定不存在") }
        try authorize(current, authorization, store: store, finalizing: false)
        try validateReleaseLayers(current)
        let original = URL(fileURLWithPath: current.archivedFile.filePath)
        try requireRegularFile(original)
        guard try sha256File(original) == current.archivedFile.sha256 else { throw WeVaultError.fileSystem("本地 SHA 已变化") }
        let target = try quarantineDestination(current)
        try validateReleasePath(target)
        let date: Date
        if case .automatic(_, _, let now) = authorization { date = now } else { date = Date() }
        let payload = createTombstone && current.archivedFile.objectType == .ordinaryFile ? try Tombstone.payload(for: current, createdAt: date) : nil
        let journal = ReleaseJournal(snapshot: current, quarantinePath: target.path, deletionPath: nil, createdAt: date, placeholder: payload?.data, format: payload?.format, inode: try fileStat(original.path).inode)
        try store.workPut(scope: "release-journal", key: current.binding.bindingID, value: journal)
        try checkpoint("isolationPrepared")
        try commitIsolation(journal, store: store)
        return LocalReleaseResult(originalURL: original, quarantineURL: target, placeholderURL: payload == nil ? nil : original, sha256: current.archivedFile.sha256)
    }

    public func finalizeSafely(snapshot: ArchivedFileSnapshot, store: ManifestStore, authorization: ReleaseAuthorization) throws -> LocalReleaseResult {
        let key = OperationCoordinator.bindingKey(snapshot.binding.bindingID, store: store)
        try OperationCoordinator.shared.acquire(key); defer { OperationCoordinator.shared.release(key) }
        try recoverPendingRelease(bindingID: snapshot.binding.bindingID, store: store, authorization: authorization)
        guard let current = try store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID) else { throw WeVaultError.fileSystem("归档绑定不存在") }
        try authorize(current, authorization, store: store, finalizing: true)
        try validateReleaseLayers(current)
        try validateOriginalForFinalization(current)
        guard let path = current.binding.quarantinePath else { throw WeVaultError.fileSystem("隔离路径缺失") }
        let q = URL(fileURLWithPath: path)
        try validateQuarantineLocation(q, snapshot: current)
        try validateReleasePath(q); try requireRegularFile(q)
        guard try sha256File(q) == current.archivedFile.sha256 else { throw WeVaultError.fileSystem("隔离副本 SHA 不匹配") }
        let date: Date
        if case .automatic(_, _, let now) = authorization { date = now } else { date = Date() }
        let journal = ReleaseJournal(snapshot: current, quarantinePath: path, deletionPath: q.appendingPathExtension("deleting-" + UUID().uuidString).path, createdAt: date, placeholder: nil, format: nil, inode: try fileStat(q.path).inode)
        try store.workPut(scope: "release-journal", key: current.binding.bindingID, value: journal)
        try checkpoint("deletionPrepared")
        try commitDeletion(journal, store: store)
        return LocalReleaseResult(originalURL: URL(fileURLWithPath: current.archivedFile.filePath), quarantineURL: nil, sha256: current.archivedFile.sha256)
    }

    public func recoverPendingRelease(bindingID: String, store: ManifestStore, authorization: ReleaseAuthorization? = nil) throws {
        guard let journal = try store.workGet(ReleaseJournal.self, scope: "release-journal", key: bindingID) else { return }
        if journal.deletionPath == nil,
           !FileManager.default.fileExists(atPath: journal.quarantinePath),
           let current = try store.archivedFileSnapshot(bindingID: bindingID), current.binding.quarantinePath == nil {
            let source = URL(fileURLWithPath: journal.snapshot.archivedFile.filePath)
            if FileManager.default.fileExists(atPath: source.path),
               (try fileStat(source.path).inode != journal.inode || sha256File(source, checkCancellation: false) != journal.snapshot.archivedFile.sha256) {
                // Nothing was committed. A changed source belongs to a new scan, not this intent.
                try store.logOperation("RELEASE_CANCELLED_SOURCE_CHANGED", detail: source.path)
                try store.workDelete(scope: "release-journal", key: bindingID)
                return
            }
        }
        if let authorization {
            let moveHasNotStarted = journal.deletionPath == nil
                ? !FileManager.default.fileExists(atPath: journal.quarantinePath)
                : FileManager.default.fileExists(atPath: journal.quarantinePath)
            if moveHasNotStarted {
                guard let current = try store.archivedFileSnapshot(bindingID: bindingID) else { throw WeVaultError.fileSystem("归档绑定缺失") }
                try authorize(current, authorization, store: store, finalizing: journal.deletionPath != nil)
            }
        }
        if journal.deletionPath == nil { try commitIsolation(journal, store: store) }
        else { try commitDeletion(journal, store: store) }
    }

    /// Called while holding the binding lease. Undo a pending deletion before restoring.
    func prepareForRestore(bindingID: String, store: ManifestStore) throws {
        guard let journal = try store.workGet(ReleaseJournal.self, scope: "release-journal", key: bindingID) else { return }
        if let path = journal.deletionPath {
            let q = URL(fileURLWithPath: journal.quarantinePath), staged = URL(fileURLWithPath: path)
            try validateQuarantineLocation(q, snapshot: journal.snapshot)
            guard staged.deletingLastPathComponent() == q.deletingLastPathComponent(), staged.lastPathComponent.hasPrefix(q.lastPathComponent + ".deleting-") else { throw WeVaultError.fileSystem("删除暂存路径无效") }
            if FileManager.default.fileExists(atPath: staged.path) {
                try requireRegularFile(staged)
                guard try fileStat(staged.path).inode == journal.inode, try sha256File(staged, checkCancellation: false) == journal.snapshot.archivedFile.sha256 else { throw WeVaultError.fileSystem("隔离提交副本发生冲突，请先恢复到下载目录") }
                try exclusiveMove(staged, q)
            }
            if FileManager.default.fileExists(atPath: q.path) {
                try requireRegularFile(q)
                guard try fileStat(q.path).inode == journal.inode, try sha256File(q, checkCancellation: false) == journal.snapshot.archivedFile.sha256 else { throw WeVaultError.fileSystem("隔离副本发生冲突") }
                try store.workDelete(scope: "release-journal", key: bindingID)
                return
            }
        }
        try recoverPendingRelease(bindingID: bindingID, store: store)
    }

    private func authorize(_ snapshot: ArchivedFileSnapshot, _ authorization: ReleaseAuthorization, store: ManifestStore, finalizing: Bool) throws {
        guard snapshot.object.verifyStatus == .verified,
              snapshot.object.cloudObjectID == snapshot.binding.cloudObjectID,
              snapshot.object.sha256 == snapshot.archivedFile.sha256,
              snapshot.object.sizeBytes == snapshot.archivedFile.sizeBytes else { throw WeVaultError.fileSystem("云端校验或绑定不匹配") }
        switch authorization {
        case .manual(let confirmed, let skip):
            guard confirmed else { throw WeVaultError.fileSystem("需要确认释放") }
            if !finalizing && !skip && snapshot.archivedFile.objectType == .ordinaryFile && snapshot.binding.restoredAt == nil { throw WeVaultError.fileSystem("请先完成恢复测试") }
        case .automatic(let settings, let root, let now):
            guard settings.automaticTasksEnabled, settings.cloudMode == .weVault,
                  snapshot.object.storageProvider == "WeVault Managed Cloud", Self.isUnderRoot(snapshot.archivedFile.filePath, root: root) else { throw WeVaultError.fileSystem("对象不在当前自动任务范围") }
            let engine = AutomaticReleaseRuleEngine()
            let duplicate = try store.isArchivedDuplicate(snapshot, root: root)
            let decision = finalizing ? engine.quarantineIsDue(snapshot, settings: settings, now: now, isDuplicate: duplicate) : engine.decision(for: snapshot, settings: settings, now: now, isDuplicate: duplicate)
            guard decision == .eligible else { throw WeVaultError.fileSystem("对象不满足当前自动释放规则：\(decision)") }
        }
        let states: [LocalArchiveState] = finalizing ? [.quarantined, .tombstoned] : [.localPresent, .restored, .quarantined]
        guard states.contains(snapshot.binding.localState) else { throw WeVaultError.fileSystem("本地状态不允许此操作") }
    }

    public static func isUnderRoot(_ path: String, root: URL) -> Bool {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return canonical.hasPrefix(base + "/")
    }

    private func quarantineDestination(_ snapshot: ArchivedFileSnapshot) throws -> URL {
        _ = try RestoreLink(bindingID: snapshot.binding.bindingID)
        let original = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        guard original.lastPathComponent == snapshot.archivedFile.originalFilename else { throw WeVaultError.fileSystem("原始文件名与路径不一致") }
        try validateReleasePath(quarantineRoot)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        var source = stat(), target = stat()
        guard lstat(original.path, &source) == 0, lstat(quarantineRoot.path, &target) == 0 else { throw WeVaultError.fileSystem("无法确认隔离卷") }
        // Keep the atomic rename on the source volume, including externally stored WeChat roots.
        let base = source.st_dev == target.st_dev ? quarantineRoot : original.deletingLastPathComponent().appendingPathComponent(".wevault-quarantine")
        return base.appendingPathComponent(snapshot.binding.bindingID).appendingPathComponent(snapshot.archivedFile.originalFilename)
    }

    private func validateQuarantineLocation(_ q: URL, snapshot: ArchivedFileSnapshot) throws {
        _ = try RestoreLink(bindingID: snapshot.binding.bindingID)
        let original = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        guard original.lastPathComponent == snapshot.archivedFile.originalFilename else { throw WeVaultError.fileSystem("归档文件名不一致") }
        let standard = quarantineRoot.appendingPathComponent(snapshot.binding.bindingID).appendingPathComponent(snapshot.archivedFile.originalFilename).standardizedFileURL
        let local = original.deletingLastPathComponent().appendingPathComponent(".wevault-quarantine").appendingPathComponent(snapshot.binding.bindingID).appendingPathComponent(snapshot.archivedFile.originalFilename).standardizedFileURL
        guard q.standardizedFileURL == standard || q.standardizedFileURL == local else { throw WeVaultError.fileSystem("隔离路径不属于该绑定") }
    }

    private func validateReleaseLayers(_ snapshot: ArchivedFileSnapshot) throws {
        guard snapshot.archivedFile.objectType != .ordinaryFile else { return }
        guard let display = snapshot.archivedFile.displayOrPlaybackPath, let thumb = snapshot.archivedFile.bubbleOrThumbPath else { throw WeVaultError.fileSystem("媒体保留层缺失") }
        try requireRegularFile(URL(fileURLWithPath: display)); try requireRegularFile(URL(fileURLWithPath: thumb))
    }

    private func validateOriginalForFinalization(_ snapshot: ArchivedFileSnapshot) throws {
        let original = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        try validateReleasePath(original)
        if snapshot.binding.placeholderPath != nil {
            try requireRegularFile(original)
            try Tombstone.validatePlaceholder(at: original, binding: snapshot.binding)
        } else if FileManager.default.fileExists(atPath: original.path) {
            throw WeVaultError.fileSystem("原路径已重新出现文件，保留隔离副本")
        }
    }

    private func commitIsolation(_ journal: ReleaseJournal, store: ManifestStore) throws {
        let snapshot = journal.snapshot, original = URL(fileURLWithPath: journal.snapshot.archivedFile.filePath)
        let q = URL(fileURLWithPath: journal.quarantinePath)
        try validateQuarantineLocation(q, snapshot: snapshot)
        try validateReleasePath(original); try validateReleasePath(q)
        try validateReleaseLayers(snapshot)
        try FileManager.default.createDirectory(at: q.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: q.path) {
            try requireRegularFile(original)
            guard try sha256File(original, checkCancellation: false) == snapshot.archivedFile.sha256 else { throw WeVaultError.fileSystem("隔离前原件已变化") }
            guard try fileStat(original.path).inode == journal.inode else { throw WeVaultError.fileSystem("原件身份已变化") }
            try exclusiveMove(original, q)
            try checkpoint("isolationMoved")
        }
        try requireRegularFile(q)
        guard try fileStat(q.path).inode == journal.inode, try sha256File(q, checkCancellation: false) == snapshot.archivedFile.sha256 else { throw WeVaultError.fileSystem("隔离文件冲突，已保留副本和操作记录") }
        // Persist the rescue path before trying to create any placeholder.
        try store.updateLocalReleaseState(bindingID: snapshot.binding.bindingID, archiveState: .verified, localState: .quarantined, releasedAt: nil, quarantinedAt: journal.createdAt, quarantinePath: q.path)
        try checkpoint("isolationStateSaved")
        if let data = journal.placeholder {
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if FileManager.default.fileExists(atPath: original.path) {
                try requireRegularFile(original)
                guard try sha256File(original, checkCancellation: false) == expected else { throw WeVaultError.fileSystem("原路径发生冲突，隔离副本已保留") }
            } else {
                let temp = q.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".placeholder")
                defer { try? FileManager.default.removeItem(at: temp) }
                try data.write(to: temp, options: .withoutOverwriting)
                try exclusiveMove(temp, original)
                try checkpoint("placeholderCommitted")
            }
            try store.updateLocalReleaseState(bindingID: snapshot.binding.bindingID, archiveState: .verified, localState: .tombstoned, releasedAt: nil, quarantinedAt: journal.createdAt, quarantinePath: q.path, placeholderPath: original.path, placeholderCreatedAt: journal.createdAt, placeholderFormat: journal.format, placeholderSHA256: expected, placeholderSize: Int64(data.count))
        } else if FileManager.default.fileExists(atPath: original.path) {
            throw WeVaultError.fileSystem("原路径出现冲突副本，未删除")
        }
        try store.updateFileStatus(path: original.path, status: journal.placeholder == nil ? .releaseEligible : .tombstoned)
        try store.logOperation("AUTOMATION_ISOLATED", detail: original.path)
        try checkpoint("isolationCompleted")
        try store.workDelete(scope: "release-journal", key: snapshot.binding.bindingID)
    }

    private func commitDeletion(_ journal: ReleaseJournal, store: ManifestStore) throws {
        let snapshot = journal.snapshot, q = URL(fileURLWithPath: journal.quarantinePath)
        let staged = URL(fileURLWithPath: journal.deletionPath!)
        try validateQuarantineLocation(q, snapshot: snapshot)
        guard staged.deletingLastPathComponent() == q.deletingLastPathComponent(), staged.lastPathComponent.hasPrefix(q.lastPathComponent + ".deleting-") else { throw WeVaultError.fileSystem("删除暂存路径无效") }
        try validateReleasePath(q); try validateReleasePath(staged)
        try validateReleaseLayers(snapshot); try validateOriginalForFinalization(snapshot)
        if FileManager.default.fileExists(atPath: q.path) {
            try requireRegularFile(q)
            guard try fileStat(q.path).inode == journal.inode, try sha256File(q, checkCancellation: false) == snapshot.archivedFile.sha256 else { throw WeVaultError.fileSystem("隔离 SHA 不匹配") }
            try exclusiveMove(q, staged)
            try checkpoint("deletionMoved")
        }
        if FileManager.default.fileExists(atPath: staged.path) {
            try requireRegularFile(staged)
            guard try fileStat(staged.path).inode == journal.inode, try sha256File(staged, checkCancellation: false) == snapshot.archivedFile.sha256 else { throw WeVaultError.fileSystem("删除提交时文件已变化，冲突副本已保留") }
            try validateReleaseLayers(snapshot); try validateOriginalForFinalization(snapshot)
            try FileManager.default.removeItem(at: staged)
            try checkpoint("deletionRemoved")
        }
        let binding = snapshot.binding
        try store.updateLocalReleaseState(bindingID: binding.bindingID, archiveState: .localReleased, localState: binding.placeholderPath == nil ? .localReleased : .tombstoned, releasedAt: journal.createdAt, quarantinePath: nil, placeholderPath: binding.placeholderPath, placeholderCreatedAt: binding.placeholderCreatedAt, placeholderFormat: binding.placeholderFormat, placeholderSHA256: binding.placeholderSHA256, placeholderSize: binding.placeholderSize)
        try store.logOperation("AUTOMATION_FINALIZED", detail: q.path)
        try checkpoint("deletionStateSaved")
        try store.workDelete(scope: "release-journal", key: binding.bindingID)
    }
}

func validateReleasePath(_ url: URL) throws {
    var component = url.standardizedFileURL
    while component.path != "/" {
        var info = stat()
        if lstat(component.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK, !["/var", "/tmp"].contains(component.path) { throw WeVaultError.fileSystem("拒绝跟随符号链接") }
        component.deleteLastPathComponent()
    }
}

func requireRegularFile(_ url: URL) throws {
    try validateReleasePath(url)
    var info = stat()
    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw WeVaultError.fileSystem("文件不存在或不是普通文件") }
}

private func exclusiveMove(_ source: URL, _ target: URL) throws {
    let result = source.path.withCString { src in target.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) } }
    guard result == 0 else { throw WeVaultError.fileSystem("无法安全移动文件（目标冲突或不在同一卷），未覆盖现有文件") }
}
