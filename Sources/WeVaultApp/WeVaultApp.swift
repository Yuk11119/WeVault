import SwiftUI

/// `swift run` starts a bare executable rather than a Finder-launched app bundle.
/// Explicit activation prevents the visible SwiftUI window from remaining behind
/// the terminal (or another app) as a non-key window.
@MainActor
final class WeVaultAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppState.shared.openRestoreURL(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activateStatusWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activateStatusWindow()
        return true
    }

    private func activateStatusWindow() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.windows.first(where: { $0.title == "WeVault 恢复中心" }) ?? NSApp.windows.first(where: { $0.canBecomeKey }))?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct WeVaultApp: App {
    @NSApplicationDelegateAdaptor(WeVaultAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

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
                    managedAccount: appState.managedAccount,
                    selfManagedCloud: appState.selfManagedCloud,
                    settings: appState.settings,
                    automationSnapshot: appState.automationSnapshot,
                    isAutomationRunning: appState.isAutomationRunning,
                    runAutomationNow: appState.runAutomationNow,
                    openSettings: { appState.isSettingsPresented = true }
                )
            } else {
                SetupWizard { appState.completeOnboarding($0) }
            }
        }
        .onAppear {
            appState.scanViewModel.apply(appState.settings)
            appState.scanViewModel.reloadActivity()
            appState.refreshAutomation()
        }
        .onChange(of: appState.settings) { _, settings in appState.scanViewModel.apply(settings) }
        .onChange(of: appState.manualScanRequestID) { _, requestID in
            guard requestID != nil else { return }
            appState.scanViewModel.scan()
        }
        .sheet(isPresented: $appState.isSupportPresented) { BetaSupportView() }
        .sheet(isPresented: $appState.isSettingsPresented) {
            SettingsSheet(settings: appState.settings, managedAccount: appState.managedAccount, selfManagedCloud: appState.selfManagedCloud, onSave: appState.save)
        }
    }
}

private struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: ScanViewModel

    var body: some View {
        Text(appState.automationSummary)
        Button("打开状态中心") { openWindow(id: "status") }
        Button("打开恢复中心") { appState.openRestoreCenter() }
        Button("立即扫描") {
            openWindow(id: "status")
            appState.requestManualScan()
        }
        Button(appState.isAutomationRunning ? "自动任务运行中…" : "立即运行自动任务") {
            openWindow(id: "status")
            appState.runAutomationNow()
        }
        .disabled(!appState.canRunAutomationNow)
        Button(appState.settings.automaticTasksEnabled ? "暂停自动化" : "恢复自动化") {
            appState.toggleAutomation()
        }
        Button("设置") {
            appState.isSettingsPresented = true
            openWindow(id: "status")
        }
        Button("帮助、反馈与更新") {
            openWindow(id: "status")
            appState.isSupportPresented = true
        }
        Divider()
        Button("退出 WeVault") { NSApplication.shared.terminate(nil) }
    }
}
