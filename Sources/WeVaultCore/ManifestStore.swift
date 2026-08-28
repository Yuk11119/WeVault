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
            try backfillArchivedFilesFromCurrentSnapshot()
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
            released_at REAL,
            quarantined_at REAL,
            quarantine_path TEXT,
            placeholder_path TEXT,
            placeholder_created_at REAL,
            placeholder_format TEXT,
            placeholder_sha256 TEXT,
            placeholder_size INTEGER,
            updated_at REAL NOT NULL,
            UNIQUE(file_path, cloud_object_id),
            FOREIGN KEY(cloud_object_id) REFERENCES cloud_objects(cloud_object_id)
        )
        """)
        try addColumnIfNeeded(table: "archive_bindings", definition: "restored_at REAL")
        try addColumnIfNeeded(table: "archive_bindings", definition: "last_restore_check_at REAL")
        try addColumnIfNeeded(table: "archive_bindings", definition: "released_at REAL")
        try addColumnIfNeeded(table: "archive_bindings", definition: "quarantined_at REAL")
        try addColumnIfNeeded(table: "archive_bindings", definition: "quarantine_path TEXT")
        try addColumnIfNeeded(table: "archive_bindings", definition: "placeholder_path TEXT")
        try addColumnIfNeeded(table: "archive_bindings", definition: "placeholder_created_at REAL")
        try addColumnIfNeeded(table: "archive_bindings", definition: "placeholder_format TEXT")
        try addColumnIfNeeded(table: "archive_bindings", definition: "placeholder_sha256 TEXT")
        try addColumnIfNeeded(table: "archive_bindings", definition: "placeholder_size INTEGER")
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
        try execute("""
        CREATE TABLE IF NOT EXISTS automation_tasks (
            id TEXT PRIMARY KEY,
            is_paused INTEGER NOT NULL,
            interval_hours INTEGER NOT NULL,
            next_run_at REAL NOT NULL,
            last_run_at REAL,
            updated_at REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS automation_task_runs (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            status TEXT NOT NULL,
            stage TEXT NOT NULL,
            completed_units INTEGER NOT NULL,
            total_units INTEGER NOT NULL,
            failure_reason TEXT,
            retry_of_run_id TEXT,
            started_at REAL,
            finished_at REAL,
            created_at REAL NOT NULL,
            FOREIGN KEY(task_id) REFERENCES automation_tasks(id)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS automation_task_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT,
            event TEXT NOT NULL,
            detail TEXT,
            created_at REAL NOT NULL,
            FOREIGN KEY(run_id) REFERENCES automation_task_runs(id)
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
        INSERT INTO archived_files (
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
            family_id = COALESCE(excluded.family_id, archived_files.family_id),
            display_or_playback_path = COALESCE(excluded.display_or_playback_path, archived_files.display_or_playback_path),
            bubble_or_thumb_path = COALESCE(excluded.bubble_or_thumb_path, archived_files.bubble_or_thumb_path),
            updated_at = excluded.updated_at
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
               ab.binding_id, ab.file_path, ab.archive_state, ab.local_state, ab.restored_at, ab.last_restore_check_at,
               ab.released_at, ab.quarantined_at, ab.quarantine_path, ab.placeholder_path, ab.placeholder_created_at,
               ab.placeholder_format, ab.placeholder_sha256, ab.placeholder_size
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
                    lastRestoreCheckAt: optionalDate(stmt, 15),
                    releasedAt: optionalDate(stmt, 16),
                    quarantinedAt: optionalDate(stmt, 17),
                    quarantinePath: optionalText(stmt, 18),
                    placeholderPath: optionalText(stmt, 19),
                    placeholderCreatedAt: optionalDate(stmt, 20),
                    placeholderFormat: optionalText(stmt, 21),
                    placeholderSHA256: optionalText(stmt, 22),
                    placeholderSize: optionalInt64(stmt, 23)
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
               ab.released_at, ab.quarantined_at, ab.quarantine_path, ab.placeholder_path, ab.placeholder_created_at,
               ab.placeholder_format, ab.placeholder_sha256, ab.placeholder_size,
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
                    cloudObjectID: columnText(stmt, 28),
                    archiveState: ArchiveBindingState(rawValue: columnText(stmt, 16)) ?? .uploaded,
                    localState: LocalArchiveState(rawValue: columnText(stmt, 17)) ?? .localPresent,
                    restoredAt: optionalDate(stmt, 18),
                    lastRestoreCheckAt: optionalDate(stmt, 19),
                    releasedAt: optionalDate(stmt, 20),
                    quarantinedAt: optionalDate(stmt, 21),
                    quarantinePath: optionalText(stmt, 22),
                    placeholderPath: optionalText(stmt, 23),
                    placeholderCreatedAt: optionalDate(stmt, 24),
                    placeholderFormat: optionalText(stmt, 25),
                    placeholderSHA256: optionalText(stmt, 26),
                    placeholderSize: optionalInt64(stmt, 27)
                )
                let object = readCloudObject(stmt, offset: 28)
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

    public func updateLocalReleaseState(
        bindingID: String,
        archiveState: ArchiveBindingState,
        localState: LocalArchiveState,
        releasedAt: Date?,
        quarantinedAt: Date? = nil,
        quarantinePath: String?,
        placeholderPath: String? = nil,
        placeholderCreatedAt: Date? = nil,
        placeholderFormat: String? = nil,
        placeholderSHA256: String? = nil,
        placeholderSize: Int64? = nil
    ) throws {
        try withStatement("""
        UPDATE archive_bindings
        SET archive_state = ?, local_state = ?, released_at = ?, quarantined_at = ?, quarantine_path = ?,
            placeholder_path = ?, placeholder_created_at = ?, placeholder_format = ?,
            placeholder_sha256 = ?, placeholder_size = ?, updated_at = ?
        WHERE binding_id = ?
        """) { stmt in
            bindText(stmt, 1, archiveState.rawValue)
            bindText(stmt, 2, localState.rawValue)
            bindOptionalDate(stmt, 3, releasedAt)
            bindOptionalDate(stmt, 4, quarantinedAt)
            bindOptionalText(stmt, 5, quarantinePath)
            bindOptionalText(stmt, 6, placeholderPath)
            bindOptionalDate(stmt, 7, placeholderCreatedAt)
            bindOptionalText(stmt, 8, placeholderFormat)
            bindOptionalText(stmt, 9, placeholderSHA256)
            bindOptionalInt64(stmt, 10, placeholderSize)
            sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970)
            bindText(stmt, 12, bindingID)
            try stepDone(stmt)
        }
    }

    public func clearPlaceholderState(bindingID: String) throws {
        try withStatement("""
        UPDATE archive_bindings
        SET placeholder_path = NULL, placeholder_created_at = NULL, placeholder_format = NULL,
            placeholder_sha256 = NULL, placeholder_size = NULL, quarantine_path = NULL,
            updated_at = ?
        WHERE binding_id = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            bindText(stmt, 2, bindingID)
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

    public func recentOperations(limit: Int = 20) throws -> [OperationRecord] {
        let safeLimit = min(max(limit, 1), 200)
        var records: [OperationRecord] = []
        try withStatement("SELECT id, event, detail, created_at FROM operations ORDER BY id DESC LIMIT ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(safeLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(OperationRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    event: columnText(stmt, 1),
                    detail: optionalText(stmt, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                ))
            }
        }
        return records
    }

    public func saveAutomationTask(_ task: AutomationTask) throws {
        try withStatement("""
        INSERT INTO automation_tasks (id, is_paused, interval_hours, next_run_at, last_run_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET is_paused = excluded.is_paused, interval_hours = excluded.interval_hours,
            next_run_at = excluded.next_run_at, last_run_at = excluded.last_run_at, updated_at = excluded.updated_at
        """) { stmt in
            bindText(stmt, 1, task.id); sqlite3_bind_int(stmt, 2, task.isPaused ? 1 : 0); sqlite3_bind_int(stmt, 3, Int32(task.intervalHours))
            sqlite3_bind_double(stmt, 4, task.nextRunAt.timeIntervalSince1970); bindOptionalDate(stmt, 5, task.lastRunAt); sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970); try stepDone(stmt)
        }
    }

    public func automationTask(id: String) throws -> AutomationTask? {
        var task: AutomationTask?
        try withStatement("SELECT id, is_paused, interval_hours, next_run_at, last_run_at FROM automation_tasks WHERE id = ?") { stmt in
            bindText(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW { task = AutomationTask(id: columnText(stmt, 0), isPaused: sqlite3_column_int(stmt, 1) != 0, intervalHours: Int(sqlite3_column_int(stmt, 2)), nextRunAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), lastRunAt: optionalDate(stmt, 4)) }
        }
        return task
    }

    public func dueAutomationTasks(at date: Date) throws -> [AutomationTask] {
        var tasks: [AutomationTask] = []
        try withStatement("SELECT id, is_paused, interval_hours, next_run_at, last_run_at FROM automation_tasks WHERE is_paused = 0 AND next_run_at <= ?") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW { tasks.append(AutomationTask(id: columnText(stmt, 0), isPaused: false, intervalHours: Int(sqlite3_column_int(stmt, 2)), nextRunAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), lastRunAt: optionalDate(stmt, 4))) }
        }
        return tasks
    }

    public func saveAutomationRun(_ run: AutomationTaskRun) throws {
        try withStatement("INSERT OR REPLACE INTO automation_task_runs (id, task_id, status, stage, completed_units, total_units, failure_reason, retry_of_run_id, started_at, finished_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { stmt in
            bindText(stmt, 1, run.id); bindText(stmt, 2, run.taskID); bindText(stmt, 3, run.status.rawValue); bindText(stmt, 4, run.stage.rawValue); sqlite3_bind_int(stmt, 5, Int32(run.completedUnits)); sqlite3_bind_int(stmt, 6, Int32(run.totalUnits)); bindOptionalText(stmt, 7, run.failureReason); bindOptionalText(stmt, 8, run.retryOfRunID); bindOptionalDate(stmt, 9, run.startedAt); bindOptionalDate(stmt, 10, run.finishedAt); sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970); try stepDone(stmt)
        }
    }

    public func latestAutomationRun(taskID: String) throws -> AutomationTaskRun? {
        var run: AutomationTaskRun?
        try withStatement("SELECT id, task_id, status, stage, completed_units, total_units, failure_reason, retry_of_run_id, started_at, finished_at FROM automation_task_runs WHERE task_id = ? ORDER BY rowid DESC LIMIT 1") { stmt in
            bindText(stmt, 1, taskID)
            if sqlite3_step(stmt) == SQLITE_ROW { run = AutomationTaskRun(id: columnText(stmt, 0), taskID: columnText(stmt, 1), status: AutomationRunStatus(rawValue: columnText(stmt, 2)) ?? .failed, stage: AutomationStage(rawValue: columnText(stmt, 3)) ?? .finished, completedUnits: Int(sqlite3_column_int(stmt, 4)), totalUnits: Int(sqlite3_column_int(stmt, 5)), failureReason: optionalText(stmt, 6), retryOfRunID: optionalText(stmt, 7), startedAt: optionalDate(stmt, 8), finishedAt: optionalDate(stmt, 9)) }
        }
        return run
    }

    public func logAutomation(runID: String?, event: String, detail: String?) throws {
        try withStatement("INSERT INTO automation_task_logs (run_id, event, detail, created_at) VALUES (?, ?, ?, ?)") { stmt in bindOptionalText(stmt, 1, runID); bindText(stmt, 2, event); bindOptionalText(stmt, 3, detail); sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970); try stepDone(stmt) }
    }

    public func recentAutomationLogs(taskID: String, limit: Int = 20) throws -> [AutomationTaskLog] {
        var logs: [AutomationTaskLog] = []; let safeLimit = min(max(limit, 1), 200)
        try withStatement("SELECT l.id, l.run_id, l.event, l.detail, l.created_at FROM automation_task_logs l JOIN automation_task_runs r ON r.id = l.run_id WHERE r.task_id = ? ORDER BY l.id DESC LIMIT ?") { stmt in
            bindText(stmt, 1, taskID); sqlite3_bind_int(stmt, 2, Int32(safeLimit))
            while sqlite3_step(stmt) == SQLITE_ROW { logs.append(AutomationTaskLog(id: sqlite3_column_int64(stmt, 0), runID: optionalText(stmt, 1), event: columnText(stmt, 2), detail: optionalText(stmt, 3), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))) }
        }
        return logs
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
        INSERT INTO archive_bindings (
            binding_id, file_path, cloud_object_id, archive_state, local_state,
            restored_at, last_restore_check_at, released_at, quarantined_at, quarantine_path,
            placeholder_path, placeholder_created_at, placeholder_format, placeholder_sha256,
            placeholder_size, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(binding_id) DO UPDATE SET
            file_path = excluded.file_path,
            cloud_object_id = excluded.cloud_object_id,
            archive_state = CASE
                WHEN excluded.archive_state = 'VERIFIED' AND archive_bindings.archive_state = 'LOCAL_RELEASED'
                    THEN archive_bindings.archive_state
                ELSE excluded.archive_state
            END,
            local_state = CASE
                WHEN excluded.local_state = 'LOCAL_PRESENT'
                     AND archive_bindings.local_state IN ('QUARANTINED', 'TOMBSTONED', 'LOCAL_RELEASED')
                    THEN archive_bindings.local_state
                ELSE excluded.local_state
            END,
            restored_at = COALESCE(archive_bindings.restored_at, excluded.restored_at),
            last_restore_check_at = COALESCE(archive_bindings.last_restore_check_at, excluded.last_restore_check_at),
            released_at = COALESCE(archive_bindings.released_at, excluded.released_at),
            quarantined_at = COALESCE(archive_bindings.quarantined_at, excluded.quarantined_at),
            quarantine_path = COALESCE(archive_bindings.quarantine_path, excluded.quarantine_path),
            placeholder_path = COALESCE(archive_bindings.placeholder_path, excluded.placeholder_path),
            placeholder_created_at = COALESCE(archive_bindings.placeholder_created_at, excluded.placeholder_created_at),
            placeholder_format = COALESCE(archive_bindings.placeholder_format, excluded.placeholder_format),
            placeholder_sha256 = COALESCE(archive_bindings.placeholder_sha256, excluded.placeholder_sha256),
            placeholder_size = COALESCE(archive_bindings.placeholder_size, excluded.placeholder_size),
            updated_at = excluded.updated_at
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, binding.bindingID)
            bindText(stmt, 2, binding.filePath)
            bindText(stmt, 3, binding.cloudObjectID)
            bindText(stmt, 4, binding.archiveState.rawValue)
            bindText(stmt, 5, binding.localState.rawValue)
            bindOptionalDate(stmt, 6, binding.restoredAt)
            bindOptionalDate(stmt, 7, binding.lastRestoreCheckAt)
            bindOptionalDate(stmt, 8, binding.releasedAt)
            bindOptionalDate(stmt, 9, binding.quarantinedAt)
            bindOptionalText(stmt, 10, binding.quarantinePath)
            bindOptionalText(stmt, 11, binding.placeholderPath)
            bindOptionalDate(stmt, 12, binding.placeholderCreatedAt)
            bindOptionalText(stmt, 13, binding.placeholderFormat)
            bindOptionalText(stmt, 14, binding.placeholderSHA256)
            bindOptionalInt64(stmt, 15, binding.placeholderSize)
            sqlite3_bind_double(stmt, 16, Date().timeIntervalSince1970)
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

private func bindOptionalInt64(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64?) {
    if let value {
        sqlite3_bind_int64(stmt, index, value)
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

private func optionalInt64(_ stmt: OpaquePointer?, _ index: Int32) -> Int64? {
    if sqlite3_column_type(stmt, index) == SQLITE_NULL {
        return nil
    }
    return sqlite3_column_int64(stmt, index)
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
