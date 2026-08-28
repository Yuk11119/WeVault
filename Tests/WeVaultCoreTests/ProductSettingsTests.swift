import Foundation
import Testing
@testable import WeVaultCore

@Suite("Product settings")
struct ProductSettingsTests {
    @Test("beta defaults match the approved automation policy")
    func defaultsMatchBetaPolicy() {
        let settings = ProductSettings.default

        #expect(!settings.onboardingCompleted)
        #expect(settings.automaticTasksEnabled)
        #expect(settings.runIntervalHours == 24)
        #expect(settings.coolingPeriodDays == 7)
        #expect(settings.quarantineRetentionDays == 7)
        #expect(settings.createTombstones)
        #expect(settings.archiveOrdinaryFiles)
        #expect(settings.archiveImageHighLayers)
        #expect(settings.archiveVideoRawLayers)
        #expect(settings.cloudMode == .weVault)
    }

    @Test("normalization bounds values and canonicalizes extensions")
    func normalizationIsSafeAndDeterministic() {
        var settings = ProductSettings(
            scanRootPath: "   ",
            largeFileThresholdMB: 999,
            runIntervalHours: 0,
            coolingPeriodDays: -1,
            quarantineRetentionDays: 0,
            allowedExtensions: [" .PDF ", "pdf", " ZIP", "", " .zip "]
        )

        settings.normalize()

        #expect(settings.scanRootPath == nil)
        #expect(settings.largeFileThresholdMB == 500)
        #expect(settings.runIntervalHours == 1)
        #expect(settings.coolingPeriodDays == 0)
        #expect(settings.quarantineRetentionDays == 1)
        #expect(settings.allowedExtensions == ["pdf", "zip"])
    }

    @Test("manifest activity exposes newest operations and failure state")
    func recentOperationsAreOrderedAndClassified() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wevault-operations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = try ManifestStore(databaseURL: temporaryDirectory.appendingPathComponent("archive.sqlite"))
        try store.logOperation("SCAN_FINISHED", detail: "files=3")
        try store.logOperation("UPLOAD_FAILED", detail: "network unavailable")

        let operations = try store.recentOperations(limit: 10)
        #expect(operations.count == 2)
        #expect(operations[0].event == "UPLOAD_FAILED")
        #expect(operations[0].isFailure)
        #expect(!operations[1].isFailure)
    }
}
