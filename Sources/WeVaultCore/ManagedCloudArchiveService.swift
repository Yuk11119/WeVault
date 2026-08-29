import Foundation

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
        let familyByPath = Dictionary(uniqueKeysWithValues: families.map { ($0.highOrRawPath, $0) })
        var completed: [String: (WeVaultObjectIndexEntry, WeVaultTemporaryCredentials?)] = [:]
        for file in files where file.sha256 != nil && file.status != .notArchivable {
            guard let sha = file.sha256 else { continue }
            do {
                let resolved: (WeVaultObjectIndexEntry, WeVaultTemporaryCredentials?)
                if let known = completed[sha] {
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
                try store.updateFileStatus(path: file.path, status: .verified)
                try store.logOperation("MANAGED_UPLOAD_VERIFIED", detail: resolved.0.objectId)
                await progress?(CloudUploadProgress(filePath: file.path, status: .verified))
            } catch {
                try? store.updateFileStatus(path: file.path, status: .uploadFailed)
                try? store.logOperation("MANAGED_UPLOAD_FAILED", detail: "\(file.path): \(error.localizedDescription)")
                await progress?(CloudUploadProgress(filePath: file.path, status: .uploadFailed, message: error.localizedDescription))
            }
        }
        return try store.cloudArchiveSnapshots()
    }

    public func restore(snapshot: ArchivedFileSnapshot, destination: RestoreDestination, api: WeVaultAPIClient, accessToken: String, deviceId: String, store: ManifestStore) async throws -> CloudRestoreResult {
        let authorization = try await api.downloadAuthorization(accessToken: accessToken, objectId: snapshot.object.cloudObjectID, deviceId: deviceId)
        try ManagedCloudContractPipeline.assertUsable(credentials: authorization.credentials)
        return try await CloudRestoreService().restore(snapshot: snapshot, destination: destination, client: STSObjectStorageClientFactory().makeClient(credentials: authorization.credentials), objectKey: authorization.credentials.objectKey, store: store)
    }
}
