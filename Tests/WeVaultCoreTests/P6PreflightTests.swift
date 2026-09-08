import Foundation
import Testing
@testable import WeVaultCore

@Suite("P6 preflight regressions")
struct P6PreflightTests {
    @Test("copied tombstones stay excluded below and above threshold in both scanners")
    func copiedTombstones() async throws {
        let f = try P6Fixture(); defer { f.remove() }
        let text = Tombstone.magic + "\n这不是原文件。"
        for name in ["a.txt", "b.txt"] { try f.write("msg/file/2026-01/" + name, text) }
        for threshold: Int64 in [1, 50 * 1024 * 1024] {
            let scan = try WeChatScanner().scan(root: f.root, options: ScanOptions(largeFileThresholdBytes: threshold))
            #expect(scan.files.count == 2)
            #expect(scan.files.allSatisfy { $0.status == .notArchivable && $0.sha256 == nil && $0.duplicateGroupID == nil })
            #expect(scan.duplicateGroups.isEmpty)
            #expect(scan.summary.largeOrdinaryCount == 0)
            let session = try await WeChatScanner().scanBatches(root: f.root, options: ScanOptions(largeFileThresholdBytes: threshold), store: f.store) { files, _ in
                #expect(files.allSatisfy { $0.status == .notArchivable && $0.sha256 == nil })
                #expect(AutomaticUploadCandidateSelector().candidates(from: files, settings: .default).isEmpty)
                #expect(files.allSatisfy { $0.candidateReason?.contains("疑似转发") == true })
            }
            let records = try f.store.workPage(FileRecord.self, scope: session + ".files")
            #expect(records.count == 2)
            #expect(records.allSatisfy { $0.value.duplicateGroupID == nil })
        }
    }

    @Test("old image cache bubble joins only the matching account month resource and prefix")
    func cachedImageBubble() async throws {
        let f = try P6Fixture(); defer { f.remove() }
        try f.write("msg/attach/resource/2026-01/Img/photo_h_M.dat", "high")
        try f.write("msg/attach/resource/2026-01/Img/photo_M.dat", "normal")
        for path in ["cache/2025-12/Message/resource/Bubble/photo_b.dat", "cache/2026-01/Message/other/Bubble/photo_b.dat", "cache/2026-01/Message/resource/Bubble/other_b.dat"] {
            try f.write(path, "wrong family")
        }
        let other = f.root.appendingPathComponent("wxid_other/cache/2026-01/Message/resource/Bubble/photo_b.dat")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other account".utf8).write(to: other)
        var scan = try WeChatScanner().scan(root: f.root)
        #expect(try #require(scan.families.first).bubbleOrThumbPath == nil)
        let bubble = try f.write("cache/2026-01/Message/resource/Bubble/photo_b.dat", "bubble").resolvingSymlinksInPath()
        scan = try WeChatScanner().scan(root: f.root)
        let family = try #require(scan.families.first)
        #expect(family.bubbleOrThumbPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == bubble)
        #expect(family.memberPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }.contains(bubble))
        #expect(scan.files.count == 1) // Cache files are retained dependencies, never upload candidates.
        let session = try await WeChatScanner().scanBatches(root: f.root, options: ScanOptions(), store: f.store) { files, families in
            #expect(files.count == 1)
            #expect(families.first?.bubbleOrThumbPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == bubble)
        }
        let saved = try f.store.workPage(FamilyRecord.self, scope: session + ".families")
        #expect(saved.first?.value.bubbleOrThumbPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == bubble)
        try FileManager.default.removeItem(at: bubble)
        try FileManager.default.createSymbolicLink(at: bubble, withDestinationURL: other)
        scan = try WeChatScanner().scan(root: f.root)
        #expect(try #require(scan.families.first).bubbleOrThumbPath == nil)
    }
}

private struct P6Fixture {
    let base: URL
    let root: URL
    let account: URL
    let store: ManifestStore
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WeVaultP6-" + UUID().uuidString)
        root = base.appendingPathComponent("xwechat_files")
        account = root.appendingPathComponent("wxid_fixture")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        store = try ManifestStore(databaseURL: base.appendingPathComponent("manifest.sqlite"), keyProvider: InMemoryManifestKeyProvider())
    }
    @discardableResult func write(_ relative: String, _ text: String) throws -> URL {
        let url = account.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
