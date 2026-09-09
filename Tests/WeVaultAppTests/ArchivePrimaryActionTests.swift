import Testing
import WeVaultCore
@testable import WeVaultApp

struct ArchivePrimaryActionTests {
    @Test("setup and account prerequisites lead to actionable setup instead of a dead organize button")
    func prerequisites() {
        var settings = ProductSettings(onboardingCompleted: true)
        #expect(ArchivePrimaryAction.resolve(settings: settings, hasRoot: false, accountReady: false, storageReady: false) == .chooseFolder)
        #expect(ArchivePrimaryAction.resolve(settings: settings, hasRoot: true, accountReady: false, storageReady: false) == .login)
        #expect(ArchivePrimaryAction.resolve(settings: settings, hasRoot: true, accountReady: true, storageReady: false) == .reviewRules)
        settings.riskAcknowledgementVersion = 1
        #expect(ArchivePrimaryAction.resolve(settings: settings, hasRoot: true, accountReady: true, storageReady: false) == .organize)
        settings.automaticTasksEnabled = false
        #expect(ArchivePrimaryAction.resolve(settings: settings, hasRoot: true, accountReady: true, storageReady: false) == .enableAutomation)
    }

    @Test("self-managed storage never advertises the managed automatic-release pipeline")
    func selfManaged() {
        let settings = ProductSettings(cloudMode: .selfManaged)
        #expect(ArchivePrimaryAction.resolve(settings: settings, hasRoot: true, accountReady: true, storageReady: false) == .configureStorage)
        #expect(ArchivePrimaryAction.resolve(settings: settings, hasRoot: true, accountReady: false, storageReady: true) == .upload)
    }
}
