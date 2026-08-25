import Foundation
import SQLite3
import Testing
@testable import WeVaultCore

@Suite("WeChat scanner")
struct WeChatScannerTests {
    @Test("scans ordinary duplicates and media layer candidates")
    func scansDuplicatesAndCandidates() throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()

        let result = try WeChatScanner().scan(root: fixture.root)

        #expect(result.summary.ordinaryCount == 3)
        #expect(result.duplicateGroups.count == 1)
        #expect(result.summary.duplicateReclaimableBytes == 11)
        #expect(result.summary.imageHighCandidateCount == 1)
        #expect(result.summary.videoRawCandidateCount == 1)
        #expect(result.summary.videoRawDiscoveredCount == 2)
        #expect(result.summary.videoPlaybackDiscoveredCount == 1)

        let notArchivable = result.files.filter { $0.status == .notArchivable }
        #expect(notArchivable.contains { $0.filename == "lonely_h.dat" })
        #expect(notArchivable.contains { $0.filename == "solo_raw.mp4" })

        let duplicateFiles = result.files.filter { $0.duplicateGroupID != nil }
        #expect(duplicateFiles.count == 2)
        #expect(duplicateFiles.allSatisfy { $0.sha256 != nil })
    }

    @Test("hashes unique ordinary files at or above large threshold")
    func hashesLargeUniqueOrdinaryFiles() throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()

        let result = try WeChatScanner().scan(root: fixture.root, options: ScanOptions(largeFileThresholdBytes: 20))
        let largeUnique = try #require(result.files.first { $0.filename == "c.zip" })

        #expect(result.summary.largeOrdinaryCount == 1)
        #expect(largeUnique.sha256 != nil)
        #expect(largeUnique.status == .hashed)
        #expect(largeUnique.candidateReason == "普通大文件候选：达到当前阈值 20 B")
    }

    @Test("manifest can be saved repeatedly")
    func manifestCanBeSavedRepeatedly() throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)

        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)
        try store.save(scanResult: result)

        #expect(try fixture.countRows(table: "files") == result.files.count)
        #expect(try fixture.countRows(table: "families") == result.families.count)
        #expect(try fixture.countRows(table: "duplicate_groups") == result.duplicateGroups.count)
    }

    @Test("cloud upload deduplicates by sha and persists bindings")
    func cloudUploadDeduplicatesBySHA() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient()
        let service = CloudUploadService { _ in client }
        let snapshots = try await service.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        #expect(client.putKeys.count == 3)
        #expect(Set(client.putKeys).count == 3)
        #expect(try fixture.countRows(table: "cloud_objects") == 3)
        #expect(try fixture.countRows(table: "archive_bindings") == 4)
        #expect(try fixture.countRows(table: "archived_files") == 4)
        #expect(snapshots.values.filter { $0.object.verifyStatus == .verified }.count == 4)
        #expect(client.putKeys.allSatisfy { !$0.contains(".pdf") && !$0.contains(".dat") && !$0.contains(".mp4") })

        let archived = try store.archivedFileSnapshots()
        let duplicateArchives = archived.values.filter { $0.archivedFile.sha256 == result.duplicateGroups[0].sha256 }
        #expect(duplicateArchives.count == 2)
        #expect(duplicateArchives.map { $0.object.cloudObjectID }.uniqued().count == 1)
        #expect(duplicateArchives.map { $0.archivedFile.filePath }.uniqued().count == 2)
    }

    @Test("cloud upload records verify failure on remote size mismatch")
    func cloudUploadRecordsVerifyFailure() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient(headSizeDelta: 1)
        let service = CloudUploadService { _ in client }
        _ = try await service.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        #expect(try fixture.countRows(table: "cloud_objects") == 3)
        #expect(try fixture.countRows(table: "archive_bindings") == 4)
        #expect(try fixture.countRows(table: "archived_files") == 4)
        #expect(try fixture.countRows(table: "cloud_objects", whereClause: "verify_status = 'VERIFY_FAILED'") == 3)
        #expect(try fixture.countRows(table: "cloud_objects", whereClause: "verify_status = 'VERIFIED'") == 0)
    }

    @Test("cloud upload skips records without sha and not archivable media")
    func cloudUploadSkipsMissingSHAAndNotArchivable() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient()
        let service = CloudUploadService { _ in client }
        _ = try await service.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        let uploadedPaths = Set(client.uploadedLocalURLs.map(\.lastPathComponent))
        #expect(!uploadedPaths.contains("c.zip"))
        #expect(!uploadedPaths.contains("lonely_h.dat"))
        #expect(!uploadedPaths.contains("solo_raw.mp4"))
    }

    @Test("cloud upload includes unique ordinary files at large threshold")
    func cloudUploadIncludesLargeUniqueOrdinaryFiles() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root, options: ScanOptions(largeFileThresholdBytes: 20))
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient()
        _ = try await CloudUploadService { _ in client }.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        let uploadedPaths = Set(client.uploadedLocalURLs.map(\.lastPathComponent))
        #expect(uploadedPaths.contains("c.zip"))
        #expect(try fixture.countRows(table: "archived_files", whereClause: "original_filename = 'c.zip'") == 1)

        let archive = try #require(try store.archivedFileSnapshots().values.first { $0.archivedFile.originalFilename == "c.zip" })
        let restored = try await CloudRestoreService { _ in client }.restore(
            snapshot: archive,
            destination: .directory(fixture.restoreRoot),
            config: fixture.storageConfig,
            store: store
        )
        #expect(restored.destinationURL.lastPathComponent == "c.zip")
        #expect(try sha256File(restored.destinationURL) == archive.archivedFile.sha256)
    }

    @Test("manifest scan refresh preserves cloud archive records")
    func manifestScanRefreshPreservesCloudRecords() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let service = CloudUploadService { _ in MockObjectStorageClient() }
        _ = try await service.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)
        try store.save(scanResult: result)

        #expect(try fixture.countRows(table: "cloud_objects") == 3)
        #expect(try fixture.countRows(table: "archive_bindings") == 4)
        #expect(try fixture.countRows(table: "archived_files") == 4)
    }

    @Test("archived files remain queryable after local file disappears and scan refreshes")
    func archivedFilesRemainAfterLocalFileDisappears() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let service = CloudUploadService { _ in MockObjectStorageClient() }
        _ = try await service.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        let removedPath = try #require(result.files.first { $0.filename == "a.pdf" }?.path)
        try FileManager.default.removeItem(atPath: removedPath)
        let refreshed = try WeChatScanner().scan(root: fixture.root)
        try store.save(scanResult: refreshed)

        #expect(!refreshed.files.contains { $0.path == removedPath })
        #expect(try fixture.countRows(table: "files", whereClause: "path = '\(removedPath)'") == 0)
        #expect(try fixture.countRows(table: "cloud_objects") == 3)
        #expect(try fixture.countRows(table: "archive_bindings") == 4)
        #expect(try fixture.countRows(table: "archived_files") == 4)

        let archived = try store.archivedFileSnapshots()
        let removedArchive = archived[removedPath]
        #expect(removedArchive?.archivedFile.originalFilename == "a.pdf")
        #expect(removedArchive?.archivedFile.objectType == .ordinaryFile)
        #expect(removedArchive?.archivedFile.sha256 == result.duplicateGroups[0].sha256)
        #expect(removedArchive?.binding.localState == .localPresent)
        #expect(removedArchive?.object.verifyStatus == .verified)
    }

    @Test("cloud restore downloads verified object and checks sha")
    func cloudRestoreDownloadsVerifiedObject() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient()
        let uploadService = CloudUploadService { _ in client }
        _ = try await uploadService.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        let archived = try store.archivedFileSnapshots()
        let source = try #require(archived.values.first { $0.archivedFile.originalFilename == "photo_h.dat" })
        let restored = try await CloudRestoreService { _ in client }.restore(
            snapshot: source,
            destination: .directory(fixture.restoreRoot),
            config: fixture.storageConfig,
            store: store
        )

        #expect(restored.destinationURL.lastPathComponent == "photo_h.dat")
        #expect(restored.sha256 == source.archivedFile.sha256)
        #expect(try sha256File(restored.destinationURL) == source.archivedFile.sha256)
        #expect(try fixture.countRows(table: "archive_bindings", whereClause: "archive_state = 'RESTORED'") == 1)
        #expect(try fixture.countRows(table: "operations", whereClause: "event = 'RESTORE_FINISHED'") == 1)
    }

    @Test("cloud restore records failure when downloaded sha mismatches")
    func cloudRestoreRecordsHashFailure() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient(downloadOverride: Data("wrong-content".utf8))
        let uploadService = CloudUploadService { _ in client }
        _ = try await uploadService.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        let source = try #require(try store.archivedFileSnapshots().values.first)
        await #expect(throws: WeVaultError.self) {
            _ = try await CloudRestoreService { _ in client }.restore(
                snapshot: source,
                destination: .directory(fixture.restoreRoot),
                config: fixture.storageConfig,
                store: store
            )
        }

        #expect(try fixture.countRows(table: "archive_bindings", whereClause: "archive_state = 'RESTORE_FAILED'") == 1)
        #expect(try fixture.countRows(table: "operations", whereClause: "event = 'RESTORE_FAILED'") == 1)
    }

    @Test("cloud restore rejects unverified archive objects")
    func cloudRestoreRejectsUnverifiedObjects() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient(headSizeDelta: 1)
        let uploadService = CloudUploadService { _ in client }
        _ = try await uploadService.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        let source = try #require(try store.archivedFileSnapshots().values.first)
        await #expect(throws: WeVaultError.self) {
            _ = try await CloudRestoreService { _ in client }.restore(
                snapshot: source,
                destination: .directory(fixture.restoreRoot),
                config: fixture.storageConfig,
                store: store
            )
        }

        #expect(client.downloadedKeys.isEmpty)
        #expect(try fixture.countRows(table: "operations", whereClause: "event = 'RESTORE_STARTED'") == 0)
    }

    @Test("cloud restore duplicate bindings use their own filenames")
    func cloudRestoreDuplicateBindingsUseOwnFilenames() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient()
        _ = try await CloudUploadService { _ in client }.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)

        let duplicates = try store.archivedFileSnapshots().values
            .filter { $0.archivedFile.sha256 == result.duplicateGroups[0].sha256 }
            .sorted { $0.archivedFile.originalFilename < $1.archivedFile.originalFilename }
        #expect(duplicates.count == 2)

        let restoreService = CloudRestoreService { _ in client }
        let first = try await restoreService.restore(snapshot: duplicates[0], destination: .directory(fixture.restoreRoot), config: fixture.storageConfig, store: store)
        let second = try await restoreService.restore(snapshot: duplicates[1], destination: .directory(fixture.restoreRoot), config: fixture.storageConfig, store: store)

        #expect(Set([first.destinationURL.lastPathComponent, second.destinationURL.lastPathComponent]) == Set(["a.pdf", "b.pdf"]))
        let firstSHA = try sha256File(first.destinationURL)
        let secondSHA = try sha256File(second.destinationURL)
        #expect(firstSHA == secondSHA)
        #expect(client.downloadedKeys.count == 2)
    }

    @Test("cloud restore media layers keep family targets")
    func cloudRestoreMediaLayersKeepFamilyTargets() async throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)
        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)

        let client = MockObjectStorageClient()
        _ = try await CloudUploadService { _ in client }.upload(files: result.files, families: result.families, config: fixture.storageConfig, store: store)
        let archived = try store.archivedFileSnapshots()
        let image = try #require(archived.values.first { $0.archivedFile.objectType == .imageHighLayer })
        let video = try #require(archived.values.first { $0.archivedFile.objectType == .videoRawLayer })

        #expect(image.archivedFile.displayOrPlaybackPath?.hasSuffix("photo.dat") == true)
        #expect(video.archivedFile.displayOrPlaybackPath?.hasSuffix("clip.mp4") == true)

        try FileManager.default.removeItem(atPath: image.archivedFile.filePath)
        try FileManager.default.removeItem(atPath: video.archivedFile.filePath)

        let restoreService = CloudRestoreService { _ in client }
        let restoredImage = try await restoreService.restore(snapshot: image, destination: .originalPath, config: fixture.storageConfig, store: store)
        let restoredVideo = try await restoreService.restore(snapshot: video, destination: .originalPath, config: fixture.storageConfig, store: store)

        #expect(restoredImage.destinationURL.path == image.archivedFile.filePath)
        #expect(restoredImage.destinationURL.lastPathComponent == "photo_h.dat")
        #expect(restoredVideo.destinationURL.path == video.archivedFile.filePath)
        #expect(restoredVideo.destinationURL.lastPathComponent == "clip_raw.mp4")
        #expect(try sha256File(restoredImage.destinationURL) == image.archivedFile.sha256)
        #expect(try sha256File(restoredVideo.destinationURL) == video.archivedFile.sha256)
    }
}

