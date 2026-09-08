import Foundation
import Testing
@testable import WeVaultCore

@Suite("P4 bounded pipeline")
struct P4PipelineTests {
    @Test("batches are bounded, first consumption precedes full scan, and duplicates cross batches")
    func streaming() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        for i in 0..<123 { try f.write("msg/file/2025-01/\(i).txt", data: Data("same-content".utf8)) }
        let probe = BatchProbe()
        let session = try await WeChatScanner().scanBatches(root: f.root, options: ScanOptions(largeFileThresholdBytes: 1), store: f.store) { files, _ in
            await probe.observe(files.count)
            #expect(files.count <= 50)
            #expect(files.allSatisfy { $0.sha256 != nil })
        }
        #expect(await probe.sizes == [50, 50, 23])
        let first = try f.store.workPage(FileRecord.self, scope: session + ".files")
        #expect(first.count == 50)
        #expect(first.allSatisfy { $0.value.duplicateGroupID != nil })
        let summary = try #require(try f.store.workGet(ScanSummary.self, scope: session + ".metadata", key: "summary"))
        #expect(summary.ordinaryCount == 123)
        #expect(summary.duplicateReclaimableBytes == 122 * 12)
        let bytes = try Data(contentsOf: f.store.databaseURL)
        #expect(bytes.range(of: Data("same-content".utf8)) == nil)
        #expect(bytes.range(of: Data(f.root.path.utf8)) == nil)
    }

    @Test("aborted scan retains the previous publication and cleans its staging")
    func abortedScan() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        try f.write("msg/file/2025-01/a.txt")
        let old = try await WeChatScanner().scanBatches(root: f.root, options: ScanOptions(), store: f.store) { _, _ in }
        await #expect(throws: CancellationError.self) {
            _ = try await WeChatScanner().scanBatches(root: f.root, options: ScanOptions(), store: f.store, session: "aborted") { _, _ in throw CancellationError() }
        }
        #expect(try f.store.currentScanSession() == old)
        #expect(try f.store.workPage(FileRecord.self, scope: "aborted.files").isEmpty)
    }

    @Test("media members arriving separately are associated on disk")
    func mediaFamilies() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        for i in 0..<110 {
            try f.write("msg/attach/resource/2025-01/\(i)_h.dat")
            try f.write("msg/attach/resource/2025-01/\(i).dat")
            try f.write("msg/attach/resource/2025-01/\(i)_t.dat")
        }
        let probe = BatchProbe()
        _ = try await WeChatScanner().scanBatches(root: f.root, options: ScanOptions(), store: f.store) { files, families in
            #expect(files.count <= 50)
            #expect(families.count == files.count)
            #expect(families.allSatisfy { $0.displayOrPlaybackPath != nil && $0.bubbleOrThumbPath != nil })
            await probe.observe(files.count)
        }
        #expect(await probe.sizes == [50, 50, 10])
    }

    @Test("all three types isolate, expire and restore while repeat archival preserves dates")
    func fullCycle() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        for kind in [ArchiveObjectType.ordinaryFile, .imageHighLayer, .videoRawLayer] {
            let original = try f.snapshot(type: kind)
            let service = LocalReleaseService(quarantineRoot: f.quarantine)
            let authorization = ReleaseAuthorization.automatic(settings: f.settings, root: f.root, now: f.now)
            _ = try service.isolate(snapshot: original, store: f.store, authorization: authorization)
            let isolated = try #require(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID))
            #expect(isolated.binding.quarantinePath != nil)
            let repeatArchived = ArchivedFile(filePath: original.archivedFile.filePath, objectType: kind, originalFilename: original.archivedFile.originalFilename, relativePath: original.archivedFile.relativePath, accountHash: "test", accountName: "wxid_test", month: "2025-01", sizeBytes: original.archivedFile.sizeBytes, sha256: original.archivedFile.sha256, mtime: f.now, familyID: nil, displayOrPlaybackPath: nil, bubbleOrThumbPath: nil, archivedAt: f.now, updatedAt: f.now)
            try f.store.saveCloudObject(original.object, binding: original.binding, archivedFile: repeatArchived)
            #expect(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID)?.binding.quarantinePath == isolated.binding.quarantinePath)
            #expect(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID)?.archivedFile.archivedAt == original.archivedFile.archivedAt)
            #expect(throws: WeVaultError.self) { try service.finalizeSafely(snapshot: isolated, store: f.store, authorization: authorization) }
            _ = try service.finalizeSafely(snapshot: isolated, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now.addingTimeInterval(7 * 86400)))
            let released = try #require(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID))
            #expect(released.binding.quarantinePath == nil)
            _ = try await CloudRestoreService().restore(snapshot: released, destination: .originalPath, client: P4ObjectClient(data: f.data), objectKey: "test", store: f.store)
            let restored = try #require(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID))
            #expect(restored.binding.localState == .restored)
            #expect(AutomaticReleaseRuleEngine().decision(for: restored, settings: f.settings, now: f.now.addingTimeInterval(30 * 86400)) != .eligible)
        }
    }

    @Test("pipeline releases historical pages even when the next scan contains only placeholders")
    func historicalPages() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        for i in 0..<112 { _ = try f.snapshot(nameOverride: "msg/file/2025-01/file-\(i).txt") }
        let pipeline = AutomaticArchivePipeline(store: f.store, releaseService: LocalReleaseService(quarantineRoot: f.quarantine), now: { f.now })
        let report = try await pipeline.run(root: f.root, settings: f.settings) { files, _, _ in
            ManagedCloudUploadReport(snapshots: [:], attemptedCount: files.count, verifiedCount: files.count, failures: [])
        }
        #expect(report.failedUnits == 0)
        #expect(try f.store.archivedFileSnapshots().values.allSatisfy { $0.binding.localState == .tombstoned })
        let later = AutomaticArchivePipeline(store: f.store, releaseService: LocalReleaseService(quarantineRoot: f.quarantine), now: { f.now.addingTimeInterval(8 * 86400) })
        let finalReport = try await later.run(root: f.root, settings: f.settings) { _, _, _ in
            Issue.record("tombstones must never be uploaded")
            return ManagedCloudUploadReport(snapshots: [:], attemptedCount: 0, verifiedCount: 0, failures: [])
        }
        #expect(finalReport.completedUnits == 112)
        #expect(finalReport.failedUnits == 0)
        #expect(try f.store.archivedFileSnapshots().values.allSatisfy { $0.binding.quarantinePath == nil })
    }

    @Test("managed upload uses two workers, merges SHA and reuses verified bindings")
    func managedConcurrency() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        for i in 0..<8 { try f.write("msg/file/2025-01/\(i).txt", data: Data("contents-\(i % 4)".utf8)) }
        let scanned = try WeChatScanner().scan(root: f.root, options: ScanOptions(largeFileThresholdBytes: 0))
        let transport = P4FallbackTransport()
        let api = WeVaultAPIClient(baseURL: URL(string: "https://p4.invalid")!, transport: transport)
        let uploader = ManagedCloudArchiveService()
        let report = try await uploader.uploadBatch(files: scanned.files, families: [], api: api, accessToken: "fixture", deviceID: "fixture-device", store: f.store)
        #expect(report.verifiedCount == 8)
        #expect(await transport.maximum == 2)
        #expect(await transport.count == 4)
        let before = try f.store.archivedFileSnapshots()
        _ = try await uploader.uploadBatch(files: scanned.files, families: [], api: api, accessToken: "fixture", deviceID: "fixture-device", store: f.store)
        #expect(await transport.count == 4)
        #expect(try f.store.archivedFileSnapshots() == before)
    }

    @Test("an individual upload failure preserves its source while independent old archives release")
    func partialFailure() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        let failedPath = f.root.appendingPathComponent("msg/file/2025-01/failing.txt").path
        try f.write("msg/file/2025-01/failing.txt")
        let report = try await AutomaticArchivePipeline(store: f.store, releaseService: LocalReleaseService(quarantineRoot: f.quarantine), now: { f.now }).run(root: f.root, settings: f.settings) { files, _, _ in
            ManagedCloudUploadReport(snapshots: [:], attemptedCount: files.count, verifiedCount: files.count - 1, failures: [ManagedCloudUploadFailure(filePath: failedPath, reason: "fixture failure")])
        }
        #expect(report.failedUnits == 1)
        #expect(FileManager.default.fileExists(atPath: failedPath))
        #expect(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID)?.binding.localState == .tombstoned)
    }

    @Test("fatal authorization stops the pipeline before any release")
    func fatalAuthorization() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        await #expect(throws: WeVaultAPIFailure.self) {
            _ = try await AutomaticArchivePipeline(store: f.store, releaseService: LocalReleaseService(quarantineRoot: f.quarantine), now: { f.now }).run(root: f.root, settings: f.settings) { _, _, _ in
                throw WeVaultAPIFailure(code: "EXPIRED", statusCode: 401, message: "expired")
            }
        }
        #expect(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID)?.binding.localState == .localPresent)
        #expect(FileManager.default.fileExists(atPath: snapshot.archivedFile.filePath))
    }

    @Test("each isolation commit interruption can be reconciled", arguments: ["isolationPrepared", "isolationMoved", "isolationStateSaved", "placeholderCommitted", "isolationCompleted"])
    func isolationInterruption(stage: String) throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        let service = LocalReleaseService(quarantineRoot: f.quarantine) { if $0 == stage { throw P4InjectedFailure.stop } }
        #expect(throws: P4InjectedFailure.self) { try service.isolate(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now)) }
        #expect(try f.store.hasPendingRelease(bindingID: snapshot.binding.bindingID))
        try LocalReleaseService(quarantineRoot: f.quarantine).recoverPendingRelease(bindingID: snapshot.binding.bindingID, store: f.store)
        let restored = try #require(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
        #expect(restored.binding.localState == .tombstoned)
        #expect(try sha256File(URL(fileURLWithPath: restored.binding.quarantinePath!)) == snapshot.archivedFile.sha256)
        #expect(try !f.store.hasPendingRelease(bindingID: snapshot.binding.bindingID))
    }

    @Test("each final-delete interruption can be reconciled", arguments: ["deletionPrepared", "deletionMoved", "deletionRemoved", "deletionStateSaved"])
    func deletionInterruption(stage: String) throws {
        let f = try P4Fixture(); defer { f.remove() }
        let original = try f.snapshot()
        _ = try LocalReleaseService(quarantineRoot: f.quarantine).isolate(snapshot: original, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now))
        let isolated = try #require(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID))
        let service = LocalReleaseService(quarantineRoot: f.quarantine) { if $0 == stage { throw P4InjectedFailure.stop } }
        #expect(throws: P4InjectedFailure.self) { try service.finalizeSafely(snapshot: isolated, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now.addingTimeInterval(8 * 86400))) }
        try LocalReleaseService(quarantineRoot: f.quarantine).recoverPendingRelease(bindingID: original.binding.bindingID, store: f.store)
        let final = try #require(try f.store.archivedFileSnapshot(bindingID: original.binding.bindingID))
        #expect(final.binding.quarantinePath == nil)
        #expect(final.binding.localState == .tombstoned)
        #expect(try !f.store.hasPendingRelease(bindingID: original.binding.bindingID))
    }

    @Test("edited placeholders and changed isolation identities are retained")
    func conflicts() throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        let service = LocalReleaseService(quarantineRoot: f.quarantine)
        _ = try service.isolate(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now))
        let isolated = try #require(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID))
        try Data("edited".utf8).write(to: URL(fileURLWithPath: snapshot.archivedFile.filePath))
        #expect(throws: WeVaultError.self) { try service.finalizeSafely(snapshot: isolated, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now.addingTimeInterval(8 * 86400))) }
        #expect(FileManager.default.fileExists(atPath: isolated.binding.quarantinePath!))
    }

    @Test("current rules reject out-of-root, disabled, small, changed and too-young originals")
    func ruleBoundaries() throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        let engine = AutomaticReleaseRuleEngine()
        let service = LocalReleaseService(quarantineRoot: f.quarantine)
        #expect(engine.decision(for: snapshot, settings: f.settings, now: f.now.addingTimeInterval(-86400)) == .eligible)
        #expect(engine.decision(for: snapshot, settings: f.settings, now: f.now.addingTimeInterval(-86401)) != .eligible)
        var small = f.settings; small.largeFileThresholdMB = 1
        #expect(engine.decision(for: snapshot, settings: small, now: f.now) != .eligible)
        var disabled = f.settings; disabled.automaticTasksEnabled = false
        #expect(throws: WeVaultError.self) { try service.isolate(snapshot: snapshot, store: f.store, authorization: .automatic(settings: disabled, root: f.root, now: f.now)) }
        var excluded = f.settings; excluded.allowedExtensions = ["zip"]
        #expect(engine.decision(for: snapshot, settings: excluded, now: f.now) != .eligible)
        #expect(throws: WeVaultError.self) { try service.isolate(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.base.appendingPathComponent("other"), now: f.now)) }
        try Data("changed".utf8).write(to: URL(fileURLWithPath: snapshot.archivedFile.filePath))
        #expect(engine.decision(for: snapshot, settings: f.settings, now: f.now) != .eligible)
        #expect(try !f.store.hasPendingRelease(bindingID: snapshot.binding.bindingID))
    }

    @Test("source replacement after authorization never gets moved")
    func sourceRace() throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        let original = URL(fileURLWithPath: snapshot.archivedFile.filePath)
        let service = LocalReleaseService(quarantineRoot: f.quarantine) { stage in
            if stage == "isolationPrepared" { try Data("new-user-content".utf8).write(to: original, options: .atomic) }
        }
        #expect(throws: WeVaultError.self) { try service.isolate(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now)) }
        #expect(try String(contentsOf: original, encoding: .utf8) == "new-user-content")
        #expect(try f.store.hasPendingRelease(bindingID: snapshot.binding.bindingID))
        try LocalReleaseService(quarantineRoot: f.quarantine).recoverPendingRelease(bindingID: snapshot.binding.bindingID, store: f.store)
        #expect(try !f.store.hasPendingRelease(bindingID: snapshot.binding.bindingID))
    }

    @Test("replacement at the deletion commit point is retained")
    func deletionRace() throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        _ = try LocalReleaseService(quarantineRoot: f.quarantine).isolate(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now))
        let service = LocalReleaseService(quarantineRoot: f.quarantine) { stage in
            if stage == "deletionMoved" {
                let journal = try #require(try f.store.workGet(ReleaseJournal.self, scope: "release-journal", key: snapshot.binding.bindingID))
                try Data("conflicting-copy".utf8).write(to: URL(fileURLWithPath: journal.deletionPath!), options: .atomic)
            }
        }
        #expect(throws: WeVaultError.self) { try service.finalizeSafely(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now.addingTimeInterval(8 * 86400))) }
        let journal = try #require(try f.store.workGet(ReleaseJournal.self, scope: "release-journal", key: snapshot.binding.bindingID))
        #expect(try String(contentsOfFile: journal.deletionPath!, encoding: .utf8) == "conflicting-copy")
    }

    @Test("media layer loss and symlink sources prevent automatic isolation")
    func unsafeSources() throws {
        let f = try P4Fixture(); defer { f.remove() }
        let image = try f.snapshot(type: .imageHighLayer)
        try FileManager.default.removeItem(atPath: image.archivedFile.displayOrPlaybackPath!)
        let service = LocalReleaseService(quarantineRoot: f.quarantine)
        #expect(throws: WeVaultError.self) { try service.isolate(snapshot: image, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now)) }
        let ordinary = try f.snapshot()
        let original = URL(fileURLWithPath: ordinary.archivedFile.filePath)
        let other = f.base.appendingPathComponent("external.txt")
        try f.data.write(to: other)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: other)
        #expect(throws: WeVaultError.self) { try service.isolate(snapshot: ordinary, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now)) }
        #expect(try Data(contentsOf: other) == f.data)
    }

    @Test("inaccessible account archives are not automatically released")
    func accountScope() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        _ = try await AutomaticArchivePipeline(store: f.store, releaseService: LocalReleaseService(quarantineRoot: f.quarantine), now: { f.now }).run(root: f.root, settings: f.settings, authorizeArchive: { _, _ in false }) { files, _, _ in
            ManagedCloudUploadReport(snapshots: [:], attemptedCount: files.count, verifiedCount: files.count, failures: [])
        }
        #expect(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID)?.binding.localState == .localPresent)
    }

    @Test("automation diagnostics are encrypted and readable after reopening")
    func encryptedDiagnostics() throws {
        let f = try P4Fixture(); defer { f.remove() }
        let secret = "private-path-and-diagnostic-" + UUID().uuidString
        try f.store.saveAutomationRun(AutomationTaskRun(id: "fixture-run", taskID: "fixture-task", status: .failed, stage: .releasing, failureReason: secret))
        try f.store.logAutomation(runID: "fixture-run", event: "FAILED", detail: secret)
        let reopened = try f.store.reopen()
        #expect(try reopened.latestAutomationRun(taskID: "fixture-task")?.failureReason == secret)
        #expect(try reopened.recentAutomationLogs(taskID: "fixture-task").first?.detail == secret)
        for path in [f.store.databaseURL.path, f.store.databaseURL.path + "-wal"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { #expect(data.range(of: Data(secret.utf8)) == nil) }
        }
    }

    @Test("binding lease rejects concurrent restore without losing the placeholder")
    func mutualExclusion() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        let key = OperationCoordinator.bindingKey(snapshot.binding.bindingID, store: f.store)
        try OperationCoordinator.shared.acquire(key); defer { OperationCoordinator.shared.release(key) }
        await #expect(throws: WeVaultError.self) { try await CloudRestoreService().restore(snapshot: snapshot, destination: .originalPath, client: P4ObjectClient(data: f.data), objectKey: "test", store: f.store) }
        #expect(try sha256File(URL(fileURLWithPath: snapshot.archivedFile.filePath)) == snapshot.archivedFile.sha256)
    }

    @Test("restore can cancel an interrupted deletion and recover the original")
    func restoreInterruptedDeletion() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        let snapshot = try f.snapshot()
        _ = try LocalReleaseService(quarantineRoot: f.quarantine).isolate(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now))
        let service = LocalReleaseService(quarantineRoot: f.quarantine) { if $0 == "deletionMoved" { throw P4InjectedFailure.stop } }
        #expect(throws: P4InjectedFailure.self) { try service.finalizeSafely(snapshot: snapshot, store: f.store, authorization: .automatic(settings: f.settings, root: f.root, now: f.now.addingTimeInterval(8 * 86400))) }
        _ = try await CloudRestoreService().restore(snapshot: snapshot, destination: .originalPath, client: P4ObjectClient(data: f.data), objectKey: "test", store: f.store)
        #expect(try !f.store.hasPendingRelease(bindingID: snapshot.binding.bindingID))
        #expect(try f.store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID)?.binding.localState == .restored)
    }

    @Test("abandoned running task becomes immediately resumable after restart")
    func restartScheduler() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        try f.store.saveAutomationTask(AutomationTask(isPaused: false, intervalHours: 24, nextRunAt: f.now.addingTimeInterval(86400)))
        try f.store.saveAutomationRun(AutomationTaskRun(taskID: "default-automation", status: .running, stage: .releasing, completedUnits: 3, totalUnits: 8))
        let scheduler = AutomationScheduler(store: f.store, now: { f.now })
        let configured = try await scheduler.configure(settings: f.settings)
        #expect(configured.nextRunAt == f.now)
        #expect(try await scheduler.snapshot()?.latestRun?.status == .paused)
        #expect(try await scheduler.snapshot()?.latestRun?.completedUnits == 3)
    }

    @Test("scheduler cancellation preserves stage and resumes immediately")
    func pauseRun() async throws {
        let f = try P4Fixture(); defer { f.remove() }
        let scheduler = AutomationScheduler(store: f.store, now: { f.now })
        _ = try await scheduler.configure(settings: f.settings)
        let running = Task { try await scheduler.runDueTasks(cloudGate: .available, contextPipeline: { context in
            try await context.progress(.hashing, completed: 3, total: 50)
            try await Task.sleep(for: .seconds(30))
            return AutomationPipelineResult(completedUnits: 50, totalUnits: 50)
        }) }
        while try await scheduler.snapshot()?.latestRun?.stage != .hashing { await Task.yield() }
        await scheduler.cancelActiveRun()
        let run = try #require(await running.value.first)
        #expect(run.status == .paused); #expect(run.stage == .hashing); #expect(run.completedUnits == 3)
        var paused = f.settings; paused.automaticTasksEnabled = false
        _ = try await scheduler.configure(settings: paused)
        let resumed = try await scheduler.configure(settings: f.settings)
        #expect(resumed.nextRunAt == f.now)
    }
}

