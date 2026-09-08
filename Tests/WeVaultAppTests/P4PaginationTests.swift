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
        #expect(model.displayFiles.count == 50)
        #expect(model.result?.summary.ordinaryCount == 53)
        model.loadAutomaticPage(next: true)
        #expect(model.displayFiles.count == 3)
        #expect(model.automaticPageNumber == 2)
        #expect(!model.hasNextAutomaticPage)
        model.loadAutomaticPage(previous: true)
        #expect(model.displayFiles.count == 50)
        #expect(model.automaticFilteredCount == 53)
        #expect(model.automaticTotalPages == 2)
        model.sortOrder = [KeyPathComparator(\FileRecord.sizeBytes, order: .reverse)]
        #expect(model.automaticPageNumber == 1)
        let first = model.filteredFiles
        model.loadAutomaticPage(next: true)
        let combined = first + model.filteredFiles
        #expect(combined.count == 53)
        #expect(Set(combined.map(\.path)).count == 53)
        #expect(zip(combined, combined.dropFirst()).allSatisfy { $0.sizeBytes >= $1.sizeBytes })
        model.filter = .image
        #expect(model.automaticPageNumber == 1)
        #expect(model.automaticFilteredCount == 0)
        #expect(model.filteredFiles.isEmpty)
        #expect(!model.hasNextAutomaticPage)
        model.filter = .ordinary
        #expect(model.automaticFilteredCount == 53)
        model.sortOrder = [KeyPathComparator(\FileRecord.filename, comparator: .localizedStandard, order: .reverse)]
        #expect(model.filteredFiles.first?.filename == "52.txt")
        model.loadAutomaticPage(next: true)
        #expect(model.filteredFiles.last?.filename == "0.txt")
        model.loadAutomaticPage(previous: true)
        #expect(model.filteredFiles.first?.filename == "52.txt")
        _ = try await WeChatScanner().scanBatches(root: root, options: ScanOptions(), store: store) { _, _ in }
        model.loadAutomaticPage(next: true)
        #expect(model.automaticPageNumber == 1)
        #expect(model.displayFiles.count == 50)
        model.apply(ProductSettings(scanRootPath: base.appendingPathComponent("wxid_other").path))
        #expect(model.displayFiles.isEmpty)
    }
}
