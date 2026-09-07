import Foundation

public enum AutomationRunStatus: String, Codable, CaseIterable, Sendable {
    case scheduled = "SCHEDULED"
    case running = "RUNNING"
    case waitingForCloud = "WAITING_FOR_CLOUD"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case paused = "PAUSED"
}

public enum AutomationStage: String, Codable, CaseIterable, Sendable {
    case scheduling = "SCHEDULING"
    case scanning = "SCANNING"
    case hashing = "HASHING"
    case uploading = "UPLOADING"
    case releasing = "RELEASING"
    case finalizingQuarantine = "FINALIZING_QUARANTINE"
    case waitingForCloud = "WAITING_FOR_CLOUD"
    case finished = "FINISHED"
}

public struct AutomationTask: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let isPaused: Bool
    public let intervalHours: Int
    public let nextRunAt: Date
    public let lastRunAt: Date?

    public init(id: String = "default-automation", isPaused: Bool, intervalHours: Int, nextRunAt: Date, lastRunAt: Date? = nil) {
        self.id = id; self.isPaused = isPaused; self.intervalHours = intervalHours; self.nextRunAt = nextRunAt; self.lastRunAt = lastRunAt
    }
}

public struct AutomationTaskRun: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let status: AutomationRunStatus
    public let stage: AutomationStage
    public let completedUnits: Int
    public let totalUnits: Int
    public let failureReason: String?
    public let retryOfRunID: String?
    public let startedAt: Date?
    public let finishedAt: Date?

    public init(id: String = UUID().uuidString, taskID: String, status: AutomationRunStatus, stage: AutomationStage, completedUnits: Int = 0, totalUnits: Int = 0, failureReason: String? = nil, retryOfRunID: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id; self.taskID = taskID; self.status = status; self.stage = stage; self.completedUnits = completedUnits; self.totalUnits = totalUnits; self.failureReason = failureReason; self.retryOfRunID = retryOfRunID; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct AutomationTaskLog: Codable, Hashable, Sendable, Identifiable {
    public let id: Int64
    public let runID: String?
    public let event: String
    public let detail: String?
    public let createdAt: Date
}

public struct AutomationTaskSnapshot: Codable, Hashable, Sendable {
    public let task: AutomationTask
    public let latestRun: AutomationTaskRun?
    public let logs: [AutomationTaskLog]
}

/// P2 is deliberately the only future source of upload authorization. Until then this gate
/// prevents every file-processing phase, including local release and final deletion.
public enum AutomationCloudGate: Sendable { case unavailable, available }

/// The authorized work performed by an automatic P2 run.  The scheduler owns
/// durable state transitions; the app owns account authorization and scanning.
public struct AutomationPipelineResult: Equatable, Sendable {
    public let completedUnits: Int
    public let totalUnits: Int
    public let failedUnits: Int
    public let failureSummary: String?

    public init(completedUnits: Int, totalUnits: Int, failedUnits: Int = 0, failureSummary: String? = nil) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.failedUnits = failedUnits
        self.failureSummary = failureSummary
    }
}

public typealias AutomationPipeline = @Sendable () async throws -> AutomationPipelineResult

/// Execution parameters for the future authorized pipeline. They are intentionally independent
/// from storage credentials and make the P4 memory/network bounds testable before P2 exists.
public enum AutomationPipelineLimits {
    public static let scanAndHashBatchSize = 50
    public static let uploadConcurrencyLimit = 2

    public static func batches<Element>(_ values: [Element], maximumBatchSize: Int = scanAndHashBatchSize) -> [[Element]] {
        precondition(maximumBatchSize > 0)
        return stride(from: 0, to: values.count, by: maximumBatchSize).map { Array(values[$0..<min($0 + maximumBatchSize, values.count)]) }
    }
}

