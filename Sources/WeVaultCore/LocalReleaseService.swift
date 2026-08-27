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

    public static func isEligibleForPhase6ImageHighLayerRelease(_ snapshot: ArchivedFileSnapshot) -> Bool {
        snapshot.archivedFile.objectType == .imageHighLayer &&
            snapshot.object.verifyStatus == .verified &&
            (snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored) &&
            (snapshot.binding.localState == .localPresent ||
             snapshot.binding.localState == .restored ||
             snapshot.binding.localState == .quarantined) &&
            FileManager.default.fileExists(atPath: snapshot.archivedFile.filePath) &&
            snapshot.archivedFile.displayOrPlaybackPath.map { FileManager.default.fileExists(atPath: $0) } == true &&
            snapshot.archivedFile.bubbleOrThumbPath.map { FileManager.default.fileExists(atPath: $0) } == true
    }

    public static func isEligibleForPhase7VideoRawLayerRelease(_ snapshot: ArchivedFileSnapshot) -> Bool {
        snapshot.archivedFile.objectType == .videoRawLayer &&
            snapshot.object.verifyStatus == .verified &&
            (snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored) &&
            (snapshot.binding.localState == .localPresent ||
             snapshot.binding.localState == .restored ||
             snapshot.binding.localState == .quarantined) &&
            FileManager.default.fileExists(atPath: snapshot.archivedFile.filePath) &&
            snapshot.archivedFile.displayOrPlaybackPath.map { FileManager.default.fileExists(atPath: $0) } == true &&
            snapshot.archivedFile.bubbleOrThumbPath.map { FileManager.default.fileExists(atPath: $0) } == true
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

    public func quarantineImageHighLayer(
        snapshot: ArchivedFileSnapshot,
        store: ManifestStore,
        userConfirmed: Bool
    ) throws -> LocalReleaseResult {
        do {
            try preflightImageHighLayerRelease(snapshot: snapshot, userConfirmed: userConfirmed)

            let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
            let quarantineURL = quarantineURL(for: snapshot)
            let digest = try sha256File(originalURL)
            guard digest == snapshot.archivedFile.sha256 else {
                throw WeVaultError.fileSystem("Local SHA-256 changed before image high layer release for \(snapshot.archivedFile.originalFilename)")
            }
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                let quarantineDigest = try sha256File(quarantineURL)
                guard quarantineDigest == snapshot.archivedFile.sha256 else {
                    throw WeVaultError.fileSystem("Quarantine target already exists with different SHA-256 at \(quarantineURL.path)")
                }
            } else {
                try FileManager.default.createDirectory(at: quarantineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }

            try store.logOperation("IMAGE_HIGH_RELEASE_QUARANTINE_STARTED", detail: originalURL.path)
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                try FileManager.default.removeItem(at: originalURL)
                try store.logOperation("IMAGE_HIGH_RELEASE_AUTO_RECOVERED_COPY_REMOVED", detail: originalURL.path)
            } else {
                try FileManager.default.moveItem(at: originalURL, to: quarantineURL)
            }

            try store.updateLocalReleaseState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .verified,
                localState: .quarantined,
                releasedAt: nil,
                quarantinePath: quarantineURL.path,
                placeholderPath: nil,
                placeholderCreatedAt: nil,
                placeholderFormat: nil,
                placeholderSHA256: nil,
                placeholderSize: nil
            )
            try store.updateFileStatus(path: snapshot.archivedFile.filePath, status: .releaseEligible)
            try store.logOperation("IMAGE_HIGH_RELEASE_QUARANTINE_FINISHED", detail: quarantineURL.path)
            return LocalReleaseResult(originalURL: originalURL, quarantineURL: quarantineURL, sha256: digest)
        } catch {
            try? store.updateLocalReleaseState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .releaseFailed,
                localState: .releaseFailed,
                releasedAt: snapshot.binding.releasedAt,
                quarantinePath: snapshot.binding.quarantinePath
            )
            try? store.updateFileStatus(path: snapshot.archivedFile.filePath, status: .releaseFailed)
            try? store.logOperation("IMAGE_HIGH_RELEASE_FAILED", detail: "\(snapshot.archivedFile.filePath): \(error.localizedDescription)")
            throw error
        }
    }

    public func quarantineVideoRawLayer(
        snapshot: ArchivedFileSnapshot,
        store: ManifestStore,
        userConfirmed: Bool
    ) throws -> LocalReleaseResult {
        do {
            try preflightVideoRawLayerRelease(snapshot: snapshot, userConfirmed: userConfirmed)

            let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
            let quarantineURL = quarantineURL(for: snapshot)
            let digest = try sha256File(originalURL)
            guard digest == snapshot.archivedFile.sha256 else {
                throw WeVaultError.fileSystem("Local SHA-256 changed before video raw layer release for \(snapshot.archivedFile.originalFilename)")
            }
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                let quarantineDigest = try sha256File(quarantineURL)
                guard quarantineDigest == snapshot.archivedFile.sha256 else {
                    throw WeVaultError.fileSystem("Quarantine target already exists with different SHA-256 at \(quarantineURL.path)")
                }
            } else {
                try FileManager.default.createDirectory(at: quarantineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }

            try store.logOperation("VIDEO_RAW_RELEASE_QUARANTINE_STARTED", detail: originalURL.path)
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                try FileManager.default.removeItem(at: originalURL)
                try store.logOperation("VIDEO_RAW_RELEASE_AUTO_RECOVERED_COPY_REMOVED", detail: originalURL.path)
            } else {
                try FileManager.default.moveItem(at: originalURL, to: quarantineURL)
            }

            try store.updateLocalReleaseState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .verified,
                localState: .quarantined,
                releasedAt: nil,
                quarantinePath: quarantineURL.path,
                placeholderPath: nil,
                placeholderCreatedAt: nil,
                placeholderFormat: nil,
                placeholderSHA256: nil,
                placeholderSize: nil
            )
            try store.updateFileStatus(path: snapshot.archivedFile.filePath, status: .releaseEligible)
            try store.logOperation("VIDEO_RAW_RELEASE_QUARANTINE_FINISHED", detail: quarantineURL.path)
            return LocalReleaseResult(originalURL: originalURL, quarantineURL: quarantineURL, sha256: digest)
        } catch {
            try? store.updateLocalReleaseState(
                bindingID: snapshot.binding.bindingID,
                archiveState: .releaseFailed,
                localState: .releaseFailed,
                releasedAt: snapshot.binding.releasedAt,
                quarantinePath: snapshot.binding.quarantinePath
            )
            try? store.updateFileStatus(path: snapshot.archivedFile.filePath, status: .releaseFailed)
            try? store.logOperation("VIDEO_RAW_RELEASE_FAILED", detail: "\(snapshot.archivedFile.filePath): \(error.localizedDescription)")
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

    private func preflightImageHighLayerRelease(snapshot: ArchivedFileSnapshot, userConfirmed: Bool) throws {
        guard userConfirmed else {
            throw WeVaultError.fileSystem("User confirmation is required before image high layer release")
        }
        guard snapshot.archivedFile.objectType == .imageHighLayer else {
            throw WeVaultError.fileSystem("Phase 6 only releases image high layers")
        }
        guard snapshot.object.verifyStatus == .verified else {
            throw WeVaultError.cloud("Cloud object must be verified before image high layer release")
        }
        guard snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored else {
            throw WeVaultError.cloud("Archive binding must be verified before image high layer release")
        }
        guard snapshot.binding.localState == .localPresent ||
              snapshot.binding.localState == .restored ||
              snapshot.binding.localState == .quarantined else {
            throw WeVaultError.fileSystem("Only local-present or auto-recovered image high layers can be quarantined")
        }
        let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw WeVaultError.fileSystem("Image high layer is missing at \(originalURL.path)")
        }
        guard let displayPath = snapshot.archivedFile.displayOrPlaybackPath, FileManager.default.fileExists(atPath: displayPath) else {
            throw WeVaultError.fileSystem("Image display layer must remain local before high layer release")
        }
        guard let bubbleOrThumbPath = snapshot.archivedFile.bubbleOrThumbPath, FileManager.default.fileExists(atPath: bubbleOrThumbPath) else {
            throw WeVaultError.fileSystem("Image bubble or thumb layer must remain local before high layer release")
        }
    }

    private func preflightVideoRawLayerRelease(snapshot: ArchivedFileSnapshot, userConfirmed: Bool) throws {
        guard userConfirmed else {
            throw WeVaultError.fileSystem("User confirmation is required before video raw layer release")
        }
        guard snapshot.archivedFile.objectType == .videoRawLayer else {
            throw WeVaultError.fileSystem("Phase 7 only releases video raw layers")
        }
        guard snapshot.object.verifyStatus == .verified else {
            throw WeVaultError.cloud("Cloud object must be verified before video raw layer release")
        }
        guard snapshot.binding.archiveState == .verified || snapshot.binding.archiveState == .restored else {
            throw WeVaultError.cloud("Archive binding must be verified before video raw layer release")
        }
        guard snapshot.binding.localState == .localPresent ||
              snapshot.binding.localState == .restored ||
              snapshot.binding.localState == .quarantined else {
            throw WeVaultError.fileSystem("Only local-present or auto-recovered video raw layers can be quarantined")
        }
        let originalURL = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw WeVaultError.fileSystem("Video raw layer is missing at \(originalURL.path)")
        }
        guard let playbackPath = snapshot.archivedFile.displayOrPlaybackPath, FileManager.default.fileExists(atPath: playbackPath) else {
            throw WeVaultError.fileSystem("Video playback layer must remain local before raw layer release")
        }
        guard let coverOrThumbPath = snapshot.archivedFile.bubbleOrThumbPath, FileManager.default.fileExists(atPath: coverOrThumbPath) else {
            throw WeVaultError.fileSystem("Video cover or thumb layer must remain local before raw layer release")
        }
    }

    private func quarantineURL(for snapshot: ArchivedFileSnapshot) -> URL {
        quarantineRoot
            .appendingPathComponent(snapshot.binding.bindingID, isDirectory: true)
            .appendingPathComponent(snapshot.archivedFile.originalFilename)
    }
}