private struct Fixture {
    let temp: URL
    let root: URL
    let account: URL
    let restoreRoot: URL

    init() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("WeVaultTests-\(UUID().uuidString)", isDirectory: true)
        root = temp.appendingPathComponent("xwechat_files", isDirectory: true)
        account = root.appendingPathComponent("wxid_demo", isDirectory: true)
        restoreRoot = temp.appendingPathComponent("restores", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var storageConfig: S3CompatibleStorageConfig {
        S3CompatibleStorageConfig(
            provider: "MockS3",
            endpoint: "https://example.invalid",
            bucket: "wevault-tests",
            region: "auto",
            accessKeyID: "test-access-key",
            secretAccessKey: "test-secret-key",
            pathStyle: true
        )
    }

    func writeWeChatTree() throws {
        try write("duplicate-a", to: account.appendingPathComponent("msg/file/2026-01/a.pdf"))
        try write("duplicate-a", to: account.appendingPathComponent("msg/file/2026-02/b.pdf"))
        try write("unique-file-with-different-size", to: account.appendingPathComponent("msg/file/2026-02/c.zip"))

        try write("normal", to: account.appendingPathComponent("msg/attach/res1/Img/2026-01/photo.dat"))
        try write("high-resolution", to: account.appendingPathComponent("msg/attach/res1/Img/2026-01/photo_h.dat"))
        try write("high-only", to: account.appendingPathComponent("msg/attach/res2/Img/2026-01/lonely_h.dat"))

        try write("play", to: account.appendingPathComponent("msg/video/2026-01/clip.mp4"))
        try write("raw-video-larger", to: account.appendingPathComponent("msg/video/2026-01/clip_raw.mp4"))
        try write("thumb", to: account.appendingPathComponent("msg/video/2026-01/clip_thumb.jpg"))
        try write("cover", to: account.appendingPathComponent("msg/video/2026-01/clip.jpg"))
        try write("raw-only", to: account.appendingPathComponent("msg/video/2026-01/solo_raw.mp4"))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func countRows(table: String, whereClause: String? = nil) throws -> Int {
        var db: OpaquePointer?
        let path = temp.appendingPathComponent("archive.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw WeVaultError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(table)" + whereClause.map { " WHERE \($0)" }.orEmpty
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WeVaultError.sqlite("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WeVaultError.sqlite("count failed")
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
}

private final class MockObjectStorageClient: ObjectStorageClient, @unchecked Sendable {
    var putKeys: [String] = []
    var uploadedLocalURLs: [URL] = []
    var sizesByKey: [String: Int64] = [:]
    var dataByKey: [String: Data] = [:]
    var downloadedKeys: [String] = []
    let headSizeDelta: Int64
    let downloadOverride: Data?

    init(headSizeDelta: Int64 = 0, downloadOverride: Data? = nil) {
        self.headSizeDelta = headSizeDelta
        self.downloadOverride = downloadOverride
    }

    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws {
        putKeys.append(objectKey)
        uploadedLocalURLs.append(localURL)
        sizesByKey[objectKey] = sizeBytes
        dataByKey[objectKey] = try Data(contentsOf: localURL)
    }

    func headObject(objectKey: String) async throws -> StoredObjectHead {
        StoredObjectHead(sizeBytes: (sizesByKey[objectKey] ?? 0) + headSizeDelta)
    }

    func getObject(objectKey: String, destinationURL: URL) async throws {
        downloadedKeys.append(objectKey)
        guard let data = downloadOverride ?? dataByKey[objectKey] else {
            throw WeVaultError.cloud("missing mock object \(objectKey)")
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String {
        self ?? ""
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