public actor AutomationScheduler {
    public let taskID: String
    private let store: ManifestStore
    private let cloudGate: AutomationCloudGate
    private let now: @Sendable () -> Date
    private var activeTaskIDs: Set<String> = []

    public init(store: ManifestStore, taskID: String = "default-automation", cloudGate: AutomationCloudGate = .unavailable, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.taskID = taskID; self.cloudGate = cloudGate; self.now = now
    }

    @discardableResult public func configure(settings: ProductSettings) throws -> AutomationTask {
        let current = try store.automationTask(id: taskID)
        let date = now()
        let paused = !settings.automaticTasksEnabled
        let next: Date
        if current == nil { next = date }
        else if paused { next = current!.nextRunAt }
        else if current!.isPaused { next = date.addingTimeInterval(TimeInterval(settings.runIntervalHours * 3600)) }
        else { next = current!.nextRunAt }
        let task = AutomationTask(id: taskID, isPaused: paused, intervalHours: settings.runIntervalHours, nextRunAt: next, lastRunAt: current?.lastRunAt)
        try store.saveAutomationTask(task)
        return task
    }

    /// Makes the next enabled run immediately due. Used by an explicit user action.
    @discardableResult public func makeDueNow() throws -> AutomationTask? {
        guard let task = try store.automationTask(id: taskID), !task.isPaused,
              !activeTaskIDs.contains(taskID) else { return nil }
        let updated = AutomationTask(id: task.id, isPaused: false, intervalHours: task.intervalHours, nextRunAt: now(), lastRunAt: task.lastRunAt)
        try store.saveAutomationTask(updated)
        return updated
    }

    /// Wakes only a task whose latest durable run is waiting for prerequisites.
    @discardableResult public func wakeWaitingTask() throws -> AutomationTask? {
        guard let task = try store.automationTask(id: taskID), !task.isPaused,
              try store.latestAutomationRun(taskID: taskID)?.status == .waitingForCloud else { return nil }
        let updated = AutomationTask(id: task.id, isPaused: false, intervalHours: task.intervalHours, nextRunAt: now(), lastRunAt: task.lastRunAt)
        try store.saveAutomationTask(updated)
        return updated
    }

    /// Processes only due scheduling records. An unavailable cloud gate never invokes a
    /// scanner, uploader, release service, or file API.  Successful pipelines upload and
    /// verify only; automatic local release remains deliberately opt-in and user-confirmed.
    @discardableResult public func runDueTasks(
        cloudGate override: AutomationCloudGate? = nil,
        pipeline: AutomationPipeline? = nil,
        waitingReason: String? = nil
    ) async throws -> [AutomationTaskRun] {
        let date = now()
        var runs: [AutomationTaskRun] = []
        for task in try store.dueAutomationTasks(at: date) {
            let next = date.addingTimeInterval(TimeInterval(task.intervalHours * 3600))
            let latest = try store.latestAutomationRun(taskID: task.id)
            let retryOf = latest?.status == .failed ? latest?.id : nil
            // Claim before awaiting. Actor methods are re-entrant at suspension points,
            // so this durable schedule update prevents poll/manual duplicate runs.
            try store.saveAutomationTask(AutomationTask(id: task.id, isPaused: false, intervalHours: task.intervalHours, nextRunAt: next, lastRunAt: date))
            switch override ?? cloudGate {
            case .unavailable:
                let run = AutomationTaskRun(taskID: task.id, status: .waitingForCloud, stage: .waitingForCloud, failureReason: waitingReason ?? "请先登录 WeVault 云端并完成设备注册", retryOfRunID: retryOf, startedAt: date, finishedAt: date)
                try store.saveAutomationRun(run)
                try store.logAutomation(runID: run.id, event: "AUTOMATION_WAITING_FOR_CLOUD", detail: run.failureReason)
                runs.append(run)
            case .available:
                guard let pipeline else {
                    let run = AutomationTaskRun(taskID: task.id, status: .failed, stage: .scheduling, failureReason: "已授权任务管线尚未接入", retryOfRunID: retryOf, startedAt: date, finishedAt: date)
                    try store.saveAutomationRun(run)
                    try store.logAutomation(runID: run.id, event: "AUTOMATION_PIPELINE_UNAVAILABLE", detail: run.failureReason)
                    runs.append(run)
                    continue
                }

                let running = AutomationTaskRun(taskID: task.id, status: .running, stage: .uploading, retryOfRunID: retryOf, startedAt: date)
                try store.saveAutomationRun(running)
                try store.logAutomation(runID: running.id, event: "AUTOMATION_STARTED", detail: nil)
                activeTaskIDs.insert(task.id)
                do {
                    defer { activeTaskIDs.remove(task.id) }
                    do {
                        let result = try await pipeline()
                        if result.failedUnits > 0 || result.completedUnits < result.totalUnits {
                            let reason = result.failureSummary ?? "\(result.failedUnits) 个对象上传或校验失败"
                            let failed = AutomationTaskRun(id: running.id, taskID: task.id, status: .failed, stage: .uploading, completedUnits: result.completedUnits, totalUnits: result.totalUnits, failureReason: reason, retryOfRunID: retryOf, startedAt: date, finishedAt: now())
                            try store.saveAutomationRun(failed)
                            try store.logAutomation(runID: failed.id, event: "AUTOMATION_UPLOAD_FAILED", detail: "\(result.completedUnits)/\(result.totalUnits): \(reason)")
                            runs.append(failed)
                        } else {
                            let completed = AutomationTaskRun(id: running.id, taskID: task.id, status: .completed, stage: .finished, completedUnits: result.completedUnits, totalUnits: result.totalUnits, retryOfRunID: retryOf, startedAt: date, finishedAt: now())
                            try store.saveAutomationRun(completed)
                            try store.logAutomation(runID: completed.id, event: "AUTOMATION_UPLOAD_FINISHED", detail: "\(result.completedUnits)/\(result.totalUnits)")
                            runs.append(completed)
                        }
                    } catch {
                        let failed = AutomationTaskRun(id: running.id, taskID: task.id, status: .failed, stage: .uploading, failureReason: error.localizedDescription, retryOfRunID: retryOf, startedAt: date, finishedAt: now())
                        try store.saveAutomationRun(failed)
                        try store.logAutomation(runID: failed.id, event: "AUTOMATION_UPLOAD_FAILED", detail: failed.failureReason)
                        runs.append(failed)
                    }
                }
            }
        }
        return runs
    }

    public func snapshot(logLimit: Int = 10) throws -> AutomationTaskSnapshot? {
        guard let task = try store.automationTask(id: taskID) else { return nil }
        return AutomationTaskSnapshot(task: task, latestRun: try store.latestAutomationRun(taskID: taskID), logs: try store.recentAutomationLogs(taskID: taskID, limit: logLimit))
    }
}

