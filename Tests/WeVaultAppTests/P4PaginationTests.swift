import Foundation
import Testing
@testable import WeVaultApp
import WeVaultCore

@MainActor
struct P4PaginationTests {
    @Test("status center pages automatic records and refresh resets stale cursors")
    func pagination() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("p4-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("wxid_fixture")
        let files = root.appendingPathComponent("msg/file/2025-01")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for i in 0..<53 { try Data("file-\(i)".utf8).write(to: files.appendingPathComponent("\(i).txt")) }
        let store = try ManifestStore(databaseURL: base.appendingPathComponent("manifest.sqlite"), keyProvider: InMemoryManifestKeyProvider(key: Data(repeating: 0x13, count: 32)))
        _ = try await WeChatScanner().scanBatches(root: root, options: ScanOptions(), store: store) { _, _ in }
        let model = ScanViewModel(archiveStoreFactory: { store })
        model.apply(ProductSettings(scanRootPath: root.path))
        await model.waitForPage()
        #expect(model.displayFiles.count == 50)
        #expect(model.result?.summary.ordinaryCount == 53)
        model.loadAutomaticPage(next: true)
        await model.waitForPage()
        #expect(model.displayFiles.count == 3)
        #expect(model.automaticPageNumber == 2)
        #expect(!model.hasNextAutomaticPage)
        model.loadAutomaticPage(previous: true)
        await model.waitForPage()
        #expect(model.displayFiles.count == 50)
        #expect(model.automaticFilteredCount == 53)
        #expect(model.automaticTotalPages == 2)
        model.sortOrder = [KeyPathComparator(\FileRecord.sizeBytes, order: .reverse)]
        await model.waitForPage()
        #expect(model.automaticPageNumber == 1)
        let first = model.filteredFiles
        model.loadAutomaticPage(next: true)
        await model.waitForPage()
        let combined = first + model.filteredFiles
        #expect(combined.count == 53)
        #expect(Set(combined.map(\.path)).count == 53)
        #expect(zip(combined, combined.dropFirst()).allSatisfy { $0.sizeBytes >= $1.sizeBytes })
        model.filter = .image
        await model.waitForPage()
        #expect(model.automaticPageNumber == 1)
        #expect(model.automaticFilteredCount == 0)
        #expect(model.filteredFiles.isEmpty)
        #expect(!model.hasNextAutomaticPage)
        model.filter = .ordinary
        await model.waitForPage()
        #expect(model.automaticFilteredCount == 53)
        model.sortOrder = [KeyPathComparator(\FileRecord.filename, comparator: .localizedStandard, order: .reverse)]
        await model.waitForPage()
        #expect(model.filteredFiles.first?.filename == "52.txt")
        model.loadAutomaticPage(next: true)
        await model.waitForPage()
        #expect(model.filteredFiles.last?.filename == "0.txt")
        model.loadAutomaticPage(previous: true)
        await model.waitForPage()
        #expect(model.filteredFiles.first?.filename == "52.txt")
        _ = try await WeChatScanner().scanBatches(root: root, options: ScanOptions(), store: store) { _, _ in }
        model.loadAutomaticPage(next: true)
        await model.waitForPage()
        #expect(model.automaticPageNumber == 1)
        #expect(model.displayFiles.count == 50)
        model.apply(ProductSettings(scanRootPath: base.appendingPathComponent("wxid_other").path))
        await model.waitForPage()
        #expect(model.displayFiles.isEmpty)
        model.apply(ProductSettings(scanRootPath: root.path))
        model.filter = .image // Change the filter before the first background page returns.
        await model.waitForPage()
        #expect(model.filteredFiles.isEmpty && model.automaticFilteredCount == 0)
        model.filter = .ordinary
        model.apply(ProductSettings(scanRootPath: base.appendingPathComponent("wxid_other").path))
        await model.waitForPage()
        #expect(model.displayFiles.isEmpty) // A stale worker cannot republish the old root.
    }
}
