import Foundation

public struct CloudUploadProgress: Sendable {
    public let filePath: String
    public let status: ArchiveStatus
    public let message: String?

    public init(filePath: String, status: ArchiveStatus, message: String? = nil) {
        self.filePath = filePath
        self.status = status
        self.message = message
    }
}

/// P2A intentionally exposes both cloud routes without changing the existing
/// automatic upload/release path.  The managed route is opt-in for contract
/// tests until the P2 product UI owns account sign-in and migration.
public enum CloudUploadProvider: String, Sendable {
    case selfConfiguredS3
    case managedWeVault
}

public final class CloudUploadService: Sendable {
    public typealias ClientFactory = @Sendable (S3CompatibleStorageConfig) -> any ObjectStorageClient

    private let clientFactory: ClientFactory

    public init(clientFactory: @escaping ClientFactory = { S3CompatibleObjectStorageClient(config: $0) }) {
        self.clientFactory = clientFactory
    }

    /// Managed-cloud contract entry point.  It does not receive a ManifestStore
    /// and therefore cannot create a verified binding or invoke any local
    /// release/quarantine/tombstone behavior.  The existing `upload` method
    /// remains the user-configured S3 path used by the current app UI.
    public func uploadManagedContract(
        api: WeVaultAPIClient,
        accessToken: String,
        deviceId: String,
        fileURL: URL,
        storageFactory: any ManagedWeVaultStorageClientFactory = STSObjectStorageClientFactory()
    ) async throws -> ManagedCloudUploadOutcome {
        try await ManagedCloudContractPipeline.upload(
            api: api,
            accessToken: accessToken,
            deviceId: deviceId,
            fileURL: fileURL,
            storageFactory: storageFactory
        )
    }

    public func upload(
        files: [FileRecord],
        families: [FamilyRecord] = [],
        config: S3CompatibleStorageConfig,
        store: ManifestStore,
        includeAllSnapshots: Bool = true,
        progress: (@Sendable (CloudUploadProgress) async -> Void)? = nil
    ) async throws -> [String: CloudArchiveSnapshot] {
        let client = clientFactory(config)
        let familiesByArchivePath = Dictionary(uniqueKeysWithValues: families.map { ($0.highOrRawPath, $0) })
        let uploadable = files.filter { file in
            file.sha256 != nil && file.status != .notArchivable
        }
        var uploadedBySHA: [String: CloudObject] = [:]

        for file in uploadable {
            try Task.checkCancellation()
            guard let digest = file.sha256 else { continue }
            let objectKey = Self.objectKey(forSHA256: digest)
            let existing = try store.verifiedCloudObject(
                sha256: digest,
                provider: config.provider,
                bucket: config.bucket,
                objectKey: objectKey
            )
            let cloudObject: CloudObject
            if let known = uploadedBySHA[digest] ?? existing {
                cloudObject = known
            } else {
                try store.updateFileStatus(path: file.path, status: .uploading)
                try store.logOperation("UPLOAD_STARTED", detail: file.path)
                await progress?(CloudUploadProgress(filePath: file.path, status: .uploading))

                do {
                    try await client.putObject(localURL: URL(fileURLWithPath: file.path), objectKey: objectKey, sha256: digest, sizeBytes: file.sizeBytes)
                    try store.updateFileStatus(path: file.path, status: .uploaded)
                    try store.logOperation("UPLOAD_FINISHED", detail: objectKey)

                    if let verifyFailure = try await Self.verifyRemoteObject(client: client, objectKey: objectKey, sha256: digest, sizeBytes: file.sizeBytes) {
                        let failed = Self.cloudObject(
                            sha256: digest,
                            sizeBytes: file.sizeBytes,
                            config: config,
                            objectKey: objectKey,
                            verifyStatus: .verifyFailed,
                            verifiedAt: nil
                        )
                        let binding = Self.binding(filePath: file.path, cloudObjectID: failed.cloudObjectID, archiveState: .verifyFailed)
                        try store.saveCloudObject(failed, binding: binding, archivedFile: Self.archivedFile(file: file, family: familiesByArchivePath[file.path]))
                        try store.updateFileStatus(path: file.path, status: .verifyFailed)
                        try store.logOperation("VERIFY_FAILED", detail: "\(objectKey): \(verifyFailure)")
                        await progress?(CloudUploadProgress(filePath: file.path, status: .verifyFailed, message: verifyFailure))
                        continue
                    }

                    cloudObject = Self.cloudObject(
                        sha256: digest,
                        sizeBytes: file.sizeBytes,
                        config: config,
                        objectKey: objectKey,
                        verifyStatus: .verified,
                        verifiedAt: Date()
                    )
                    uploadedBySHA[digest] = cloudObject
                    try store.logOperation("VERIFY_FINISHED", detail: objectKey)
                } catch {
                    if AutomationFailure.isFatal(error) { throw error }
                    try store.updateFileStatus(path: file.path, status: .uploadFailed)
                    try store.logOperation("UPLOAD_FAILED", detail: "\(file.path): \(error.localizedDescription)")
                    await progress?(CloudUploadProgress(filePath: file.path, status: .uploadFailed, message: error.localizedDescription))
                    continue
                }
            }

            let binding = Self.binding(filePath: file.path, cloudObjectID: cloudObject.cloudObjectID, archiveState: .verified)
            try store.saveCloudObject(cloudObject, binding: binding, archivedFile: Self.archivedFile(file: file, family: familiesByArchivePath[file.path]))
            try store.updateFileStatus(path: file.path, status: .verified)
            await progress?(CloudUploadProgress(filePath: file.path, status: .verified))
        }

        return includeAllSnapshots ? try store.cloudArchiveSnapshots() : [:]
    }