/// Selects local candidates for P2's automatic upload phase. Extension restrictions
/// remain part of P4's release policy and are deliberately not applied here.
public struct AutomaticUploadCandidateSelector: Sendable {
    public init() {}

    public func candidates(
        from files: [FileRecord],
        settings: ProductSettings,
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [FileRecord] {
        files.filter { file in
            guard file.sha256 != nil, fileExists(file.path) else { return false }
            guard ![.notArchivable, .tombstoned, .localReleased, .releaseEligible].contains(file.status) else { return false }
            switch file.objectType {
            case .ordinaryFile: return settings.archiveOrdinaryFiles
            case .imageHighLayer: return settings.archiveImageHighLayers
            case .videoRawLayer: return settings.archiveVideoRawLayers
            }
        }
    }
}

public enum AutomaticReleaseDecision: Equatable, Sendable {
    case eligible
    case ineligible(String)
}

public struct AutomaticReleaseRuleEngine: Sendable {
    public init() {}

    public func decision(for snapshot: ArchivedFileSnapshot, settings: ProductSettings, now: Date = Date(), fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> AutomaticReleaseDecision {
        guard snapshot.object.verifyStatus == .verified, snapshot.binding.archiveState == .verified else { return .ineligible("云端对象或归档绑定未校验") }
        guard snapshot.binding.localState == .localPresent else { return .ineligible("本地对象不是可隔离状态") }
        guard fileExists(snapshot.archivedFile.filePath) else { return .ineligible("本地对象不存在") }
        guard (try? sha256File(URL(fileURLWithPath: snapshot.archivedFile.filePath))) == snapshot.archivedFile.sha256 else { return .ineligible("本地 SHA-256 不匹配") }
        guard now.timeIntervalSince(snapshot.archivedFile.archivedAt) >= TimeInterval(settings.coolingPeriodDays * 86_400) else { return .ineligible("冷却期未到") }
        if !settings.allowedExtensions.isEmpty && !settings.allowedExtensions.contains(snapshot.archivedFile.originalFilename.split(separator: ".").last.map(String.init)?.lowercased() ?? "") { return .ineligible("扩展名不在允许范围") }
        switch snapshot.archivedFile.objectType {
        case .ordinaryFile: guard settings.archiveOrdinaryFiles else { return .ineligible("普通文件自动归档已关闭") }
        case .imageHighLayer:
            guard settings.archiveImageHighLayers, let display = snapshot.archivedFile.displayOrPlaybackPath, let thumb = snapshot.archivedFile.bubbleOrThumbPath, fileExists(display), fileExists(thumb) else { return .ineligible("图片保留层不完整或已关闭") }
        case .videoRawLayer:
            guard settings.archiveVideoRawLayers, let playback = snapshot.archivedFile.displayOrPlaybackPath, let thumb = snapshot.archivedFile.bubbleOrThumbPath, fileExists(playback), fileExists(thumb) else { return .ineligible("视频保留层不完整或已关闭") }
        }
        return .eligible
    }

    public func quarantineIsDue(_ snapshot: ArchivedFileSnapshot, settings: ProductSettings, now: Date = Date()) -> AutomaticReleaseDecision {
        guard snapshot.binding.localState == .quarantined || snapshot.binding.localState == .tombstoned else { return .ineligible("对象未处于 quarantine") }
        guard let path = snapshot.binding.quarantinePath, FileManager.default.fileExists(atPath: path) else { return .ineligible("quarantine 副本不存在") }
        guard let quarantinedAt = snapshot.binding.quarantinedAt, now.timeIntervalSince(quarantinedAt) >= TimeInterval(settings.quarantineRetentionDays * 86_400) else { return .ineligible("quarantine 保留期未到") }
        guard (try? sha256File(URL(fileURLWithPath: path))) == snapshot.archivedFile.sha256 else { return .ineligible("quarantine SHA-256 不匹配") }
        return .eligible
    }

    /// Selection only: the scheduler may hand these to LocalReleaseService.finalizeRelease
    /// after an authorized pipeline exists. P4's cloud gate never invokes that destructive call.
    public func dueQuarantineSnapshots(_ snapshots: [ArchivedFileSnapshot], settings: ProductSettings, now: Date = Date()) -> [ArchivedFileSnapshot] {
        snapshots.filter { quarantineIsDue($0, settings: settings, now: now) == .eligible }
    }
}
