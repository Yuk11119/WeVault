import Foundation
import Combine
import SwiftUI
import WeVaultCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    let restoreCenter = RestoreCenterModel()
    private var restoreWindow: NSWindowController?

    func openRestoreURL(_ url: URL) {
        #if DEBUG
        if let root = DevelopmentIsolation.root {
            try? Data(url.absoluteString.utf8).write(to: root.appendingPathComponent("last-incoming-url.txt"))
        }
        #endif
        do { openRestoreCenter(bindingID: try RestoreLink(url: url).bindingID) }
        catch {
            openRestoreCenter()
            restoreCenter.rejectLink("恢复链接不完整或格式不受支持。请复制占位文件中的完整归档编号，在上方粘贴并点击“定位”。")
        }
    }

    func openRestoreCenter(bindingID: String? = nil) {
        if restoreWindow == nil {
            let controller = NSHostingController(rootView: RestoreCenterView(appState: self, model: restoreCenter, operations: scanViewModel))
            let window = NSWindow(contentViewController: controller)
            window.title = "WeVault 恢复中心"
            window.setContentSize(NSSize(width: 960, height: 640))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            restoreWindow = NSWindowController(window: window)
        }
        restoreCenter.load(bindingID: bindingID)
        restoreWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        restoreWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @Published private(set) var settings: ProductSettings
    @Published var isSettingsPresented = false
    @Published var isSupportPresented = false
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
    private var configurationGeneration = 0

    init(defaults: UserDefaults = .standard) {
        let defaults = DevelopmentIsolation.root == nil ? defaults : UserDefaults(suiteName: "online.wevault.p5-fixtures")!
        self.defaults = defaults
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(ProductSettings.self, from: data) {
            var normalized = decoded
            normalized.normalize()
            settings = normalized
        } else {
            settings = .default
        }
        if DevelopmentIsolation.root != nil {
            settings = ProductSettings(onboardingCompleted: true, automaticTasksEnabled: false)
        }
        do { scheduler = try AutomationScheduler(store: ManifestStore()) }
        catch { scheduler = nil; scanViewModel.alertMessage = UserFacingFailure.describe(error).description }
        // Restore the persisted root before the first due-task evaluation.
        scanViewModel.apply(settings)
        accountReadinessCancellable = managedAccount.$isReady
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ready in
                Task { [weak self] in
                    guard let self else { return }
                    self.configurationGeneration += 1
                    await self.scheduler?.cancelActiveRun()
                    self.refreshAutomation(wakeWaiting: ready)
                }
            }
        refreshAutomation(wakeWaiting: prerequisitesAppearReady)
        automationLoop = Task { [weak self] in
            while !Task.isCancelled {
                let delay: UInt64 = self?.isAutomationRunning == true ? 1_000_000_000 : 15_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self?.refreshAutomation()
            }
        }
    }

    func save(_ newSettings: ProductSettings) {
        var normalized = newSettings
        normalized.normalize()
        if DevelopmentIsolation.root != nil { normalized.automaticTasksEnabled = false; normalized.scanRootPath = nil }
        configurationGeneration += 1
        settings = normalized
        scanViewModel.apply(normalized)
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: settingsKey)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.scheduler?.cancelActiveRun()
            self.refreshAutomation(wakeWaiting: self.prerequisitesAppearReady)
        }
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
        if settings.riskAcknowledgementVersion != 1 { return "请在设置中阅读并确认归档风险，自动任务尚未启用" }
        guard let snapshot = automationSnapshot else { return "自动任务准备中" }
        if snapshot.task.isPaused { return "自动任务已暂停" }
        if let run = snapshot.latestRun, run.status == .running { return "\(run.stage.displayName)：\(run.completedUnits)/\(run.totalUnits)" }
        if let run = snapshot.latestRun, run.status == .failed { return "自动任务失败：\(run.failureReason ?? "请重试")" }
        if let run = snapshot.latestRun, run.status == .waitingForCloud { return run.failureReason ?? "自动任务等待云端条件" }
        return "下次自动任务：\(snapshot.task.nextRunAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var canRunAutomationNow: Bool {
        settings.automaticExecutionPermitted && settings.cloudMode == .weVault && managedAccount.isReady &&
            scanViewModel.selectedRoot != nil && !isAutomationRunning && !scanViewModel.isScanning &&
            !scanViewModel.isUploading && !scanViewModel.isRestoring && !scanViewModel.isReleasing
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
    }

    private func endAutomationRefresh() {
        activeAutomationRefreshes = max(0, activeAutomationRefreshes - 1)
        isAutomationRunning = activeAutomationRefreshes > 0
    }

    private func refreshAutomationNow() async {
        guard let scheduler else { return }
        if activeAutomationRefreshes > 0 {
            automationSnapshot = try? await scheduler.snapshot()
            return
        }
        beginAutomationRefresh()
        defer { endAutomationRefresh() }
        var settings = settings
        if !settings.automaticExecutionPermitted { settings.automaticTasksEnabled = false }
        let generation = configurationGeneration
        do {
            let configured = try await scheduler.configure(settings: settings)
            let hasImmediateRequest = await scheduler.hasImmediateRunRequest()
            if configured.isPaused || (configured.nextRunAt > Date() && !hasImmediateRequest) {
                automationSnapshot = try await scheduler.snapshot()
                return
            }
            isAutomationRunning = true
            let gate: AutomationCloudGate
            let pipeline: ContextAutomationPipeline?
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
                    waitingReason = "云端授权不可用：\(UserFacingFailure.describe(error).description)"
                    _ = try await scheduler.runDueTasks(cloudGate: gate, contextPipeline: pipeline, waitingReason: waitingReason)
                    automationSnapshot = try await scheduler.snapshot()
                    scanViewModel.reloadActivity()
                    return
                }
                guard generation == configurationGeneration, self.settings == settings, managedAccount.isReady else { return }
                gate = .available
                pipeline = { [root, authorization, settings] context in
                    let store = try ManifestStore()
                    return try await AutomaticArchivePipeline(store: store).run(root: root, settings: settings, context: context, authorizeArchive: { snapshot, connection in
                        let refreshed = try await self.managedAccount.withAuthorizedDevice()
                        guard refreshed.deviceID == authorization.deviceID else { throw CancellationError() }
                        return try await ManagedCloudArchiveService().isAuthorizedArchive(snapshot, api: refreshed.api, accessToken: refreshed.accessToken, deviceID: refreshed.deviceID, store: connection)
                    }) { files, families, connection in
                        let refreshed = try await self.managedAccount.withAuthorizedDevice()
                        guard refreshed.deviceID == authorization.deviceID else { throw CancellationError() }
                        return try await ManagedCloudArchiveService().uploadBatch(files: files, families: families, api: refreshed.api, accessToken: refreshed.accessToken, deviceID: refreshed.deviceID, store: connection)
                    }
                }
            } else {
                gate = .unavailable
                pipeline = nil
                waitingReason = "扫描目录不可用"
            }
            _ = try await scheduler.runDueTasks(cloudGate: gate, contextPipeline: pipeline, waitingReason: waitingReason)
            automationSnapshot = try await scheduler.snapshot()
            scanViewModel.loadAutomaticPage(reset: true)
            scanViewModel.reloadActivity()
        } catch {
            scanViewModel.alertMessage = UserFacingFailure.describe(error).description
        }
    }

    deinit { automationLoop?.cancel() }
}
