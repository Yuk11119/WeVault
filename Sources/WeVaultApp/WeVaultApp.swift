import SwiftUI

@main
struct WeVaultApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("WeVault 状态中心", id: "status") {
            StatusCenter(appState: appState)
        }
        .defaultSize(width: 1280, height: 760)

        MenuBarExtra("WeVault", systemImage: appState.settings.automaticTasksEnabled ? "archivebox.fill" : "pause.circle") {
            MenuBarView(appState: appState, viewModel: appState.scanViewModel)
        }
    }
}

private struct StatusCenter: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            if appState.settings.onboardingCompleted {
                ContentView(
                    viewModel: appState.scanViewModel,
                    settings: appState.settings,
                    openSettings: { appState.isSettingsPresented = true }
                )
            } else {
                SetupWizard { appState.completeOnboarding($0) }
            }
        }
        .onAppear {
            appState.scanViewModel.apply(appState.settings)
            appState.scanViewModel.reloadActivity()
        }
        .onChange(of: appState.settings) { _, settings in appState.scanViewModel.apply(settings) }
        .onChange(of: appState.manualScanRequestID) { _, requestID in
            guard requestID != nil else { return }
            appState.scanViewModel.scan()
        }
        .sheet(isPresented: $appState.isSettingsPresented) {
            SettingsSheet(settings: appState.settings, onSave: appState.save)
        }
    }
}

private struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: ScanViewModel

    var body: some View {
        Text(viewModel.activitySummary)
        Button("打开状态中心") { openWindow(id: "status") }
        Button("立即扫描") {
            openWindow(id: "status")
            appState.requestManualScan()
        }
        Button(appState.settings.automaticTasksEnabled ? "暂停自动化" : "恢复自动化") {
            appState.toggleAutomation()
        }
        Button("设置") {
            appState.isSettingsPresented = true
            openWindow(id: "status")
        }
        Divider()
        Button("退出 WeVault") { NSApplication.shared.terminate(nil) }
    }
}
