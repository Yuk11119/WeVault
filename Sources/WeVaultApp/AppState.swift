import Foundation
import SwiftUI
import WeVaultCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings: ProductSettings
    @Published var isSettingsPresented = false
    @Published var manualScanRequestID: UUID?
    @Published private(set) var automationSnapshot: AutomationTaskSnapshot?
    let scanViewModel = ScanViewModel()
    let managedAccount = ManagedAccount()
    let selfManagedCloud = SelfManagedCloud()

    private let defaults: UserDefaults
    private let settingsKey = "product-settings-v1"
    private let scheduler: AutomationScheduler?
    private var automationLoop: Task<Void, Never>?

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
        refreshAutomation()
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
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: settingsKey)
        }
        refreshAutomation()
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
        if snapshot.latestRun?.status == .waitingForCloud { return "自动任务等待 P2 云端能力" }
        return "下次自动任务：\(snapshot.task.nextRunAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func refreshAutomation() {
        Task { [weak self] in await self?.refreshAutomationNow() }
    }

    private func refreshAutomationNow() async {
        guard let scheduler else { return }
        let settings = settings
        do {
            _ = try await scheduler.configure(settings: settings)
            _ = try await scheduler.runDueTasks()
            automationSnapshot = try await scheduler.snapshot()
        } catch {
            // The manifest operation log remains the durable diagnostic source.
        }
    }

    deinit { automationLoop?.cancel() }
}
