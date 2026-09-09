import Foundation
import Testing
@testable import WeVaultCore

struct P7ResourceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEVAULT_P7_RESOURCE_COUNT"] != nil))
    func scanResourceFixture() async throws {
        let count = min(100_000, max(100, Int(ProcessInfo.processInfo.environment["WEVAULT_P7_RESOURCE_COUNT"] ?? "1000") ?? 1000))
        let f = try BetaFixture(); defer { f.remove() }
        for i in 0..<count { try autoreleasepool { try f.write("\(i).txt", "synthetic-\(i % 10)") } }
        if ProcessInfo.processInfo.environment["WEVAULT_P7_SCAN_MODE"] == "legacy" {
            let result = try WeChatScanner().scan(root: f.root, options: ScanOptions(largeFileThresholdBytes: 1))
            try f.store.save(scanResult: result)
            #expect(result.files.count == count)
        } else {
            let session = try await ManualArchivePipeline.scan(root: f.root, threshold: 1, store: f.store)
            #expect(try f.store.workGet(ScanSummary.self, scope: session + ".metadata", key: "summary")?.ordinaryCount == count)
            #expect(try f.store.workPage(FileRecord.self, scope: session + ".files").count <= 50)
        }
    }
}
