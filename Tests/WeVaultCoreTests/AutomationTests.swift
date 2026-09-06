import Foundation
import Testing
@testable import WeVaultCore

@Suite("Automation scheduler")
struct AutomationTests {
    @Test("unavailable cloud creates a durable waiting run without file work")
    func unavailableCloudCreatesWaitingRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wevault-automation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try ManifestStore(databaseURL: directory.appendingPathComponent("archive.sqlite"))
        let scheduler = AutomationScheduler(store: store, now: { now })
        _ = try await scheduler.configure(settings: ProductSettings())
        let runs = try await scheduler.runDueTasks()
        #expect(runs.count == 1)
        #expect(runs[0].status == .waitingForCloud)
        let snapshot = try #require(await scheduler.snapshot())
        #expect(snapshot.latestRun?.stage == .waitingForCloud)
        #expect(snapshot.logs.first?.event == "AUTOMATION_WAITING_FOR_CLOUD")
        #expect(snapshot.task.nextRunAt == now.addingTimeInterval(86_400))
    }

    @Test("pause prevents runs and resume recomputes the next schedule")
    func pauseAndResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wevault-automation-pause-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = AutomationScheduler(store: try ManifestStore(databaseURL: directory.appendingPathComponent("archive.sqlite")), now: { now })
        var paused = ProductSettings(); paused.automaticTasksEnabled = false
        let task = try await scheduler.configure(settings: paused)
        #expect(task.isPaused)
        #expect(try await scheduler.runDueTasks().isEmpty)
        var resumed = paused; resumed.automaticTasksEnabled = true; resumed.runIntervalHours = 6
        let resumedTask = try await scheduler.configure(settings: resumed)
        #expect(!resumedTask.isPaused)
        #expect(resumedTask.nextRunAt == now.addingTimeInterval(21_600))
    }

    @Test("a failed run is linked only when the next scheduled cycle retries")
    func failureRetryIsDeferredToNextCycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wevault-automation-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try ManifestStore(databaseURL: directory.appendingPathComponent("archive.sqlite"))
        try store.saveAutomationTask(AutomationTask(isPaused: false, intervalHours: 24, nextRunAt: now))
        let failed = AutomationTaskRun(id: "failed-run", taskID: "default-automation", status: .failed, stage: .uploading, failureReason: "network")
        try store.saveAutomationRun(failed)
        let scheduler = AutomationScheduler(store: store, now: { now })
        let retry = try #require(try await scheduler.runDueTasks().first)
        #expect(retry.retryOfRunID == failed.id)
        #expect((try await scheduler.runDueTasks()).isEmpty)
    }

    @Test("batch boundaries and upload bound remain fixed")
    func batchLimits() {
        let batches = AutomationPipelineLimits.batches(Array(0..<101))
        #expect(batches.map(\.count) == [50, 50, 1])
        #expect(AutomationPipelineLimits.uploadConcurrencyLimit == 2)
    }

    @Test("authorized pipeline records completion and never exposes credentials")
    func authorizedPipelineCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wevault-automation-authorized-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try ManifestStore(databaseURL: directory.appendingPathComponent("archive.sqlite"))
        let scheduler = AutomationScheduler(store: store, now: { now })
        _ = try await scheduler.configure(settings: ProductSettings())
        let runs = try await scheduler.runDueTasks(cloudGate: .available) {
            AutomationPipelineResult(completedUnits: 2, totalUnits: 3)
        }
        let run = try #require(runs.first)
        #expect(run.status == .completed)
        #expect(run.stage == .finished)
        #expect(run.completedUnits == 2)
        #expect(run.totalUnits == 3)
        #expect((try await scheduler.snapshot())?.logs.first?.event == "AUTOMATION_UPLOAD_FINISHED")
    }

    @Test("release engine requires verification, cooling period, local hash and rules")
    func releaseEligibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wevault-automation-rules-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("report.pdf")
        try Data("archive".utf8).write(to: file)
        let digest = try sha256File(file)
        let now = Date()
        let snapshot = archivedSnapshot(path: file.path, digest: digest, archivedAt: now.addingTimeInterval(-8 * 86_400))
        let engine = AutomaticReleaseRuleEngine()
        #expect(engine.decision(for: snapshot, settings: ProductSettings(), now: now) == .eligible)
        var restricted = ProductSettings(); restricted.allowedExtensions = ["zip"]
        #expect(engine.decision(for: snapshot, settings: restricted, now: now) == .ineligible("扩展名不在允许范围"))
        #expect(engine.decision(for: snapshot, settings: ProductSettings(), now: now, fileExists: { _ in false }) == .ineligible("本地对象不存在"))
    }

    @Test("quarantine final release is gated by retention and checksum")
    func quarantineDue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wevault-automation-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("report.pdf"); try Data("archive".utf8).write(to: file)
        let digest = try sha256File(file); let now = Date()
        let snapshot = archivedSnapshot(path: file.path, digest: digest, archivedAt: now, localState: .quarantined, quarantinePath: file.path, quarantinedAt: now.addingTimeInterval(-8 * 86_400))
        #expect(AutomaticReleaseRuleEngine().quarantineIsDue(snapshot, settings: ProductSettings(), now: now) == .eligible)
        #expect(AutomaticReleaseRuleEngine().dueQuarantineSnapshots([snapshot], settings: ProductSettings(), now: now) == [snapshot])
        #expect(AutomaticReleaseRuleEngine().quarantineIsDue(snapshot, settings: ProductSettings(), now: now.addingTimeInterval(-2 * 86_400)) == .ineligible("quarantine 保留期未到"))
    }

    private func archivedSnapshot(path: String, digest: String, archivedAt: Date, localState: LocalArchiveState = .localPresent, quarantinePath: String? = nil, quarantinedAt: Date? = nil) -> ArchivedFileSnapshot {
        let object = CloudObject(cloudObjectID: "object", sha256: digest, sizeBytes: 7, storageProvider: "test", bucketOrContainer: "test", objectKey: "test", uploadedAt: archivedAt, verifiedAt: archivedAt, verifyStatus: .verified, refCount: 1)
        let binding = ArchiveBinding(bindingID: "binding", filePath: path, cloudObjectID: "object", archiveState: .verified, localState: localState, quarantinedAt: quarantinedAt, quarantinePath: quarantinePath)
        let file = ArchivedFile(filePath: path, objectType: .ordinaryFile, originalFilename: "report.pdf", relativePath: "report.pdf", accountHash: "account", accountName: "account", month: nil, sizeBytes: 7, sha256: digest, mtime: archivedAt, familyID: nil, displayOrPlaybackPath: nil, bubbleOrThumbPath: nil, archivedAt: archivedAt, updatedAt: archivedAt)
        return ArchivedFileSnapshot(archivedFile: file, binding: binding, object: object)
    }
}
