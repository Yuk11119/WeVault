import Foundation
import Testing
import PDFKit
@testable import WeVaultCore

@Suite("P5 restore center")
struct RestoreCenterTests {
    @Test("links accept existing IDs and reject extra authority or path data")
    func links() throws {
        for length in [32, 64] {
            let id = "binding-" + String(repeating: "a", count: length)
            let link = try RestoreLink(bindingID: id)
            #expect(try RestoreLink(url: link.url).bindingID == id)
            #expect(try RestoreLink(url: URL(string: link.url.absoluteString + "?OR=PowerPoint")!).url == link.url)
            for suffix in ["/", "/extra", "?path=/tmp/file", "#fragment", "?", "?OR=PowerPoint&OR=PowerPoint", "?OR=Word", "?OR=PowerPoint&path=x", "?%4fR=PowerPoint"] {
                #expect(throws: WeVaultError.self) { try RestoreLink(url: URL(string: link.url.absoluteString + suffix)!) }
            }
        }
        for raw in ["https://restore/binding-a", "wevault://delete/binding-a", "wevault://user@restore/binding-a", "wevault://restore:80/binding-a", "wevault://restore/../x", "wevault://restore/%62inding-" + String(repeating: "a", count: 32)] {
            #expect(throws: WeVaultError.self) { try RestoreLink(url: URL(string: raw)!) }
        }
    }

