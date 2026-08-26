import Foundation

public struct LocalReleaseResult: Sendable {
    public let originalURL: URL
    public let quarantineURL: URL?
    public let placeholderURL: URL?
    public let sha256: String?

    public init(originalURL: URL, quarantineURL: URL?, placeholderURL: URL? = nil, sha256: String?) {
        self.originalURL = originalURL
        self.quarantineURL = quarantineURL
        self.placeholderURL = placeholderURL
        self.sha256 = sha256
    }
}

public final class LocalReleaseService: Sendable {
    public let quarantineRoot: URL

    public init(quarantineRoot: URL = LocalReleaseService.defaultQuarantineRoot()) {
        self.quarantineRoot = quarantineRoot
    }

    public static func defaultQuarantineRoot() -> URL {
        ManifestStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("quarantine", isDirectory: true)
    }

    public static func isEligibleForPhase5Quarantine(_ snapshot: ArchivedFileSnapshot, requireRestoreTest: Bool = false) -> Bool {
        snapshot.archivedFile.objectType == .ordinaryFile &&
            snapshot.object.verifyStatus == .verified &&
            (snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored) &&
            (snapshot.binding.localState == .localPresent || snapshot.binding.localState == .restored) &&
            (!requireRestoreTest || snapshot.binding.restoredAt != nil)
    }

