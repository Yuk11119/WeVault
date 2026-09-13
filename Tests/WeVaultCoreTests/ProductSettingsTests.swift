import Foundation
import SQLite3
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
        #expect(settings.quarantineRetentionDays == 0)
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

    @Test("legacy manifest migration keeps SQLite integer log identifiers")
    func legacyManifestMigrationPreservesIntegerLogIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wevault-legacy-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("archive.sqlite")

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE files (path TEXT PRIMARY KEY, object_type TEXT NOT NULL, account_hash TEXT NOT NULL, account_name TEXT NOT NULL, original_filename TEXT NOT NULL, extension TEXT NOT NULL, month TEXT, size_bytes INTEGER NOT NULL, allocated_bytes INTEGER NOT NULL, inode INTEGER NOT NULL, nlink INTEGER NOT NULL, mtime REAL NOT NULL, sha256 TEXT, status TEXT NOT NULL, duplicate_group_id TEXT, candidate_reason TEXT, relative_path TEXT NOT NULL, updated_at REAL NOT NULL); INSERT INTO files VALUES ('/legacy/one', 'ORDINARY_FILE', 'account', 'name', 'one.txt', 'txt', NULL, 1, 1, 1, 1, 1, NULL, 'HASHED', NULL, NULL, 'one', 1); INSERT INTO files VALUES ('/legacy/two', 'ORDINARY_FILE', 'account', 'name', 'two.txt', 'txt', NULL, 2, 2, 2, 1, 2, NULL, 'HASHED', NULL, NULL, 'two', 2); CREATE TABLE operations (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, detail TEXT, created_at REAL NOT NULL); INSERT INTO operations (event, detail, created_at) VALUES ('SCAN_FINISHED', 'legacy detail', 1); CREATE TABLE automation_task_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, event TEXT NOT NULL, detail TEXT, created_at REAL NOT NULL); INSERT INTO automation_task_logs (run_id, event, detail, created_at) VALUES (NULL, 'TASK_FINISHED', 'legacy detail', 1);", nil, nil, nil) == SQLITE_OK)

        let store = try ManifestStore(databaseURL: databaseURL)
        let operations = try store.recentOperations(limit: 10)
        #expect(operations.count == 1)
        #expect(operations[0].detail == "legacy detail")

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "SELECT typeof(id), typeof(id_token) FROM operations", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "integer")
        #expect(String(cString: sqlite3_column_text(statement, 1)) == "text")
    }

}
