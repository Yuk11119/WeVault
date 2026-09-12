import Foundation

public actor AutomaticArchivePipeline {
    public typealias Upload = @Sendable ([FileRecord], [FamilyRecord], ManifestStore) async throws -> ManagedCloudUploadReport
    private let store: ManifestStore
    private let releaseService: LocalReleaseService
    private let now: @Sendable () -> Date
    private var completed = 0, total = 0, failed = 0
    private var firstFailure: String?

    public init(store: ManifestStore, releaseService: LocalReleaseService = LocalReleaseService(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.releaseService = releaseService; self.now = now
    }

    public func run(root: URL, settings: ProductSettings, context: AutomationExecutionContext = AutomationExecutionContext(), authorizeArchive: @Sendable (ArchivedFileSnapshot, ManifestStore) async throws -> Bool = { _, _ in true }, upload: @escaping Upload) async throws -> AutomationPipelineResult {
        guard settings.automaticTasksEnabled, settings.cloudMode == .weVault else { throw CancellationError() }
        try OperationCoordinator.shared.acquire(OperationCoordinator.pipelineKey(store.databaseURL))
        defer { OperationCoordinator.shared.release(OperationCoordinator.pipelineKey(store.databaseURL)) }
        completed = 0; total = 0; failed = 0; firstFailure = nil
        // Finish durable file commits before starting a new scan. Never guess from an old UI snapshot.
        var cursor: Int64 = 0
        while true {
            let rows = try store.workPage(ReleaseJournal.self, scope: "release-journal", after: cursor)
            if rows.isEmpty { break }
            for row in rows {
                try Task.checkCancellation()
                cursor = row.id
                guard LocalReleaseService.isUnderRoot(row.value.snapshot.archivedFile.filePath, root: root) else { continue }
                guard try await authorizeArchive(row.value.snapshot, store) else { continue }
                let key = OperationCoordinator.bindingKey(row.value.snapshot.binding.bindingID, store: store)
                total += 1
                do {
                    try OperationCoordinator.shared.acquire(key)
                    defer { OperationCoordinator.shared.release(key) }
                    try releaseService.recoverPendingRelease(bindingID: row.value.snapshot.binding.bindingID, store: store, authorization: .automatic(settings: settings, root: root, now: now()))
                    completed += 1
                } catch { try recordFailure(error, context: context) }
            }
        }
        let session = UUID().uuidString
        _ = try await WeChatScanner().scanBatches(root: root, options: ScanOptions(largeFileThresholdBytes: Int64(settings.largeFileThresholdMB) * 1024 * 1024), store: store, session: session,
            progress: { stage, count in try await context.progress(stage, completed: count, total: count) },
            consume: { [self] files, families in try await self.uploadBatch(files, families: families, settings: settings, session: session, context: context, upload: upload) })
        for finalizing in [false, true] {
            cursor = 0
            while true {
                let rows = try store.archiveBindingPage(after: cursor)
                if rows.isEmpty { break }
                for row in rows {
                    cursor = row.id
                    try Task.checkCancellation()
                    guard let snapshot = try store.archivedFileSnapshot(bindingID: row.bindingID),
                          LocalReleaseService.isUnderRoot(snapshot.archivedFile.filePath, root: root),
                          snapshot.object.storageProvider == "WeVault Managed Cloud" else { continue }
                    let engine = AutomaticReleaseRuleEngine()
                    let decision = finalizing ? engine.quarantineIsDue(snapshot, settings: settings, now: now()) : engine.decision(for: snapshot, settings: settings, now: now())
                    guard decision == .eligible else {
                        if case .ineligible(let reason) = decision {
                            try store.logAutomation(runID: context.runID, event: "AUTOMATION_OBJECT_SKIPPED", detail: "\(snapshot.archivedFile.filePath)：\(reason)")
                        }
                        continue
                    }
                    guard try await authorizeArchive(snapshot, store) else {
                        try store.logAutomation(runID: context.runID, event: "AUTOMATION_ACCOUNT_MISMATCH", detail: "当前账号无法访问该归档，保留本地副本")
                        continue
                    }
                    total += 1
                    try await context.progress(finalizing ? .finalizingQuarantine : .releasing, completed: completed, total: total)
                    do {
                        let authorization = ReleaseAuthorization.automatic(settings: settings, root: root, now: now())
                        if finalizing { _ = try releaseService.finalizeSafely(snapshot: snapshot, store: store, authorization: authorization) }
                        else { _ = try releaseService.isolate(snapshot: snapshot, store: store, authorization: authorization, createTombstone: settings.createTombstones) }
                        completed += 1
                    } catch { try recordFailure(error, context: context) }
                }
            }
        }
        return AutomationPipelineResult(completedUnits: completed, totalUnits: total, failedUnits: failed, failureSummary: firstFailure)
    }

    private func uploadBatch(_ files: [FileRecord], families: [FamilyRecord], settings: ProductSettings, session: String, context: AutomationExecutionContext, upload: Upload) async throws {
        let candidates = AutomaticUploadCandidateSelector().candidates(from: files, settings: settings)
        guard !candidates.isEmpty else { return }
        try await context.progress(.uploading, completed: completed, total: total + candidates.count)
        let report = try await upload(candidates, families, store)
        completed += report.verifiedCount; total += report.attemptedCount; failed += report.failures.count
        if let networkFailure = report.failures.first(where: { $0.reason.contains("（NETWORK_UNAVAILABLE）") }) {
            firstFailure = networkFailure.reason
        } else if firstFailure == nil { firstFailure = report.failures.first?.reason }
        let failures = Set(report.failures.map(\.filePath))
        for var file in files where candidates.contains(where: { $0.path == file.path }) {
            file.status = failures.contains(file.path) ? .uploadFailed : .verified
            try store.workPut(scope: session + ".files", key: file.path, value: file, group: file.objectType == .ordinaryFile ? file.sha256 : nil)
        }
        try await context.progress(.uploading, completed: completed, total: total)
    }

    private func recordFailure(_ error: Error, context: AutomationExecutionContext) throws {
        if AutomationFailure.isFatal(error) { throw error }
        failed += 1
        let failure = UserFacingFailure.describe(error)
        if firstFailure == nil || failure.code == "NETWORK_UNAVAILABLE" { firstFailure = failure.description }
        try store.logAutomation(runID: context.runID, event: "AUTOMATION_OBJECT_FAILED", detail: UserFacingFailure.describe(error).description)
    }
}

extension ManagedCloudArchiveService {
    /// Each worker owns a SQLite connection; only two distinct SHA groups are in flight.
    public func uploadBatch(files: [FileRecord], families: [FamilyRecord], api: WeVaultAPIClient, accessToken: String, deviceID: String, store: ManifestStore) async throws -> ManagedCloudUploadReport {
        let groups = Array(Dictionary(grouping: files, by: { $0.sha256 ?? $0.path }).values)
        let connections = try (0..<min(2, groups.count)).map { _ in try store.reopen() }
        var verified = 0, attempted = 0
        var failures: [ManagedCloudUploadFailure] = []
        for offset in stride(from: 0, to: groups.count, by: 2) {
            try Task.checkCancellation()
            let reports = try await withThrowingTaskGroup(of: ManagedCloudUploadReport.self) { tasks in
                for (index, group) in groups[offset..<min(offset + 2, groups.count)].enumerated() {
                    let connection = connections[index]
                    tasks.addTask {
                        try await self.uploadWithReport(files: group, families: families, api: api, accessToken: accessToken, deviceId: deviceID, store: connection, includeAllSnapshots: false)
                    }
                }
                var result: [ManagedCloudUploadReport] = []
                for try await report in tasks { result.append(report) }
                return result
            }
            for report in reports { verified += report.verifiedCount; attempted += report.attemptedCount; failures += report.failures }
        }
        return ManagedCloudUploadReport(snapshots: [:], attemptedCount: attempted, verifiedCount: verified, failures: failures)
    }
}