    public func quarantine(
        snapshot: ArchivedFileSnapshot,
        store: ManifestStore,
        userConfirmed: Bool,
        skipRestoreTest: Bool = false,
        createTombstone: Bool = true
    ) throws -> LocalReleaseResult {
        do {
            try preflightQuarantine(snapshot: snapshot, userConfirmed: userConfirmed, skipRestoreTest: skipRestoreTest)
            if skipRestoreTest && snapshot.binding.restoredAt == nil {
                try store.logOperation("RELEASE_RESTORE_TEST_SKIPPED", detail: snapshot.archivedFile.filePath)
            }

            let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
            let quarantineURL = quarantineURL(for: snapshot)
            let digest = try sha256File(originalURL)
            guard digest == snapshot.archivedFile.sha256 else {
                throw WeVaultError.fileSystem("Local SHA-256 changed before release for \(snapshot.archivedFile.originalFilename)")
            }
            guard !FileManager.default.fileExists(atPath: quarantineURL.path) else {
                throw WeVaultError.fileSystem("Quarantine target already exists at \(quarantineURL.path)")
            }

            try store.logOperation("RELEASE_QUARANTINE_STARTED", detail: originalURL.path)
            try FileManager.default.createDirectory(at: quarantineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: originalURL, to: quarantineURL)

            let placeholderCreatedAt = Date()
            let placeholderPayload = createTombstone ? try Tombstone.payload(for: snapshot, createdAt: placeholderCreatedAt) : nil
            let placeholderSHA: String?
            let placeholderSize: Int64?
            if let payload = placeholderPayload {
                try payload.data.write(to: originalURL, options: .atomic)
                placeholderSHA = try sha256File(originalURL)
                placeholderSize = try fileStat(originalURL.path).size
                try store.logOperation("RELEASE_TOMBSTONE_WRITTEN", detail: "\(payload.format): \(originalURL.path)")
            } else {
                placeholderSHA = nil
                placeholderSize = nil
                if createTombstone {
                    try store.logOperation("RELEASE_TOMBSTONE_UNSUPPORTED_TYPE", detail: originalURL.path)
                }
            }
            let wroteTombstone = placeholderPayload != nil

            try store.updateLocalReleaseState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .verified,
                localState: wroteTombstone ? .tombstoned : .quarantined,
                releasedAt: nil,
                quarantinePath: quarantineURL.path,
                placeholderPath: wroteTombstone ? originalURL.path : nil,
                placeholderCreatedAt: wroteTombstone ? placeholderCreatedAt : nil,
                placeholderFormat: placeholderPayload?.format,
                placeholderSHA256: placeholderSHA,
                placeholderSize: placeholderSize
            )
            try store.updateFileStatus(path: snapshot.archivedFile.filePath, status: wroteTombstone ? .tombstoned : .releaseEligible)
            try store.logOperation("RELEASE_QUARANTINE_FINISHED", detail: quarantineURL.path)
            return LocalReleaseResult(originalURL: originalURL, quarantineURL: quarantineURL, placeholderURL: wroteTombstone ? originalURL : nil, sha256: digest)
        } catch {
            try? store.updateLocalReleaseState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .releaseFailed,
                localState: .releaseFailed,
                releasedAt: snapshot.binding.releasedAt,
                quarantinePath: snapshot.binding.quarantinePath
            )
            try? store.updateFileStatus(path: snapshot.archivedFile.filePath, status: .releaseFailed)
            try? store.logOperation("RELEASE_FAILED", detail: "\(snapshot.archivedFile.filePath): \(error.localizedDescription)")
            throw error
        }
    }

    public func rollback(snapshot: ArchivedFileSnapshot, store: ManifestStore) throws -> LocalReleaseResult {
        let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        guard snapshot.binding.localState == .quarantined || snapshot.binding.localState == .tombstoned else {
            throw WeVaultError.fileSystem("Only quarantined or tombstoned files can be rolled back")
        }
        guard let quarantinePath = snapshot.binding.quarantinePath else {
            throw WeVaultError.fileSystem("Missing quarantine path for \(snapshot.archivedFile.originalFilename)")
        }
        let quarantineURL = URL(fileURLWithPath: quarantinePath)
        guard FileManager.default.fileExists(atPath: quarantineURL.path) else {
            throw WeVaultError.fileSystem("Quarantine file is missing at \(quarantineURL.path)")
        }
        if FileManager.default.fileExists(atPath: originalURL.path) {
            guard snapshot.binding.localState == .tombstoned else {
                throw WeVaultError.fileSystem("Refusing to overwrite existing file at \(originalURL.path)")
            }
            try Tombstone.validatePlaceholder(at: originalURL, binding: snapshot.binding)
            try FileManager.default.removeItem(at: originalURL)
        }

        try store.logOperation("RELEASE_ROLLBACK_STARTED", detail: quarantineURL.path)
        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: quarantineURL, to: originalURL)
        let digest = try sha256File(originalURL)
        guard digest == snapshot.archivedFile.sha256 else {
            throw WeVaultError.fileSystem("Rolled back SHA-256 mismatch for \(snapshot.archivedFile.originalFilename)")
        }
        try store.updateLocalReleaseState(
            bindingID: snapshot.binding.bindingID,
            archiveState: .verified,
            localState: .localPresent,
            releasedAt: nil,
            quarantinePath: nil,
            placeholderPath: nil,
            placeholderCreatedAt: nil,
            placeholderFormat: nil,
            placeholderSHA256: nil,
            placeholderSize: nil
        )
        try store.updateFileStatus(path: snapshot.archivedFile.filePath, status: .verified)
        try store.logOperation("RELEASE_ROLLBACK_FINISHED", detail: originalURL.path)
        return LocalReleaseResult(originalURL: originalURL, quarantineURL: nil, sha256: digest)
    }

    public func finalizeRelease(snapshot: ArchivedFileSnapshot, store: ManifestStore) throws -> LocalReleaseResult {
        guard snapshot.binding.localState == .quarantined || snapshot.binding.localState == .tombstoned else {
            throw WeVaultError.fileSystem("Only quarantined or tombstoned files can be finally released")
        }
        guard let quarantinePath = snapshot.binding.quarantinePath else {
            throw WeVaultError.fileSystem("Missing quarantine path for \(snapshot.archivedFile.originalFilename)")
        }
        let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        let quarantineURL = URL(fileURLWithPath: quarantinePath)
        guard FileManager.default.fileExists(atPath: quarantineURL.path) else {
            throw WeVaultError.fileSystem("Quarantine file is missing at \(quarantineURL.path)")
        }

        let digest = try sha256File(quarantineURL)
        guard digest == snapshot.archivedFile.sha256 else {
            throw WeVaultError.fileSystem("Quarantine SHA-256 mismatch for \(snapshot.archivedFile.originalFilename)")
        }

        try store.logOperation("RELEASE_DELETE_QUARANTINE_STARTED", detail: quarantineURL.path)
        try FileManager.default.removeItem(at: quarantineURL)
        let keepsTombstone = snapshot.binding.localState == .tombstoned
        try store.updateLocalReleaseState(
            bindingID: snapshot.binding.bindingID,
            archiveState: .localReleased,
            localState: keepsTombstone ? .tombstoned : .localReleased,
            releasedAt: Date(),
            quarantinePath: nil,
            placeholderPath: keepsTombstone ? snapshot.binding.placeholderPath : nil,
            placeholderCreatedAt: keepsTombstone ? snapshot.binding.placeholderCreatedAt : nil,
            placeholderFormat: keepsTombstone ? snapshot.binding.placeholderFormat : nil,
            placeholderSHA256: keepsTombstone ? snapshot.binding.placeholderSHA256 : nil,
            placeholderSize: keepsTombstone ? snapshot.binding.placeholderSize : nil
        )
        try store.updateFileStatus(path: snapshot.archivedFile.filePath, status: keepsTombstone ? .tombstoned : .localReleased)
        try store.logOperation("RELEASE_DELETE_QUARANTINE_FINISHED", detail: originalURL.path)
        return LocalReleaseResult(originalURL: originalURL, quarantineURL: nil, sha256: digest)
    }

    private func preflightQuarantine(snapshot: ArchivedFileSnapshot, userConfirmed: Bool, skipRestoreTest: Bool) throws {
        guard userConfirmed else {
            throw WeVaultError.fileSystem("User confirmation is required before local release")
        }
        guard snapshot.archivedFile.objectType == .ordinaryFile else {
            throw WeVaultError.fileSystem("Phase 5 only releases ordinary files; media layers are reserved for later phases")
        }
        guard snapshot.object.verifyStatus == .verified else {
            throw WeVaultError.cloud("Cloud object must be verified before local release")
        }
        guard snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored else {
            throw WeVaultError.cloud("Archive binding must be verified before local release")
        }
        guard snapshot.binding.localState == .localPresent || snapshot.binding.localState == .restored else {
            throw WeVaultError.fileSystem("Only local-present ordinary files can be quarantined")
        }
        guard skipRestoreTest || snapshot.binding.restoredAt != nil else {
            throw WeVaultError.fileSystem("Run a restore test first, or explicitly skip it")
        }
        let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw WeVaultError.fileSystem("Local file is missing at \(originalURL.path)")
        }
    }

    private func quarantineURL(for snapshot: ArchivedFileSnapshot) -> URL {
        quarantineRoot
            .appendingPathComponent(snapshot.binding.bindingID, isDirectory: true)
            .appendingPathComponent(snapshot.archivedFile.originalFilename)
    }
}
