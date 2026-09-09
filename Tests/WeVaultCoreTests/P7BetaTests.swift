import Foundation
import Testing
@testable import WeVaultCore

@Suite("P7 beta stabilization")
struct P7BetaTests {
    #if DEBUG
    @Test("dedicated smoke bundles retain isolation without a launch environment")
    func smokeBundleIsolation() {
        #expect(DevelopmentIsolation.fixtureRoot(environmentPath: nil, bundlePath: "/tmp/beta-fixture")?.path == "/tmp/beta-fixture/synthetic-wevault")
        #expect(DevelopmentIsolation.fixtureRoot(environmentPath: "/tmp/explicit-fixture", bundlePath: "/tmp/beta-fixture")?.path == "/tmp/explicit-fixture/synthetic-wevault")
        #expect(DevelopmentIsolation.fixtureRoot(environmentPath: nil, bundlePath: nil) == nil)
        #expect(DevelopmentIsolation.fixtureRoot(environmentPath: nil, bundlePath: "relative") == nil)
    }
    #endif

    @Test("manual upload processes every page, selects duplicates below threshold, and retains sources")
    func manualPages() async throws {
        let f = try BetaFixture(); defer { f.remove() }
        for i in 0..<123 { try f.write("\(i).txt", "same contents") }
        try f.write("small-unique.txt", "unique")
        let session = try await ManualArchivePipeline.scan(root: f.root, threshold: 1024, store: f.store)
        let summary = try await ManualArchivePipeline.upload(session: session, root: f.root, threshold: 1024, store: f.store) { files, _, store in
            #expect(files.count <= 50)
            for file in files { try f.save(file, store: store) }
        }
        #expect(summary.attempted == 123 && summary.verified == 123 && summary.failed == 0)
        #expect(FileManager.default.fileExists(atPath: f.files.appendingPathComponent("0.txt").path))
        #expect(try f.store.archivedSnapshot(path: f.files.appendingPathComponent("small-unique.txt").path) == nil)
        #expect(try f.store.archivedFilePage(limit: 1).first?.binding.localState == .localPresent)
    }

    @Test("manual rescan retains released archives for display but never uploads placeholders")
    func releasedDisplay() async throws {
        let f = try BetaFixture(); defer { f.remove() }
        try f.write("original.txt", "payload")
        let scan = try WeChatScanner().scan(root: f.root, options: ScanOptions(largeFileThresholdBytes: 1))
        try f.save(scan.files[0], store: f.store)
        let archived = try #require(try f.store.archivedSnapshot(path: scan.files[0].path))
        _ = try LocalReleaseService(quarantineRoot: f.base.appendingPathComponent("quarantine")).isolate(snapshot: archived, store: f.store, authorization: .manual(confirmed: true, skipRestoreTest: true))
        let session = try await ManualArchivePipeline.scan(root: f.root, threshold: 1, store: f.store)
        let rows = try f.store.workPage(FileRecord.self, scope: session + ".files")
        #expect(rows.count == 1 && rows.first?.value.status == .tombstoned)
        let summary = try await ManualArchivePipeline.upload(session: session, root: f.root, threshold: 1, store: f.store) { _, _, _ in Issue.record("Placeholder must not upload") }
        #expect(summary.attempted == 0)
    }

