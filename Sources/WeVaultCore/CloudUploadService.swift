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

public final class CloudUploadService: Sendable {
    public typealias ClientFactory = @Sendable (S3CompatibleStorageConfig) -> any ObjectStorageClient

    private let clientFactory: ClientFactory

    public init(clientFactory: @escaping ClientFactory = { S3CompatibleObjectStorageClient(config: $0) }) {
        self.clientFactory = clientFactory
    }

    public func upload(
        files: [FileRecord],
        families: [FamilyRecord] = [],
        config: S3CompatibleStorageConfig,
        store: ManifestStore,
        progress: (@Sendable (CloudUploadProgress) async -> Void)? = nil
    ) async throws -> [String: CloudArchiveSnapshot] {
        let client = clientFactory(config)
        let familiesByArchivePath = Dictionary(uniqueKeysWithValues: families.map { ($0.highOrRawPath, $0) })
        let uploadable = files.filter { file in
            file.sha256 != nil && file.status != .notArchivable
        }
        var uploadedBySHA: [String: CloudObject] = [:]

        for file in uploadable {
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

                    let head = try await client.headObject(objectKey: objectKey)
                    guard head.sizeBytes == file.sizeBytes else {
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
                        try store.logOperation("VERIFY_FAILED", detail: "\(objectKey): remote size \(head.sizeBytes), local size \(file.sizeBytes)")
                        await progress?(CloudUploadProgress(filePath: file.path, status: .verifyFailed, message: "remote size \(head.sizeBytes), local size \(file.sizeBytes)"))
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

        return try store.cloudArchiveSnapshots()
    }

    public static func objectKey(forSHA256 sha256: String) -> String {
        let first = String(sha256.prefix(2))
        let secondStart = sha256.index(sha256.startIndex, offsetBy: min(2, sha256.count))
        let secondEnd = sha256.index(sha256.startIndex, offsetBy: min(4, sha256.count))
        let second = String(sha256[secondStart..<secondEnd])
        return "objects/sha256/\(first)/\(second)/\(sha256)"
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
