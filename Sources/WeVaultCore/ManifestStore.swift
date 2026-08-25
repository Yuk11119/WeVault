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
        try execute("""
        CREATE TABLE IF NOT EXISTS cloud_objects (
            cloud_object_id TEXT PRIMARY KEY,
            sha256 TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            storage_provider TEXT NOT NULL,
            bucket_or_container TEXT NOT NULL,
            object_key TEXT NOT NULL,
            uploaded_at REAL NOT NULL,
            verified_at REAL,
            verify_status TEXT NOT NULL,
            ref_count INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(storage_provider, bucket_or_container, object_key)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS archive_bindings (
            binding_id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL,
            cloud_object_id TEXT NOT NULL,
            archive_state TEXT NOT NULL,
            local_state TEXT NOT NULL,
            restored_at REAL,
            last_restore_check_at REAL,
            updated_at REAL NOT NULL,
            UNIQUE(file_path, cloud_object_id),
            FOREIGN KEY(cloud_object_id) REFERENCES cloud_objects(cloud_object_id)
        )
        """)
        try addColumnIfNeeded(table: "archive_bindings", definition: "restored_at REAL")
        try addColumnIfNeeded(table: "archive_bindings", definition: "last_restore_check_at REAL")
        try execute("""
        CREATE TABLE IF NOT EXISTS archived_files (
            file_path TEXT PRIMARY KEY,
            object_type TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            account_hash TEXT NOT NULL,
            account_name TEXT NOT NULL,
            month TEXT,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            mtime REAL NOT NULL,
            family_id TEXT,
            display_or_playback_path TEXT,
            bubble_or_thumb_path TEXT,
            archived_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        try backfillArchivedFilesFromCurrentSnapshot()
    }

    private func clearCurrentSnapshot() throws {
        try execute("DELETE FROM files")
        try execute("DELETE FROM families")
        try execute("DELETE FROM duplicate_groups")
    }

    private func backfillArchivedFilesFromCurrentSnapshot() throws {
        try execute("""
        INSERT OR IGNORE INTO archived_files (
            file_path, object_type, original_filename, relative_path, account_hash, account_name,
            month, size_bytes, sha256, mtime, family_id, display_or_playback_path,
            bubble_or_thumb_path, archived_at, updated_at
        )
        SELECT f.path, f.object_type, f.original_filename, f.relative_path, f.account_hash, f.account_name,
               f.month, f.size_bytes, f.sha256, f.mtime, fam.id, fam.display_or_playback_path,
               fam.bubble_or_thumb_path, ab.updated_at, strftime('%s','now')
        FROM archive_bindings ab
        JOIN files f ON f.path = ab.file_path
        LEFT JOIN families fam ON fam.high_or_raw_path = f.path
        WHERE f.sha256 IS NOT NULL
        """)
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

    public func verifiedCloudObject(sha256: String, provider: String, bucket: String, objectKey: String) throws -> CloudObject? {
        let sql = """
        SELECT cloud_object_id, sha256, size_bytes, storage_provider, bucket_or_container, object_key,
               uploaded_at, verified_at, verify_status, ref_count
        FROM cloud_objects
        WHERE sha256 = ? AND storage_provider = ? AND bucket_or_container = ? AND object_key = ? AND verify_status = ?
        LIMIT 1
        """
        var result: CloudObject?
        try withStatement(sql) { stmt in
            bindText(stmt, 1, sha256)
            bindText(stmt, 2, provider)
            bindText(stmt, 3, bucket)
            bindText(stmt, 4, objectKey)
            bindText(stmt, 5, CloudVerifyStatus.verified.rawValue)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = readCloudObject(stmt)
            }
        }
        return result
    }

    public func cloudArchiveSnapshots() throws -> [String: CloudArchiveSnapshot] {
        let sql = """
        SELECT co.cloud_object_id, co.sha256, co.size_bytes, co.storage_provider, co.bucket_or_container, co.object_key,
               co.uploaded_at, co.verified_at, co.verify_status, co.ref_count,
               ab.binding_id, ab.file_path, ab.archive_state, ab.local_state, ab.restored_at, ab.last_restore_check_at
        FROM archive_bindings ab
        JOIN cloud_objects co ON co.cloud_object_id = ab.cloud_object_id
        """
        var snapshots: [String: CloudArchiveSnapshot] = [:]
        try withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let object = readCloudObject(stmt)
                let binding = ArchiveBinding(
                    bindingID: columnText(stmt, 10),
                    filePath: columnText(stmt, 11),
                    cloudObjectID: object.cloudObjectID,
                    archiveState: ArchiveBindingState(rawValue: columnText(stmt, 12)) ?? .uploaded,
                    localState: LocalArchiveState(rawValue: columnText(stmt, 13)) ?? .localPresent,
                    restoredAt: optionalDate(stmt, 14),
                    lastRestoreCheckAt: optionalDate(stmt, 15)
                )
                snapshots[binding.filePath] = CloudArchiveSnapshot(object: object, binding: binding)
            }
        }
        return snapshots
    }

    public func archivedFileSnapshots() throws -> [String: ArchivedFileSnapshot] {
        let sql = """
        SELECT af.file_path, af.object_type, af.original_filename, af.relative_path, af.account_hash, af.account_name,
               af.month, af.size_bytes, af.sha256, af.mtime, af.family_id, af.display_or_playback_path,
               af.bubble_or_thumb_path, af.archived_at, af.updated_at,
               ab.binding_id, ab.archive_state, ab.local_state, ab.restored_at, ab.last_restore_check_at,
               co.cloud_object_id, co.sha256, co.size_bytes, co.storage_provider, co.bucket_or_container, co.object_key,
               co.uploaded_at, co.verified_at, co.verify_status, co.ref_count
        FROM archived_files af
        JOIN archive_bindings ab ON ab.file_path = af.file_path
        JOIN cloud_objects co ON co.cloud_object_id = ab.cloud_object_id
        """
        var snapshots: [String: ArchivedFileSnapshot] = [:]
        try withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let archivedFile = readArchivedFile(stmt)
                let binding = ArchiveBinding(
                    bindingID: columnText(stmt, 15),
                    filePath: archivedFile.filePath,
                    cloudObjectID: columnText(stmt, 20),
                    archiveState: ArchiveBindingState(rawValue: columnText(stmt, 16)) ?? .uploaded,
                    localState: LocalArchiveState(rawValue: columnText(stmt, 17)) ?? .localPresent,
                    restoredAt: optionalDate(stmt, 18),
                    lastRestoreCheckAt: optionalDate(stmt, 19)
                )
                let object = readCloudObject(stmt, offset: 20)
                snapshots[archivedFile.filePath] = ArchivedFileSnapshot(archivedFile: archivedFile, binding: binding, object: object)
            }
        }
        return snapshots
    }

    public func updateRestoreState(bindingID: String, archiveState: ArchiveBindingState, localState: LocalArchiveState, restoredAt: Date?, lastRestoreCheckAt: Date?) throws {
        try withStatement("""
        UPDATE archive_bindings
        SET archive_state = ?, local_state = ?, restored_at = ?, last_restore_check_at = ?, updated_at = ?
        WHERE binding_id = ?
        """) { stmt in
            bindText(stmt, 1, archiveState.rawValue)
            bindText(stmt, 2, localState.rawValue)
            bindOptionalDate(stmt, 3, restoredAt)
            bindOptionalDate(stmt, 4, lastRestoreCheckAt)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            bindText(stmt, 6, bindingID)
            try stepDone(stmt)
        }
    }

    public func saveCloudObject(_ object: CloudObject, binding: ArchiveBinding, archivedFile: ArchivedFile) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try upsert(object)
            try upsert(binding)
            try upsert(archivedFile)
            try refreshRefCount(cloudObjectID: object.cloudObjectID)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func updateFileStatus(path: String, status: ArchiveStatus) throws {
        try withStatement("UPDATE files SET status = ?, updated_at = ? WHERE path = ?") { stmt in
            bindText(stmt, 1, status.rawValue)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, 3, path)
            try stepDone(stmt)
        }
    }

    public func logOperation(_ event: String, detail: String?) throws {
        try withStatement("INSERT INTO operations (event, detail, created_at) VALUES (?, ?, ?)") { stmt in
            bindText(stmt, 1, event)
            bindOptionalText(stmt, 2, detail)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func upsert(_ object: CloudObject) throws {
        let sql = """
        INSERT OR REPLACE INTO cloud_objects (
            cloud_object_id, sha256, size_bytes, storage_provider, bucket_or_container, object_key,
            uploaded_at, verified_at, verify_status, ref_count, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, object.cloudObjectID)
            bindText(stmt, 2, object.sha256)
            sqlite3_bind_int64(stmt, 3, object.sizeBytes)
            bindText(stmt, 4, object.storageProvider)
            bindText(stmt, 5, object.bucketOrContainer)
            bindText(stmt, 6, object.objectKey)
            sqlite3_bind_double(stmt, 7, object.uploadedAt.timeIntervalSince1970)
            bindOptionalDate(stmt, 8, object.verifiedAt)
            bindText(stmt, 9, object.verifyStatus.rawValue)
            sqlite3_bind_int(stmt, 10, Int32(object.refCount))
            sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func upsert(_ binding: ArchiveBinding) throws {
        let sql = """
        INSERT OR REPLACE INTO archive_bindings (
            binding_id, file_path, cloud_object_id, archive_state, local_state, restored_at, last_restore_check_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, binding.bindingID)
            bindText(stmt, 2, binding.filePath)
            bindText(stmt, 3, binding.cloudObjectID)
            bindText(stmt, 4, binding.archiveState.rawValue)
            bindText(stmt, 5, binding.localState.rawValue)
            bindOptionalDate(stmt, 6, binding.restoredAt)
            bindOptionalDate(stmt, 7, binding.lastRestoreCheckAt)
            sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func upsert(_ archivedFile: ArchivedFile) throws {
        let sql = """
        INSERT INTO archived_files (
            file_path, object_type, original_filename, relative_path, account_hash, account_name,
            month, size_bytes, sha256, mtime, family_id, display_or_playback_path,
            bubble_or_thumb_path, archived_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_path) DO UPDATE SET
            object_type = excluded.object_type,
            original_filename = excluded.original_filename,
            relative_path = excluded.relative_path,
            account_hash = excluded.account_hash,
            account_name = excluded.account_name,
            month = excluded.month,
            size_bytes = excluded.size_bytes,
            sha256 = excluded.sha256,
            mtime = excluded.mtime,
            family_id = excluded.family_id,
            display_or_playback_path = excluded.display_or_playback_path,
            bubble_or_thumb_path = excluded.bubble_or_thumb_path,
            updated_at = excluded.updated_at
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, archivedFile.filePath)
            bindText(stmt, 2, archivedFile.objectType.rawValue)
            bindText(stmt, 3, archivedFile.originalFilename)
            bindText(stmt, 4, archivedFile.relativePath)
            bindText(stmt, 5, archivedFile.accountHash)
            bindText(stmt, 6, archivedFile.accountName)
            bindOptionalText(stmt, 7, archivedFile.month)
            sqlite3_bind_int64(stmt, 8, archivedFile.sizeBytes)
            bindText(stmt, 9, archivedFile.sha256)
            sqlite3_bind_double(stmt, 10, archivedFile.mtime.timeIntervalSince1970)
            bindOptionalText(stmt, 11, archivedFile.familyID)
            bindOptionalText(stmt, 12, archivedFile.displayOrPlaybackPath)
            bindOptionalText(stmt, 13, archivedFile.bubbleOrThumbPath)
            sqlite3_bind_double(stmt, 14, archivedFile.archivedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 15, archivedFile.updatedAt.timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    private func refreshRefCount(cloudObjectID: String) throws {
        let sql = """
        UPDATE cloud_objects
        SET ref_count = (SELECT COUNT(*) FROM archive_bindings WHERE cloud_object_id = ?), updated_at = ?
        WHERE cloud_object_id = ?
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, cloudObjectID)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, 3, cloudObjectID)
            try stepDone(stmt)
        }
    }

    private func readArchivedFile(_ stmt: OpaquePointer?) -> ArchivedFile {
        ArchivedFile(
            filePath: columnText(stmt, 0),
            objectType: ArchiveObjectType(rawValue: columnText(stmt, 1)) ?? .ordinaryFile,
            originalFilename: columnText(stmt, 2),
            relativePath: columnText(stmt, 3),
            accountHash: columnText(stmt, 4),
            accountName: columnText(stmt, 5),
            month: optionalText(stmt, 6),
            sizeBytes: sqlite3_column_int64(stmt, 7),
            sha256: columnText(stmt, 8),
            mtime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
            familyID: optionalText(stmt, 10),
            displayOrPlaybackPath: optionalText(stmt, 11),
            bubbleOrThumbPath: optionalText(stmt, 12),
            archivedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
        )
    }

    private func readCloudObject(_ stmt: OpaquePointer?, offset: Int32 = 0) -> CloudObject {
        CloudObject(
            cloudObjectID: columnText(stmt, offset),
            sha256: columnText(stmt, offset + 1),
            sizeBytes: sqlite3_column_int64(stmt, offset + 2),
            storageProvider: columnText(stmt, offset + 3),
            bucketOrContainer: columnText(stmt, offset + 4),
            objectKey: columnText(stmt, offset + 5),
            uploadedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, offset + 6)),
            verifiedAt: optionalDate(stmt, offset + 7),
            verifyStatus: CloudVerifyStatus(rawValue: columnText(stmt, offset + 8)) ?? .uploaded,
            refCount: Int(sqlite3_column_int(stmt, offset + 9))
        )
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

private func bindOptionalDate(_ stmt: OpaquePointer?, _ index: Int32, _ value: Date?) {
    if let value {
        sqlite3_bind_double(stmt, index, value.timeIntervalSince1970)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

private func optionalDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
    if sqlite3_column_type(stmt, index) == SQLITE_NULL {
        return nil
    }
    return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
}

private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(stmt, index) else { return "" }
    return String(cString: value)
}

private func optionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    if sqlite3_column_type(stmt, index) == SQLITE_NULL {
        return nil
    }
    return columnText(stmt, index)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