    @Test("manual fatal failure stops later pages and cancellation retains published scan")
    func manualFailure() async throws {
        let f = try BetaFixture(); defer { f.remove() }
        for i in 0..<103 { try f.write("\(i).txt", "payload") }
        let session = try await ManualArchivePipeline.scan(root: f.root, threshold: 1, store: f.store)
        await #expect(throws: WeVaultError.self) {
            _ = try await ManualArchivePipeline.upload(session: session, root: f.root, threshold: 1, store: f.store) { _, _, _ in
                throw WeVaultError.sqlite("Injected write failure")
            }
        }
        #expect(try f.store.archivedFilePage().isEmpty)
        let task = Task {
            try await ManualArchivePipeline.upload(session: session, root: f.root, threshold: 1, store: f.store) { _, _, _ in throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try f.store.currentScanSession() == session)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.files.path).count == 103)
    }

    @Test("self-managed cancellation is propagated instead of continuing the upload batch")
    func selfManagedCancellation() async throws {
        let f = try BetaFixture(); defer { f.remove() }
        try f.write("file.txt", "payload")
        let scan = try WeChatScanner().scan(root: f.root, options: ScanOptions(largeFileThresholdBytes: 1))
        let config = S3CompatibleStorageConfig(provider: "test", endpoint: "https://fixture.invalid", bucket: "test", region: "test", accessKeyID: "test", secretAccessKey: "test")
        await #expect(throws: CancellationError.self) {
            _ = try await CloudUploadService(clientFactory: { _ in CancellingBetaStorage() }).upload(files: scan.files, config: config, store: f.store)
        }
        #expect(try f.store.archivedFilePage().isEmpty)
        #expect(try String(contentsOf: f.files.appendingPathComponent("file.txt"), encoding: .utf8) == "payload")
    }

    @Test("diagnostic export spans pages, removes private prose, and never overwrites a file")
    func diagnostics() throws {
        let f = try BetaFixture(); defer { f.remove() }
        let secret = "/Users/person/private.pdf token=private-token object=users/private"
        for _ in 0..<250 { try f.store.logOperation("UPLOAD_FAILED", detail: secret) }
        try f.store.logAutomation(runID: nil, event: "AUTOMATION_OBJECT_FAILED", detail: secret)
        try f.store.logAutomation(runID: nil, event: secret, detail: secret)
        try f.store.logDiagnosticOperation("MANAGED_UPLOAD_FAILED", diagnostic: "HTTP 403 AccessDenied request=test-request")
        let runID = UUID().uuidString
        try f.store.saveAutomationRun(AutomationTaskRun(id: runID, taskID: "fixture", status: .failed, stage: .uploading, completedUnits: 3, totalUnits: 5, failureReason: secret))
        let target = f.base.appendingPathComponent("diagnostics.jsonl")
        try DiagnosticExporter.export(to: target, store: f.store, version: "0.7.0", build: "7")
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 255)
        #expect(!text.contains("private") && !text.contains("/Users/") && !text.contains("private-token"))
        #expect(text.contains("HTTP 403 AccessDenied request=test-request"))
        #expect(text.contains("UNKNOWN_EVENT"))
        #expect(text.contains(runID) && text.contains("completedUnits") && text.contains("UPLOADING"))
        #expect(throws: (any Error).self) { try DiagnosticExporter.export(to: target, store: f.store, version: "changed", build: "8") }
        #expect(try String(contentsOf: target, encoding: .utf8) == text)
        let fallback = f.base.appendingPathComponent("unavailable.jsonl")
        try DiagnosticExporter.export(to: fallback, store: nil, version: "0.7.0", build: "7")
        #expect(try String(contentsOf: fallback, encoding: .utf8).contains("unavailable"))
    }

    @Test("user errors do not expose server secrets and distinguish actionable failures")
    func messages() {
        let auth = UserFacingFailure.describe(WeVaultAPIFailure(code: "SECRET", statusCode: 401, message: "token=secret"))
        #expect(auth.code == "AUTH_EXPIRED" && !auth.description.contains("secret"))
        #expect(UserFacingFailure.describe(WeVaultError.manifest(.missingNeedsCloudIndexFallback)).message.contains("不能重建"))
        #expect(UserFacingFailure.describe(URLError(.notConnectedToInternet)).code == "NETWORK_UNAVAILABLE")
        #expect(UserFacingFailure.describe(CancellationError()).code == "CANCELLED")
    }

    @Test("update metadata validates URL and OS compatibility; feedback cannot inject mail headers")
    func updates() throws {
        let data = Data(#"{"version":"0.8.0","build":8,"minimumSystemVersion":"14.0","downloadURL":"https://downloads.example.test/beta","releaseNotes":"Bug fixes"}"#.utf8)
        let release = try JSONDecoder().decode(BetaRelease.self, from: data)
        try release.validate()
        #expect(release.supports(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        #expect(!release.supports(OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)))
        for address in ["file:///private/file", "http://example.test", "https://user:pass@example.test/"] {
            #expect(!BetaRelease.isWebURL(URL(string: address)!))
        }
        #expect(BetaFeedback.mailURL(address: "person@example.test\nBcc:other@example.test", version: "0.7.0", build: "7") == nil)
        let mail = try #require(BetaFeedback.mailURL(address: "support@example.test", version: "0.7.0", build: "7"))
        #expect(mail.scheme == "mailto")
        #expect(URLComponents(url: mail, resolvingAgainstBaseURL: false)?.queryItems?.count == 2)
    }

    @Test("older settings decode without risk acknowledgement and retain existing policy")
    func oldSettings() throws {
        let encoded = try JSONEncoder().encode(ProductSettings(onboardingCompleted: true, automaticTasksEnabled: false))
        let loaded = try JSONDecoder().decode(ProductSettings.self, from: encoded)
        #expect(loaded.riskAcknowledgementVersion == nil)
        #expect(!loaded.automaticExecutionPermitted)
        var enabled = ProductSettings(onboardingCompleted: true)
        #expect(!enabled.automaticExecutionPermitted)
        enabled.riskAcknowledgementVersion = 1
        #expect(enabled.automaticExecutionPermitted)
        #expect(!loaded.automaticTasksEnabled && loaded.coolingPeriodDays == 7 && loaded.quarantineRetentionDays == 7)
    }
}

private struct CancellingBetaStorage: ObjectStorageClient {
    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws { throw CancellationError() }
    func headObject(objectKey: String) async throws -> StoredObjectHead { throw CancellationError() }
    func getObject(objectKey: String, destinationURL: URL) async throws { throw CancellationError() }
}

struct BetaFixture: Sendable {
    let base: URL, root: URL, files: URL
    let store: ManifestStore
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("WeVaultP7-" + UUID().uuidString)
        root = base.appendingPathComponent("wxid_fixture")
        files = root.appendingPathComponent("msg/file/2025-01")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        store = try ManifestStore(databaseURL: base.appendingPathComponent("manifest.sqlite"), keyProvider: InMemoryManifestKeyProvider())
    }
    func write(_ name: String, _ contents: String) throws { try Data(contents.utf8).write(to: files.appendingPathComponent(name)) }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func save(_ file: FileRecord, store: ManifestStore, provider: String = "test") throws {
        let sha = file.sha256!
        let object = CloudObject(cloudObjectID: "cloud-" + sha, sha256: sha, sizeBytes: file.sizeBytes, storageProvider: provider, bucketOrContainer: "test", objectKey: "test", uploadedAt: Date(), verifiedAt: Date(), verifyStatus: .verified, refCount: 1)
        let archive = ArchivedFile(filePath: file.path, objectType: file.objectType, originalFilename: file.filename, relativePath: file.relativePath, accountHash: "fixture", accountName: "wxid_fixture", month: file.month, sizeBytes: file.sizeBytes, sha256: sha, mtime: file.mtime, familyID: nil, displayOrPlaybackPath: nil, bubbleOrThumbPath: nil, archivedAt: Date(), updatedAt: Date())
        try store.saveCloudObject(object, binding: ArchiveBinding(bindingID: "binding-" + sha256Hex(file.path), filePath: file.path, cloudObjectID: object.cloudObjectID, archiveState: .verified, localState: .localPresent), archivedFile: archive)
    }
}