    public static func objectKey(forSHA256 sha256: String) -> String {
        let first = String(sha256.prefix(2))
        let secondStart = sha256.index(sha256.startIndex, offsetBy: min(2, sha256.count))
        let secondEnd = sha256.index(sha256.startIndex, offsetBy: min(4, sha256.count))
        let second = String(sha256[secondStart..<secondEnd])
        return "objects/sha256/\(first)/\(second)/\(sha256)"
    }

    private static func verifyRemoteObject(client: any ObjectStorageClient, objectKey: String, sha256: String, sizeBytes: Int64) async throws -> String? {
        let head = try await client.headObject(objectKey: objectKey)
        guard head.sizeBytes == sizeBytes else {
            return "remote size \(head.sizeBytes), local size \(sizeBytes)"
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wevault-verify-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        try await client.getObject(objectKey: objectKey, destinationURL: temporaryURL)
        let downloadedStat = try fileStat(temporaryURL.path)
        guard downloadedStat.size == sizeBytes else {
            return "downloaded size \(downloadedStat.size), local size \(sizeBytes)"
        }
        let downloadedSHA = try sha256File(temporaryURL)
        guard downloadedSHA == sha256 else {
            return "downloaded SHA-256 \(downloadedSHA), local SHA-256 \(sha256)"
        }
        return nil
    }

    private static func cloudObject(
        sha256: String,
        sizeBytes: Int64,
        config: S3CompatibleStorageConfig,
        objectKey: String,
        verifyStatus: CloudVerifyStatus,
        verifiedAt: Date?
    ) -> CloudObject {
        CloudObject(
            cloudObjectID: "cloud-\(sha256Hex([config.provider, config.bucket, objectKey].joined(separator: "|")).prefix(32))",
            sha256: sha256,
            sizeBytes: sizeBytes,
            storageProvider: config.provider,
            bucketOrContainer: config.bucket,
            objectKey: objectKey,
            uploadedAt: Date(),
            verifiedAt: verifiedAt,
            verifyStatus: verifyStatus,
            refCount: 0
        )
    }

    private static func binding(filePath: String, cloudObjectID: String, archiveState: ArchiveBindingState) -> ArchiveBinding {
        ArchiveBinding(
            bindingID: "binding-\(sha256Hex([filePath, cloudObjectID].joined(separator: "|")).prefix(32))",
            filePath: filePath,
            cloudObjectID: cloudObjectID,
            archiveState: archiveState,
            localState: .localPresent
        )
    }

    private static func archivedFile(file: FileRecord, family: FamilyRecord?) -> ArchivedFile {
        let now = Date()
        return ArchivedFile(
            filePath: file.path,
            objectType: file.objectType,
            originalFilename: file.filename,
            relativePath: file.relativePath,
            accountHash: file.accountHash,
            accountName: file.accountName,
            month: file.month,
            sizeBytes: file.sizeBytes,
            sha256: file.sha256 ?? "",
            mtime: file.mtime,
            familyID: family?.id,
            displayOrPlaybackPath: family?.displayOrPlaybackPath,
            bubbleOrThumbPath: family?.bubbleOrThumbPath,
            archivedAt: now,
            updatedAt: now
        )
    }
}
