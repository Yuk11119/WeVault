import Foundation

public struct ManagedCloudUploadFailure: Equatable, Sendable {
    public let filePath: String
    public let reason: String

    public init(filePath: String, reason: String) {
        self.filePath = filePath
        self.reason = reason
    }
}

public struct ManagedCloudUploadReport: Sendable {
    public let snapshots: [String: CloudArchiveSnapshot]
    public let attemptedCount: Int
    public let verifiedCount: Int
    public let failures: [ManagedCloudUploadFailure]

    public init(snapshots: [String: CloudArchiveSnapshot], attemptedCount: Int, verifiedCount: Int, failures: [ManagedCloudUploadFailure]) {
        self.snapshots = snapshots
        self.attemptedCount = attemptedCount
        self.verifiedCount = verifiedCount
        self.failures = failures
    }
}

/// P2's managed-cloud path persists a local archive binding only after the
/// backend returned VERIFIED. It never performs release or deletion itself.
public final class ManagedCloudArchiveService: Sendable {
    public init() {}

    public func upload(
        files: [FileRecord],
        families: [FamilyRecord] = [],
        api: WeVaultAPIClient,
        accessToken: String,
        deviceId: String,
        store: ManifestStore,
        progress: (@Sendable (CloudUploadProgress) async -> Void)? = nil
    ) async throws -> [String: CloudArchiveSnapshot] {
        try await uploadWithReport(files: files, families: families, api: api, accessToken: accessToken, deviceId: deviceId, store: store, progress: progress).snapshots
    }

    /// Returns counts for this invocation only. The compatibility `upload` method
    /// continues to return the complete manifest snapshot collection.
    public func uploadWithReport(
        files: [FileRecord],
        families: [FamilyRecord] = [],
        api: WeVaultAPIClient,
        accessToken: String,
        deviceId: String,
        store: ManifestStore,
        includeAllSnapshots: Bool = true,
        progress: (@Sendable (CloudUploadProgress) async -> Void)? = nil
    ) async throws -> ManagedCloudUploadReport {
        let familyByPath = Dictionary(uniqueKeysWithValues: families.map { ($0.highOrRawPath, $0) })
        var completed: [String: (WeVaultObjectIndexEntry, WeVaultTemporaryCredentials?)] = [:]
        let candidates = files.filter { $0.sha256 != nil && $0.status != .notArchivable }
        var verifiedCount = 0
        var failures: [ManagedCloudUploadFailure] = []
        for file in candidates {
            try Task.checkCancellation()
            if let existing = try store.archivedSnapshot(path: file.path), existing.archivedFile.sha256 == file.sha256, existing.archivedFile.sizeBytes == file.sizeBytes, existing.object.verifyStatus == .verified, existing.object.storageProvider == "WeVault Managed Cloud",
               try store.workGet(String.self, scope: "managed-binding-owner", key: existing.binding.bindingID) == deviceId {
                verifiedCount += 1
                continue
            }
            guard let sha = file.sha256 else { continue }
            do {
                let resolved: (WeVaultObjectIndexEntry, WeVaultTemporaryCredentials?)
                if let cached = try store.workGet(CloudObject.self, scope: "managed-verified-cache", key: deviceId + "|" + sha), cached.sizeBytes == file.sizeBytes {
                    resolved = (WeVaultObjectIndexEntry(objectId: cached.cloudObjectID, sha256: cached.sha256, sizeBytes: cached.sizeBytes, verifiedAt: cached.verifiedAt ?? Date()), nil)
                } else if let known = completed[sha] {
                    resolved = known
                } else {
                    let outcome = try await ManagedCloudContractPipeline.upload(api: api, accessToken: accessToken, deviceId: deviceId, fileURL: URL(fileURLWithPath: file.path))
                    switch outcome {
                    case .fallbackFound(let objects):
                        guard let object = objects.first(where: { $0.sha256 == sha }) else { throw WeVaultError.cloud("Managed cloud fallback did not return the requested SHA-256") }
                        resolved = (object, nil)
                    case .verified(let authorization, let verification):
                        resolved = (WeVaultObjectIndexEntry(objectId: verification.objectId, sha256: verification.sha256, sizeBytes: verification.sizeBytes, verifiedAt: verification.verifiedAt), authorization.credentials)
                    }
                    completed[sha] = resolved
                }
                guard resolved.0.sha256 == sha, resolved.0.sizeBytes == file.sizeBytes else { throw WeVaultError.cloud("Managed cloud verified object does not match local candidate") }
                let cloud = CloudObject(cloudObjectID: resolved.0.objectId, sha256: sha, sizeBytes: file.sizeBytes, storageProvider: "WeVault Managed Cloud", bucketOrContainer: resolved.1?.bucket ?? "managed", objectKey: resolved.1?.objectKey ?? "managed://\(resolved.0.objectId)", uploadedAt: Date(), verifiedAt: resolved.0.verifiedAt, verifyStatus: .verified, refCount: 0)
                let binding = ArchiveBinding(bindingID: "binding-\(sha256Hex("\(file.path)|\(resolved.0.objectId)"))", filePath: file.path, cloudObjectID: resolved.0.objectId, archiveState: .verified, localState: .localPresent)
                let archived = ArchivedFile(filePath: file.path, objectType: file.objectType, originalFilename: file.filename, relativePath: file.relativePath, accountHash: file.accountHash, accountName: file.accountName, month: file.month, sizeBytes: file.sizeBytes, sha256: sha, mtime: file.mtime, familyID: familyByPath[file.path]?.id, displayOrPlaybackPath: familyByPath[file.path]?.displayOrPlaybackPath, bubbleOrThumbPath: familyByPath[file.path]?.bubbleOrThumbPath, archivedAt: Date(), updatedAt: Date())
                try store.saveCloudObject(cloud, binding: binding, archivedFile: archived)
                try store.workPut(scope: "managed-verified-cache", key: deviceId + "|" + sha, value: cloud)
                try store.workPut(scope: "managed-binding-owner", key: binding.bindingID, value: deviceId)
                try store.updateFileStatus(path: file.path, status: .verified)
                try store.logOperation("MANAGED_UPLOAD_VERIFIED", detail: resolved.0.objectId)
                verifiedCount += 1
                await progress?(CloudUploadProgress(filePath: file.path, status: .verified))
            } catch {
                if AutomationFailure.isFatal(error) { throw error }
                try? store.updateFileStatus(path: file.path, status: .uploadFailed)
                if let diagnostic = Self.safeStorageDiagnostic(error.localizedDescription) {
                    try? store.logDiagnosticOperation("MANAGED_UPLOAD_FAILED", diagnostic: diagnostic)
                } else {
                    try? store.logOperation("MANAGED_UPLOAD_FAILED", detail: "\(file.path): \(error.localizedDescription)")
                }
                failures.append(ManagedCloudUploadFailure(filePath: file.path, reason: Self.safeStorageDiagnostic(error.localizedDescription) ?? "上传或服务端校验失败"))
                await progress?(CloudUploadProgress(filePath: file.path, status: .uploadFailed, message: error.localizedDescription))
            }
        }
        return ManagedCloudUploadReport(
            snapshots: includeAllSnapshots ? try store.cloudArchiveSnapshots() : [:],
            attemptedCount: candidates.count,
            verifiedCount: verifiedCount,
            failures: failures
        )
    }