private enum P4InjectedFailure: Error { case stop }
private actor BatchProbe {
    var sizes: [Int] = []
    func observe(_ count: Int) { sizes.append(count) }
}
private struct P4Fixture: Sendable {
    let base: URL
    let root: URL
    let store: ManifestStore
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data(repeating: 0x31, count: 1024)
    var quarantine: URL { base.appendingPathComponent("quarantine") }
    var settings: ProductSettings { ProductSettings(largeFileThresholdMB: 0) }
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("p4-" + UUID().uuidString)
        root = base.appendingPathComponent("wxid_test")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try ManifestStore(databaseURL: base.appendingPathComponent("manifest.sqlite"), keyProvider: InMemoryManifestKeyProvider(key: Data(repeating: 0x41, count: 32)))
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func write(_ relative: String, data: Data? = nil) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? self.data).write(to: url)
    }
    func snapshot(type: ArchiveObjectType = .ordinaryFile, nameOverride: String? = nil) throws -> ArchivedFileSnapshot {
        let name = nameOverride ?? (type == .ordinaryFile ? "msg/file/2025-01/file.txt" : type == .imageHighLayer ? "msg/attach/r/2025-01/image_h.dat" : "msg/video/2025-01/video_raw.mp4")
        try write(name)
        let file = root.appendingPathComponent(name)
        let sha = try sha256File(file)
        let display = root.appendingPathComponent(name + ".display"), thumb = root.appendingPathComponent(name + ".thumb")
        if type != .ordinaryFile { try write(name + ".display", data: Data([1])); try write(name + ".thumb", data: Data([2])) }
        let object = CloudObject(cloudObjectID: "cloud-" + type.rawValue, sha256: sha, sizeBytes: Int64(data.count), storageProvider: "WeVault Managed Cloud", bucketOrContainer: "test", objectKey: "test", uploadedAt: now, verifiedAt: now, verifyStatus: .verified, refCount: 1)
        let binding = ArchiveBinding(bindingID: "binding-" + sha256Hex(name), filePath: file.path, cloudObjectID: object.cloudObjectID, archiveState: .verified, localState: .localPresent)
        let archive = ArchivedFile(filePath: file.path, objectType: type, originalFilename: file.lastPathComponent, relativePath: name, accountHash: "test", accountName: "wxid_test", month: "2025-01", sizeBytes: Int64(data.count), sha256: sha, mtime: now, familyID: nil, displayOrPlaybackPath: type == .ordinaryFile ? nil : display.path, bubbleOrThumbPath: type == .ordinaryFile ? nil : thumb.path, archivedAt: now.addingTimeInterval(-8 * 86400), updatedAt: now)
        try store.saveCloudObject(object, binding: binding, archivedFile: archive)
        return ArchivedFileSnapshot(archivedFile: archive, binding: binding, object: object)
    }
}
private struct P4ObjectClient: ObjectStorageClient {
    let data: Data
    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws {}
    func headObject(objectKey: String) async throws -> StoredObjectHead { StoredObjectHead(sizeBytes: Int64(data.count)) }
    func getObject(objectKey: String, destinationURL: URL) async throws { try data.write(to: destinationURL) }
}

private actor P4FallbackTransport: WeVaultAPITransport {
    var count = 0, maximum = 0, active = 0
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        active += 1; count += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(15))
        let sha = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "sha256" }!.value!
        let body = "{\"objects\":[{\"objectId\":\"\(sha)\",\"sha256\":\"\(sha)\",\"sizeBytes\":10,\"verifiedAt\":\"2026-09-01T00:00:00Z\"}]}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
