import Foundation
import Combine
import SwiftUI
import WeVaultCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings: ProductSettings
    @Published var isSettingsPresented = false
    @Published var manualScanRequestID: UUID?
    @Published private(set) var automationSnapshot: AutomationTaskSnapshot?
    @Published private(set) var isAutomationRunning = false
    let scanViewModel = ScanViewModel()
    let managedAccount = ManagedAccount()
    let selfManagedCloud = SelfManagedCloud()

    private let defaults: UserDefaults
    private let settingsKey = "product-settings-v1"
    private let scheduler: AutomationScheduler?
    private var automationLoop: Task<Void, Never>?
    private var accountReadinessCancellable: AnyCancellable?
    private var activeAutomationRefreshes = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(ProductSettings.self, from: data) {
            var normalized = decoded
            normalized.normalize()
            settings = normalized
        } else {
            settings = .default
        }
        scheduler = try? AutomationScheduler(store: ManifestStore())
        // Restore the persisted root before the first due-task evaluation.
        scanViewModel.apply(settings)
        accountReadinessCancellable = managedAccount.$isReady
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ready in
                self?.refreshAutomation(wakeWaiting: ready)
            }
        refreshAutomation(wakeWaiting: prerequisitesAppearReady)
        automationLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshAutomationNow()
            }
        }
    }

    func save(_ newSettings: ProductSettings) {
        var normalized = newSettings
        normalized.normalize()
        settings = normalized
        scanViewModel.apply(normalized)
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: settingsKey)
        }
        refreshAutomation(wakeWaiting: prerequisitesAppearReady)
    }

    func completeOnboarding(_ newSettings: ProductSettings) {
        var completed = newSettings
        completed.onboardingCompleted = true
        save(completed)
    }

    func toggleAutomation() {
        var updated = settings
        updated.automaticTasksEnabled.toggle()
        save(updated)
    }

    func requestManualScan() {
        manualScanRequestID = UUID()
    }

    var automationSummary: String {
        guard let snapshot = automationSnapshot else { return "自动任务准备中" }
        if snapshot.task.isPaused { return "自动任务已暂停" }
        if let run = snapshot.latestRun, run.status == .running { return "自动任务正在运行" }
        if let run = snapshot.latestRun, run.status == .waitingForCloud { return run.failureReason ?? "自动任务等待云端条件" }
        return "下次自动任务：\(snapshot.task.nextRunAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var canRunAutomationNow: Bool {
        settings.automaticTasksEnabled && !isAutomationRunning
    }

    func runAutomationNow() {
        guard canRunAutomationNow else { return }
        Task { [weak self] in
            guard let self, let scheduler = self.scheduler else { return }
            do {
                _ = try await scheduler.configure(settings: self.settings)
                _ = try await scheduler.makeDueNow()
            } catch {
                return
            }
            await self.refreshAutomationNow()
        }
    }

    func refreshAutomation(wakeWaiting: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            if wakeWaiting, let scheduler = self.scheduler {
                _ = try? await scheduler.wakeWaitingTask()
            }
            await self.refreshAutomationNow()
        }
    }

    private var prerequisitesAppearReady: Bool {
        guard settings.cloudMode == .weVault, managedAccount.isReady,
              let root = scanViewModel.selectedRoot else { return false }
        return scanRootIsAvailable(root)
    }

    private func scanRootIsAvailable(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) &&
            isDirectory.boolValue && FileManager.default.isReadableFile(atPath: root.path)
    }

    private func beginAutomationRefresh() {
        activeAutomationRefreshes += 1
        isAutomationRunning = true
    }

    private func endAutomationRefresh() {
        activeAutomationRefreshes = max(0, activeAutomationRefreshes - 1)
        isAutomationRunning = activeAutomationRefreshes > 0
    }

    private func refreshAutomationNow() async {
        guard let scheduler else { return }
        beginAutomationRefresh()
        defer { endAutomationRefresh() }
        let settings = settings
        do {
            _ = try await scheduler.configure(settings: settings)
            let gate: AutomationCloudGate
            let pipeline: AutomationPipeline?
            var waitingReason: String?
            if settings.cloudMode != .weVault {
                gate = .unavailable
                pipeline = nil
                waitingReason = "自动上传当前仅支持 WeVault 云端模式"
            } else if !managedAccount.isReady {
                gate = .unavailable
                pipeline = nil
                waitingReason = "请先登录 WeVault 云端并完成设备注册"
            } else if scanViewModel.selectedRoot == nil {
                gate = .unavailable
                pipeline = nil
                waitingReason = "请先在设置中选择微信扫描目录"
            } else if let root = scanViewModel.selectedRoot, !scanRootIsAvailable(root) {
                gate = .unavailable
                pipeline = nil
                waitingReason = "已保存的微信扫描目录不存在或不可用"
            } else if let root = scanViewModel.selectedRoot {
                let authorization: (api: WeVaultAPIClient, accessToken: String, deviceID: String)
                do {
                    authorization = try await managedAccount.withAuthorizedDevice()
                } catch {
                    gate = .unavailable
                    pipeline = nil
                    waitingReason = "云端授权不可用：\(error.localizedDescription)"
                    _ = try await scheduler.runDueTasks(cloudGate: gate, pipeline: pipeline, waitingReason: waitingReason)
                    automationSnapshot = try await scheduler.snapshot()
                    scanViewModel.reloadActivity()
                    return
                }
                gate = .available
                let threshold = Int64(settings.largeFileThresholdMB * 1024 * 1024)
                let viewModel = scanViewModel
                pipeline = { [root, threshold, authorization, settings, viewModel] in
                    let scanned = try await Task.detached(priority: .utility) {
                        let store = try ManifestStore()
                        let placeholders = try store.archivedFileSnapshots().values.compactMap(\.binding.placeholderPath)
                        let result = try WeChatScanner().scan(root: root, options: ScanOptions(largeFileThresholdBytes: threshold, knownPlaceholderPaths: Set(placeholders)))
                        try store.save(scanResult: result)
                        return result
                    }.value
                    let candidates = AutomaticUploadCandidateSelector().candidates(from: scanned.files, settings: settings)
                    let store = try ManifestStore()
                    let report = try await ManagedCloudArchiveService().uploadWithReport(files: candidates, families: scanned.families, api: authorization.api, accessToken: authorization.accessToken, deviceId: authorization.deviceID, store: store)
                    let archivedSnapshots = try store.archivedFileSnapshots()
                    await viewModel.applyAutomationResult(
                        scanned,
                        root: root,
                        cloudSnapshots: report.snapshots,
                        archivedSnapshots: archivedSnapshots,
                        failedPaths: Set(report.failures.map(\.filePath))
                    )
                    let summary = report.failures.isEmpty ? nil : "\(report.failures.count) 个对象上传或服务端校验失败：\(report.failures[0].reason)"
                    return AutomationPipelineResult(completedUnits: report.verifiedCount, totalUnits: report.attemptedCount, failedUnits: report.failures.count, failureSummary: summary)
                }
            } else {
                gate = .unavailable
                pipeline = nil
                waitingReason = "扫描目录不可用"
            }
            _ = try await scheduler.runDueTasks(cloudGate: gate, pipeline: pipeline, waitingReason: waitingReason)
            automationSnapshot = try await scheduler.snapshot()
            scanViewModel.reloadActivity()
        } catch {
            // The manifest operation log remains the durable diagnostic source.
        }
    }

    deinit { automationLoop?.cancel() }
}