    public func isAuthorizedArchive(_ snapshot: ArchivedFileSnapshot, api: WeVaultAPIClient, accessToken: String, deviceID: String, store: ManifestStore, storageFactory: any ManagedWeVaultStorageClientFactory = STSObjectStorageClientFactory()) async throws -> Bool {
        let matches = try await api.fallback(accessToken: accessToken, deviceId: deviceID, sha256: snapshot.object.sha256)
        guard matches.contains(where: { $0.objectId == snapshot.object.cloudObjectID && $0.sha256 == snapshot.archivedFile.sha256 && $0.sizeBytes == snapshot.archivedFile.sizeBytes }) else { return false }
        let authorization = try await api.downloadAuthorization(accessToken: accessToken, objectId: snapshot.object.cloudObjectID, deviceId: deviceID)
        try ManagedCloudContractPipeline.assertUsable(credentials: authorization.credentials)
        let head = try await storageFactory.makeClient(credentials: authorization.credentials).headObject(objectKey: authorization.credentials.objectKey)
        guard head.sizeBytes == snapshot.archivedFile.sizeBytes,
              head.metadata["sha256"] == snapshot.archivedFile.sha256 else {
            throw WeVaultError.cloud("释放前云端对象不可验证；保留本地副本")
        }
        try store.workPut(scope: "managed-binding-owner", key: snapshot.binding.bindingID, value: deviceID)
        return true
    }

    private static func safeStorageDiagnostic(_ description: String) -> String? {
        let pattern = "HTTP [0-9]{3}( [A-Za-z0-9_-]{1,80})?( request=[A-Za-z0-9_-]{1,120})?"
        guard let range = description.range(of: pattern, options: .regularExpression) else { return nil }
        return String(description[range])
    }

    public func restore(snapshot: ArchivedFileSnapshot, destination: RestoreDestination, api: WeVaultAPIClient, accessToken: String, deviceId: String, store: ManifestStore) async throws -> CloudRestoreResult {
        let authorization = try await api.downloadAuthorization(accessToken: accessToken, objectId: snapshot.object.cloudObjectID, deviceId: deviceId)
        try ManagedCloudContractPipeline.assertUsable(credentials: authorization.credentials)
        return try await CloudRestoreService().restore(snapshot: snapshot, destination: destination, client: STSObjectStorageClientFactory().makeClient(credentials: authorization.credentials), objectKey: authorization.credentials.objectKey, store: store)
    }
}