    @Test("encrypted ID lookup and stable pages survive local source and scan removal")
    func lookup() throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let original = try f.snapshot()
        for i in 0..<53 { _ = try f.snapshot(name: "file-\(i).txt", index: i + 1) }
        #expect(try f.store.archivedFilePage(limit: 50).count == 50)
        #expect(try f.store.archivedFilePage(limit: 50, offset: 50).count == 4)
        let ids = try f.store.archivedFilePage(limit: 50).map(\.binding.bindingID)
        #expect(try f.store.archivedFilePage(limit: 50).map(\.binding.bindingID) == ids)
        try FileManager.default.removeItem(atPath: original.archivedFile.filePath)
        let root = f.root.appendingPathComponent("wxid_empty")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try f.store.save(scanResult: WeChatScanner().scan(root: root))
        #expect(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID)?.archivedFile.originalFilename == "sample.txt")
        #expect(try f.store.archivedFileSnapshot(bindingID: "unknown") == nil)
        #expect(throws: WeVaultError.self) { try ManifestStore(databaseURL: f.root.appendingPathComponent("archive.sqlite"), keyProvider: InMemoryManifestKeyProvider(key: Data(repeating: 9, count: 32))) }
    }

    @Test("failed download keeps tombstone and retry works using refreshed state")
    func failureRetry() async throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let snapshot = try f.quarantined()
        let before = try Data(contentsOf: URL(fileURLWithPath: snapshot.archivedFile.filePath))
        let failedClient = RestoreClient(data: nil)
        await #expect(throws: WeVaultError.self) { try await f.restore(snapshot, client: failedClient) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: snapshot.archivedFile.filePath)) == before)
        let failed = try #require(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
        #expect(failed.binding.archiveState == .restoreFailed)
        #expect(failed.binding.localState == .tombstoned)
        _ = try await f.restore(failed)
        let done = try #require(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
        #expect(done.binding.localState == .restored)
        #expect(done.binding.placeholderPath == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: snapshot.archivedFile.filePath)) == f.bytes)
    }

    @Test("bad hash and modified tombstones never overwrite local data")
    func badContent() async throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let snapshot = try f.quarantined()
        let url = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        let placeholder = try Data(contentsOf: url)
        await #expect(throws: WeVaultError.self) { try await f.restore(snapshot, client: RestoreClient(data: Data(repeating: 0, count: f.bytes.count))) }
        #expect(try Data(contentsOf: url) == placeholder)
        try Data("user edited".utf8).write(to: url)
        await #expect(throws: WeVaultError.self) { try await f.restore(snapshot) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "user edited")
    }

    @Test("download copy preserves tombstone and quarantine with collision-safe filenames")
    func downloads() async throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let snapshot = try f.quarantined()
        let directory = f.root.appendingPathComponent("downloads")
        let a = try await f.restore(snapshot, destination: .directory(directory))
        let b = try await f.restore(snapshot, destination: .directory(directory))
        #expect(a.destinationURL != b.destinationURL)
        #expect(try Data(contentsOf: a.destinationURL) == f.bytes)
        let refreshed = try #require(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
        #expect(refreshed.binding.localState == .tombstoned)
        #expect(refreshed.binding.placeholderSHA256 == snapshot.binding.placeholderSHA256)
        #expect(FileManager.default.fileExists(atPath: snapshot.binding.quarantinePath!))
    }

    @Test("target changed during download is preserved")
    func changingTarget() async throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let snapshot = try f.quarantined()
        let path = snapshot.archivedFile.filePath
        let client = RestoreClient(data: f.bytes) { try Data("new user file".utf8).write(to: URL(fileURLWithPath: path)) }
        await #expect(throws: WeVaultError.self) { try await f.restore(snapshot, client: client) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new user file")
    }

    @Test("media retained layers checked before and after download")
    func retainedLayers() async throws {
        for type in [ArchiveObjectType.imageHighLayer, .videoRawLayer] {
            let f = try RestoreFixture(); defer { f.remove() }
            let snapshot = try f.snapshot(type: type)
            try FileManager.default.removeItem(atPath: snapshot.archivedFile.filePath)
            let display = snapshot.archivedFile.displayOrPlaybackPath!
            let client = RestoreClient(data: f.bytes) { try FileManager.default.removeItem(atPath: display) }
            await #expect(throws: WeVaultError.self) { try await f.restore(snapshot, client: client) }
            #expect(!FileManager.default.fileExists(atPath: snapshot.archivedFile.filePath))
            await #expect(throws: WeVaultError.self) { try await f.restore(snapshot) }
            _ = try await f.restore(snapshot, destination: .directory(f.root.appendingPathComponent("downloads")))
        }
    }

    @Test("symlink targets and missing video thumbnails are rejected")
    func targetSafety() async throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        let target = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        let other = f.root.appendingPathComponent("other.txt")
        try f.bytes.write(to: other)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        await #expect(throws: WeVaultError.self) { try await f.restore(snapshot) }
        #expect(try Data(contentsOf: other) == f.bytes)
        let video = try f.snapshot(name: "clip_raw.mp4", index: 1, type: .videoRawLayer)
        try FileManager.default.removeItem(atPath: video.archivedFile.bubbleOrThumbPath!)
        await #expect(throws: WeVaultError.self) { try await f.restore(video) }
    }

    @Test("legacy failure local state is reconciled without claiming a download restored the original")
    func legacyFailure() async throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let snapshot = try f.quarantined()
        try f.store.updateRestoreState(bindingID: snapshot.binding.bindingID, archiveState: .restoreFailed, localState: .restoreFailed, restoredAt: nil, lastRestoreCheckAt: Date())
        let failed = try #require(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
        _ = try await f.restore(failed, destination: .directory(f.root.appendingPathComponent("downloads")))
        #expect(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID)?.binding.localState == .tombstoned)
    }

    @Test("interrupted restoration revalidates and completes without redownload of existing original")
    func interrupted() async throws {
        let f = try RestoreFixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        try f.store.updateRestoreState(bindingID: snapshot.binding.bindingID, archiveState: .restorePending, localState: .localPresent, restoredAt: nil, lastRestoreCheckAt: Date())
        let pending = try #require(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
        _ = try await f.restore(pending, client: RestoreClient(data: nil))
        #expect(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID)?.binding.archiveState == .restored)
    }

    @Test("PDF and Office include actionable links; all formats retain metadata and detection")
    func tombstones() throws {
        let f = try RestoreFixture(); defer { f.remove() }
        for ext in ["txt", "pdf", "docx", "pptx", "xlsx", "zip"] {
            let snapshot = try f.snapshot(name: "测试归档文件.\(ext)")
            if DevelopmentIsolation.root != nil {
                try ManifestStore().saveCloudObject(snapshot.object, binding: snapshot.binding, archivedFile: snapshot.archivedFile)
            }
            let payload = try #require(try Tombstone.payload(for: snapshot, createdAt: Date()))
            let url = f.root.appendingPathComponent("placeholder.\(ext)")
            try payload.data.write(to: url)
            #expect(Tombstone.isTombstone(url))
            let expected = try RestoreLink(bindingID: snapshot.binding.bindingID).url
            if ext == "pdf" {
                let pdf = try #require(PDFDocument(data: payload.data))
                #expect(pdf.pageCount == 1)
                #expect(pdf.string?.contains("这不是原文件") == true)
                #expect(pdf.page(at: 0)?.annotations.contains(where: { $0.url == expected }) == true)
            } else {
                #expect(payload.data.range(of: Data(expected.absoluteString.utf8)) != nil)
                #expect(payload.data.range(of: Data(snapshot.archivedFile.sha256.utf8)) != nil)
                if ["docx", "pptx", "xlsx"].contains(ext) {
                    #expect(payload.data.range(of: Data("TargetMode=\"External\"".utf8)) != nil)
                    #expect(payload.data.range(of: Data("r:id=\"rIdRestore\"".utf8)) != nil)
                }
            }
            if let path = ProcessInfo.processInfo.environment["WEVAULT_P5_ARTIFACT_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try payload.data.write(to: directory.appendingPathComponent("placeholder.\(ext)"))
            }
        }
    }
}

