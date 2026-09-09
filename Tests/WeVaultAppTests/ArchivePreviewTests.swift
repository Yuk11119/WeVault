import AppKit
import CryptoKit
import Foundation
import Testing
import WeVaultCore
@testable import WeVaultApp

@Suite("Archive preview")
@MainActor
struct ArchivePreviewTests {
    private func record(root: URL, data: Data, state: LocalArchiveState = .localPresent, quarantine: String? = nil) -> ArchivedFileSnapshot {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = ArchivedFile(filePath: root.appendingPathComponent("sample.txt").path, objectType: .ordinaryFile,
            originalFilename: "sample.txt", relativePath: "sample.txt", accountHash: "fixture", accountName: "fixture",
            month: "2026-09", sizeBytes: Int64(data.count), sha256: sha, mtime: Date(), familyID: nil,
            displayOrPlaybackPath: nil, bubbleOrThumbPath: nil, archivedAt: Date(), updatedAt: Date())
        let object = CloudObject(cloudObjectID: "object", sha256: sha, sizeBytes: Int64(data.count), storageProvider: "fixture",
            bucketOrContainer: "fixture", objectKey: "fixture", uploadedAt: Date(), verifiedAt: Date(), verifyStatus: .verified, refCount: 1)
        let binding = ArchiveBinding(bindingID: "binding", filePath: file.filePath, cloudObjectID: "object",
            archiveState: .verified, localState: state, quarantinePath: quarantine)
        return ArchivedFileSnapshot(archivedFile: file, binding: binding, object: object)
    }

    @Test("preview uses a verified temporary copy and clears it without changing the source")
    func localCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("A readable preview".utf8)
        let snapshot = record(root: root, data: data)
        try data.write(to: URL(fileURLWithPath: snapshot.archivedFile.filePath))
        let model = ArchivePreviewModel()
        await model.loadLocal(snapshot)
        let url = try #require(model.url)
        #expect(url.path != snapshot.archivedFile.filePath)
        #expect(try Data(contentsOf: url) == data)
        model.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: snapshot.archivedFile.filePath))
    }

    @Test("a changed file or a placeholder is never presented as the archived original")
    func changedOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = record(root: root, data: Data("original".utf8))
        try Data("changed!".utf8).write(to: URL(fileURLWithPath: snapshot.archivedFile.filePath))
        let model = ArchivePreviewModel()
        await model.loadLocal(snapshot)
        #expect(model.url == nil)
        #expect(!model.isLoading)
        let placeholder = record(root: root, data: Data("changed!".utf8), state: .tombstoned)
        #expect(ArchivePreviewModel.localCandidates(placeholder).isEmpty)
        model.clear()
    }

    @Test("quarantine preview retains the original extension")
    func quarantineCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("quarantine preview".utf8)
        let path = root.appendingPathComponent("opaque-copy")
        try data.write(to: path)
        let model = ArchivePreviewModel()
        await model.loadLocal(record(root: root, data: data, state: .tombstoned, quarantine: path.path))
        #expect(model.url?.pathExtension == "txt")
        model.clear()
        #expect(try Data(contentsOf: path) == data)
    }

    @Test("closing and reopening a retained window keeps preview updates valid")
    func windowPreviewLifecycle() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data("first preview".utf8).write(to: first)
        try Data("second preview".utf8).write(to: second)
        let host = ArchivePreviewHostView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { host.closePreview(); window.contentView = nil }
        for _ in 0..<8 {
            host.display(first)
            #expect(host.preview?.shouldCloseWithWindow == false)
            // This notification permanently closes the old implementation's QL view.
            window.close()
            host.display(second)
            #expect((host.preview?.previewItem as? NSURL) == second as NSURL)
            let previous = host.preview
            host.closePreview()
            host.closePreview()
            host.display(first)
            #expect(host.preview !== previous)
        }
    }

    @Test("internal operation names have readable fallback labels")
    func activityLabels() {
        for event in ["MANAGED_UPLOAD_VERIFIED", "VERIFY_FAILED", "RELEASE_TOMBSTONE_WRITTEN", "REDACTED", "NEW_UNKNOWN_EVENT"] {
            let operation = OperationRecord(id: 1, event: event, detail: "[REDACTED]", createdAt: Date())
            #expect(operation.eventTitle != event)
            #expect(!operation.eventTitle.contains("REDACTED"))
        }
    }
}
