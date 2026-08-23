import Foundation
import SQLite3

public final class ManifestStore: @unchecked Sendable {
    public let databaseURL: URL
    private var db: OpaquePointer?

    public init(databaseURL: URL = ManifestStore.defaultDatabaseURL()) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw WeVaultError.sqlite(lastError)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WeVault", isDirectory: true).appendingPathComponent("archive.sqlite")
    }

    public func save(scanResult: ScanResult) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try logOperation("SCAN_STARTED", detail: scanResult.rootPath)
            try clearCurrentSnapshot()
            for file in scanResult.files {
                try insert(file)
            }
            for family in scanResult.families {
                try insert(family)
            }
            for group in scanResult.duplicateGroups {
                try insert(group)
            }
            try logOperation("SCAN_FINISHED", detail: "files=\(scanResult.files.count), families=\(scanResult.families.count), duplicates=\(scanResult.duplicateGroups.count)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY,
            object_type TEXT NOT NULL,
            account_hash TEXT NOT NULL,
            account_name TEXT NOT NULL,
            conversation_name TEXT,
            conversation_resolution TEXT NOT NULL DEFAULT '',
            original_filename TEXT NOT NULL,
            extension TEXT NOT NULL,
            month TEXT,
            size_bytes INTEGER NOT NULL,
            allocated_bytes INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            nlink INTEGER NOT NULL,
            mtime REAL NOT NULL,
            sha256 TEXT,
            status TEXT NOT NULL,
            duplicate_group_id TEXT,
            candidate_reason TEXT,
            relative_path TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        try addColumnIfNeeded(table: "files", definition: "conversation_name TEXT")
        try addColumnIfNeeded(table: "files", definition: "conversation_resolution TEXT NOT NULL DEFAULT ''")
        try execute("""
        CREATE TABLE IF NOT EXISTS families (
            id TEXT PRIMARY KEY,
            family_type TEXT NOT NULL,
            account_hash TEXT NOT NULL,
            account_name TEXT NOT NULL,
            month TEXT,
            prefix TEXT NOT NULL,
            high_or_raw_path TEXT NOT NULL,
            display_or_playback_path TEXT,
            bubble_or_thumb_path TEXT,
            is_candidate INTEGER NOT NULL,
            reason TEXT NOT NULL,
            member_paths_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS duplicate_groups (
            id TEXT PRIMARY KEY,
            sha256 TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            duplicate_count INTEGER NOT NULL,
            reclaimable_bytes INTEGER NOT NULL,
            paths_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS operations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event TEXT NOT NULL,
            detail TEXT,
            created_at REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS storage_configs (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            endpoint TEXT NOT NULL,
            bucket TEXT NOT NULL,
            region TEXT NOT NULL,
            access_key_reference TEXT NOT NULL,
            secret_key_reference TEXT NOT NULL,
            path_style INTEGER NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
    }

    private func clearCurrentSnapshot() throws {
        try execute("DELETE FROM files")
        try execute("DELETE FROM families")
        try execute("DELETE FROM duplicate_groups")
    }

    private func insert(_ file: FileRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO files (
            path, object_type, account_hash, account_name, conversation_name, conversation_resolution, original_filename, extension, month,
            size_bytes, allocated_bytes, inode, nlink, mtime, sha256, status, duplicate_group_id,
            candidate_reason, relative_path, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, file.path)
            bindText(stmt, 2, file.objectType.rawValue)
            bindText(stmt, 3, file.accountHash)
            bindText(stmt, 4, file.accountName)
            bindOptionalText(stmt, 5, file.conversationName)
            bindText(stmt, 6, file.conversationResolution)
            bindText(stmt, 7, file.filename)
            bindText(stmt, 8, file.fileExtension)
            bindOptionalText(stmt, 9, file.month)
            sqlite3_bind_int64(stmt, 10, file.sizeBytes)
            sqlite3_bind_int64(stmt, 11, file.allocatedBytes)
            sqlite3_bind_int64(stmt, 12, Int64(bitPattern: file.inode))
            sqlite3_bind_int64(stmt, 13, Int64(bitPattern: file.nlink))
            sqlite3_bind_double(stmt, 14, file.mtime.timeIntervalSince1970)
            bindOptionalText(stmt, 15, file.sha256)
            bindText(stmt, 16, file.status.rawValue)
            bindOptionalText(stmt, 17, file.duplicateGroupID)
            bindOptionalText(stmt, 18, file.candidateReason)
            bindText(stmt, 19, file.relativePath)
            sqlite3_bind_double(stmt, 20, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func insert(_ family: FamilyRecord) throws {
        let pathsJSON = try String(data: JSONEncoder().encode(family.memberPaths), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT OR REPLACE INTO families (
            id, family_type, account_hash, account_name, month, prefix, high_or_raw_path,
            display_or_playback_path, bubble_or_thumb_path, is_candidate, reason, member_paths_json, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, family.id)
            bindText(stmt, 2, family.familyType.rawValue)
            bindText(stmt, 3, family.accountHash)
            bindText(stmt, 4, family.accountName)
            bindOptionalText(stmt, 5, family.month)
            bindText(stmt, 6, family.prefix)
            bindText(stmt, 7, family.highOrRawPath)
            bindOptionalText(stmt, 8, family.displayOrPlaybackPath)
            bindOptionalText(stmt, 9, family.bubbleOrThumbPath)
            sqlite3_bind_int(stmt, 10, family.isCandidate ? 1 : 0)
            bindText(stmt, 11, family.reason)
            bindText(stmt, 12, pathsJSON)
            sqlite3_bind_double(stmt, 13, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func insert(_ group: DuplicateGroup) throws {
        let pathsJSON = try String(data: JSONEncoder().encode(group.paths), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT OR REPLACE INTO duplicate_groups (
            id, sha256, size_bytes, duplicate_count, reclaimable_bytes, paths_json, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, group.id)
            bindText(stmt, 2, group.sha256)
            sqlite3_bind_int64(stmt, 3, group.sizeBytes)
            sqlite3_bind_int(stmt, 4, Int32(group.duplicateCount))
            sqlite3_bind_int64(stmt, 5, group.reclaimableBytes)
            bindText(stmt, 6, pathsJSON)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func logOperation(_ event: String, detail: String?) throws {
        try withStatement("INSERT INTO operations (event, detail, created_at) VALUES (?, ?, ?)") { stmt in
            bindText(stmt, 1, event)
            bindOptionalText(stmt, 2, detail)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func execute(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw WeVaultError.sqlite(lastError)
        }
    }

    private func addColumnIfNeeded(table: String, definition: String) throws {
        do {
            try execute("ALTER TABLE \(table) ADD COLUMN \(definition)")
        } catch {
            if lastError.lowercased().contains("duplicate column name") {
                return
            }
            throw error
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WeVaultError.sqlite(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw WeVaultError.sqlite(lastError)
        }
    }

    private var lastError: String {
        if let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "unknown"
    }
}

private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
}

private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    if let value {
        bindText(stmt, index, value)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