private final class RestoreFixture {
    let root: URL
    let store: ManifestStore
    let bytes = Data("verified original contents".utf8)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WeVaultP5-\(UUID().uuidString)")
        store = try ManifestStore(databaseURL: root.appendingPathComponent("archive.sqlite"), keyProvider: InMemoryManifestKeyProvider())
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func snapshot(name: String = "sample.txt", index: Int = 0, type: ArchiveObjectType = .ordinaryFile) throws -> ArchivedFileSnapshot {
        let path = root.appendingPathComponent(name)
        try bytes.write(to: path)
        let display = root.appendingPathComponent("display-\(index)")
        let thumb = root.appendingPathComponent("thumb-\(index)")
        try bytes.write(to: display); try bytes.write(to: thumb)
        let digest = try sha256File(path)
        let id = "binding-" + sha256Hex("\(name)|\(index)")
        let file = ArchivedFile(filePath: path.path, objectType: type, originalFilename: name, relativePath: name, accountHash: "test", accountName: "test", month: "2026-09", sizeBytes: Int64(bytes.count), sha256: digest, mtime: Date(), familyID: nil, displayOrPlaybackPath: display.path, bubbleOrThumbPath: thumb.path, archivedAt: Date(timeIntervalSince1970: 1000), updatedAt: Date())
        let object = CloudObject(cloudObjectID: "object-\(index)", sha256: digest, sizeBytes: Int64(bytes.count), storageProvider: "Mock", bucketOrContainer: "test", objectKey: "test", uploadedAt: Date(), verifiedAt: Date(), verifyStatus: .verified, refCount: 1)
        let binding = ArchiveBinding(bindingID: id, filePath: path.path, cloudObjectID: object.cloudObjectID, archiveState: .verified, localState: .localPresent)
        try store.saveCloudObject(object, binding: binding, archivedFile: file)
        return ArchivedFileSnapshot(archivedFile: file, binding: binding, object: object)
    }
    func quarantined() throws -> ArchivedFileSnapshot {
        let snapshot = try snapshot()
        _ = try LocalReleaseService(quarantineRoot: root.appendingPathComponent("quarantine")).quarantine(snapshot: snapshot, store: store, userConfirmed: true, skipRestoreTest: true)
        return try #require(try store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
    }
    func restore(_ snapshot: ArchivedFileSnapshot, destination: RestoreDestination = .originalPath, client: RestoreClient? = nil) async throws -> CloudRestoreResult {
        try await CloudRestoreService().restore(snapshot: snapshot, destination: destination, client: client ?? RestoreClient(data: bytes), objectKey: "test", store: store)
    }
}

private struct RestoreClient: ObjectStorageClient {
    let data: Data?
    let duringDownload: @Sendable () throws -> Void
    init(data: Data?, duringDownload: @escaping @Sendable () throws -> Void = {}) { self.data = data; self.duringDownload = duringDownload }
    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws { throw WeVaultError.cloud("not supported") }
    func headObject(objectKey: String) async throws -> StoredObjectHead { StoredObjectHead(sizeBytes: Int64(data?.count ?? 0)) }
    func getObject(objectKey: String, destinationURL: URL) async throws {
        guard let data else { throw WeVaultError.cloud("simulated network failure") }
        try data.write(to: destinationURL)
        try duringDownload()
    }
}
