import Foundation
import SwiftUI
import WeVaultCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var settings: ProductSettings
    @Published var isSettingsPresented = false
    @Published var manualScanRequestID: UUID?
    let scanViewModel = ScanViewModel()

    private let defaults: UserDefaults
    private let settingsKey = "product-settings-v1"

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
    }

    func save(_ newSettings: ProductSettings) {
        var normalized = newSettings
        normalized.normalize()
        settings = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: settingsKey)
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
}
