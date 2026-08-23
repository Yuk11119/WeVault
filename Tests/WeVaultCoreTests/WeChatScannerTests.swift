import Foundation
import SQLite3
import Testing
@testable import WeVaultCore

@Suite("WeChat scanner")
struct WeChatScannerTests {
    @Test("scans ordinary duplicates and media layer candidates")
    func scansDuplicatesAndCandidates() throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()

        let result = try WeChatScanner().scan(root: fixture.root)

        #expect(result.summary.ordinaryCount == 3)
        #expect(result.duplicateGroups.count == 1)
        #expect(result.summary.duplicateReclaimableBytes == 11)
        #expect(result.summary.imageHighCandidateCount == 1)
        #expect(result.summary.videoRawCandidateCount == 1)
        #expect(result.summary.videoRawDiscoveredCount == 2)
        #expect(result.summary.videoPlaybackDiscoveredCount == 1)

        let notArchivable = result.files.filter { $0.status == .notArchivable }
        #expect(notArchivable.contains { $0.filename == "lonely_h.dat" })
        #expect(notArchivable.contains { $0.filename == "solo_raw.mp4" })

        let duplicateFiles = result.files.filter { $0.duplicateGroupID != nil }
        #expect(duplicateFiles.count == 2)
        #expect(duplicateFiles.allSatisfy { $0.sha256 != nil })
    }

    @Test("manifest can be saved repeatedly")
    func manifestCanBeSavedRepeatedly() throws {
        let fixture = try Fixture()
        try fixture.writeWeChatTree()
        let result = try WeChatScanner().scan(root: fixture.root)

        let store = try ManifestStore(databaseURL: fixture.temp.appendingPathComponent("archive.sqlite"))
        try store.save(scanResult: result)
        try store.save(scanResult: result)

        #expect(try fixture.countRows(table: "files") == result.files.count)
        #expect(try fixture.countRows(table: "families") == result.families.count)
        #expect(try fixture.countRows(table: "duplicate_groups") == result.duplicateGroups.count)
    }
}

private struct Fixture {
    let temp: URL
    let root: URL

    init() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("WeVaultTests-\(UUID().uuidString)", isDirectory: true)
        root = temp.appendingPathComponent("xwechat_files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeWeChatTree() throws {
        let account = root.appendingPathComponent("wxid_demo", isDirectory: true)

        try write("duplicate-a", to: account.appendingPathComponent("msg/file/2026-01/a.pdf"))
        try write("duplicate-a", to: account.appendingPathComponent("msg/file/2026-02/b.pdf"))
        try write("unique-file", to: account.appendingPathComponent("msg/file/2026-02/c.zip"))

        try write("normal", to: account.appendingPathComponent("msg/attach/res1/Img/2026-01/photo.dat"))
        try write("high-resolution", to: account.appendingPathComponent("msg/attach/res1/Img/2026-01/photo_h.dat"))
        try write("high-only", to: account.appendingPathComponent("msg/attach/res2/Img/2026-01/lonely_h.dat"))

        try write("play", to: account.appendingPathComponent("msg/video/2026-01/clip.mp4"))
        try write("raw-video-larger", to: account.appendingPathComponent("msg/video/2026-01/clip_raw.mp4"))
        try write("thumb", to: account.appendingPathComponent("msg/video/2026-01/clip_thumb.jpg"))
        try write("cover", to: account.appendingPathComponent("msg/video/2026-01/clip.jpg"))
        try write("raw-only", to: account.appendingPathComponent("msg/video/2026-01/solo_raw.mp4"))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func countRows(table: String) throws -> Int {
        var db: OpaquePointer?
        let path = temp.appendingPathComponent("archive.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw WeVaultError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK else {
            throw WeVaultError.sqlite("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WeVaultError.sqlite("count failed")
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
