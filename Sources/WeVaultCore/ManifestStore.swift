import Foundation
import SQLite3

public final class ManifestStore: @unchecked Sendable {
    public let databaseURL: URL
    private var db: OpaquePointer?
    private let keyProvider: any ManifestKeyProvider
    private var cipher: ManifestCipher!
    public private(set) var recoveryState: ManifestRecoveryState = .ready

    public init(databaseURL: URL = ManifestStore.defaultDatabaseURL(), keyProvider: (any ManifestKeyProvider)? = nil) throws {
        let keyProvider = keyProvider ?? DevelopmentIsolation.keyProvider
        self.databaseURL = databaseURL
        self.keyProvider = keyProvider
        let existed = FileManager.default.fileExists(atPath: databaseURL.path)
        // A missing production manifest after a key was provisioned is not a first launch.
        if !existed, databaseURL == Self.defaultDatabaseURL(), DevelopmentIsolation.root == nil, try keyProvider.existingKey() != nil {
            recoveryState = .needsCloudIndexFallback
            throw WeVaultError.manifest(.missingNeedsCloudIndexFallback)
        }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw WeVaultError.manifest(.sqliteCorrupt)
        }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        // Encrypted identifiers use authenticated ciphertext with independent nonces; SQLite's
        // plaintext foreign-key comparison is therefore replaced by keyed token joins.
        try execute("PRAGMA foreign_keys=OFF")
        try prepareSecurity()
        try migrate()
        try encryptLegacyManifestIfNeeded()
        try verifyIntegrity()
    }

    private func prepareSecurity() throws {
        try execute("CREATE TABLE IF NOT EXISTS manifest_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let state = try metadata("encryption_state")
        let databaseID: String
        if let existing = try metadata("database_id") { databaseID = existing }
        else { databaseID = UUID().uuidString; try setMetadata("database_id", databaseID) }
        let master: Data
        if state == "encrypted" {
            guard let key = try keyProvider.existingKey() else { throw WeVaultError.manifest(.keyMissing) }
            master = key
        } else {
            master = try keyProvider.existingKey() ?? keyProvider.createKey()
        }
        do { cipher = try ManifestCipher(masterKey: master, databaseID: databaseID) }
        catch let failure as ManifestFailure { throw WeVaultError.manifest(failure) }
        if state == "encrypted", try metadata("key_verifier") != cipher.verifier(databaseID: databaseID) {
            throw WeVaultError.manifest(.keyMismatch)
        }
        if state == nil {
            try setMetadata("key_verifier", cipher.verifier(databaseID: databaseID))
        }
    }

    private func metadata(_ key: String) throws -> String? {
        var value: String?
        try withStatement("SELECT value FROM manifest_metadata WHERE key = ?") { stmt in
            bindText(stmt, 1, key); if sqlite3_step(stmt) == SQLITE_ROW { value = columnText(stmt, 0) }
        }
        return value
    }

    private func setMetadata(_ key: String, _ value: String) throws {
        try withStatement("INSERT OR REPLACE INTO manifest_metadata (key, value) VALUES (?, ?)") { stmt in
            bindText(stmt, 1, key); bindText(stmt, 2, value); try stepDone(stmt)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    public static func defaultDatabaseURL() -> URL {
        if let root = DevelopmentIsolation.root { return root.appendingPathComponent("archive.sqlite") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WeVault", isDirectory: true).appendingPathComponent("archive.sqlite")
    }

    public func hasPendingRelease(bindingID: String) throws -> Bool {
        try workGet(ReleaseJournal.self, scope: "release-journal", key: bindingID) != nil
    }

    public func reopen() throws -> ManifestStore {
        try ManifestStore(databaseURL: databaseURL, keyProvider: keyProvider)
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
        try execute("CREATE TABLE IF NOT EXISTS pipeline_records (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, token TEXT NOT NULL, grouping TEXT, payload BLOB NOT NULL, UNIQUE(scope, token))")
        try execute("CREATE INDEX IF NOT EXISTS pipeline_group ON pipeline_records(scope, grouping)")
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
        try addColumnIfNeeded(table: "files", definition: "path_token TEXT")
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
        try addColumnIfNeeded(table: "families", definition: "id_token TEXT")
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
        try addColumnIfNeeded(table: "duplicate_groups", definition: "id_token TEXT")
        try execute("""
        CREATE TABLE IF NOT EXISTS operations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event TEXT NOT NULL,
            detail TEXT,
            created_at REAL NOT NULL,
            id_token TEXT
        )
        """)
        try addColumnIfNeeded(table: "operations", definition: "id_token TEXT")
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
        try addColumnIfNeeded(table: "cloud_objects", definition: "cloud_object_token TEXT")
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
        try addColumnIfNeeded(table: "archive_bindings", definition: "binding_token TEXT")
        try addColumnIfNeeded(table: "archive_bindings", definition: "file_path_token TEXT")
        try addColumnIfNeeded(table: "archive_bindings", definition: "cloud_object_token TEXT")
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
        try addColumnIfNeeded(table: "archived_files", definition: "file_path_token TEXT")
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
            id_token TEXT,
            FOREIGN KEY(run_id) REFERENCES automation_task_runs(id)
        )
        """)
        try addColumnIfNeeded(table: "automation_task_logs", definition: "id_token TEXT")
        try backfillArchivedFilesFromCurrentSnapshot()
    }

    // SQLite has no field encryption primitive. P3 stores ciphertext in the original text
    // columns and uses keyed tokens only for equality joins/indexes. This method is deliberately
    // transactional so an interrupted legacy upgrade leaves the plaintext database untouched.
    private func encryptLegacyManifestIfNeeded() throws {
        guard try metadata("encryption_state") != "encrypted" else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try migrateTable("files", tokenColumn: "path_token", sourceColumn: "path", columns: ["path", "account_hash", "account_name", "conversation_name", "conversation_resolution", "original_filename", "relative_path", "duplicate_group_id", "candidate_reason"])
            try migrateTable("families", tokenColumn: "id_token", sourceColumn: "id", columns: ["id", "account_hash", "account_name", "prefix", "high_or_raw_path", "display_or_playback_path", "bubble_or_thumb_path", "reason", "member_paths_json"])
            try migrateTable("duplicate_groups", tokenColumn: "id_token", sourceColumn: "id", columns: ["id", "paths_json"])
            try migrateTable("cloud_objects", tokenColumn: "cloud_object_token", sourceColumn: "cloud_object_id", columns: ["cloud_object_id", "storage_provider", "bucket_or_container", "object_key"])
            try migrateTable("archive_bindings", tokenColumn: "binding_token", sourceColumn: "binding_id", columns: ["binding_id", "file_path", "cloud_object_id", "quarantine_path", "placeholder_path", "placeholder_format", "placeholder_sha256"])
            try migrateTable("archived_files", tokenColumn: "file_path_token", sourceColumn: "file_path", columns: ["file_path", "original_filename", "relative_path", "account_hash", "account_name", "sha256", "family_id", "display_or_playback_path", "bubble_or_thumb_path"])
            try migrateTable("storage_configs", tokenColumn: "id", sourceColumn: "id", columns: ["endpoint", "bucket", "region", "access_key_reference", "secret_key_reference"])
            // `id` is an INTEGER PRIMARY KEY. Keep it numeric and store the encryption token
            // separately; replacing it with a text token makes SQLite reject the migration.
            try migrateTable("operations", tokenColumn: "id_token", sourceColumn: "id", columns: ["detail"])
            try migrateTable("automation_task_runs", tokenColumn: "id", sourceColumn: "id", columns: ["failure_reason", "retry_of_run_id"])
            try migrateTable("automation_task_logs", tokenColumn: "id_token", sourceColumn: "id", columns: ["detail"])
            try execute("UPDATE archive_bindings SET file_path_token = NULL, cloud_object_token = NULL")
            try fillBindingTokens()
            try execute("CREATE UNIQUE INDEX IF NOT EXISTS files_path_token_idx ON files(path_token)")
            try execute("CREATE UNIQUE INDEX IF NOT EXISTS cloud_objects_token_idx ON cloud_objects(cloud_object_token)")
            try execute("CREATE UNIQUE INDEX IF NOT EXISTS bindings_binding_token_idx ON archive_bindings(binding_token)")
            try execute("CREATE UNIQUE INDEX IF NOT EXISTS archived_files_path_token_idx ON archived_files(file_path_token)")
            try setMetadata("encryption_state", "encrypted")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrateTable(_ table: String, tokenColumn: String, sourceColumn: String, columns: [String]) throws {
        // Do not mutate a table while walking a cursor over it. SQLite can then revisit rows
        // whose payload changed, which produces duplicate keyed tokens during legacy upgrades.
        var rows: [(rowID: Int64, source: String)] = []
        try withStatement("SELECT rowid, \(sourceColumn) FROM \(table)") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(stmt, 0), columnText(stmt, 1)))
            }
        }
        for row in rows {
            let token = cipher.token(row.source, domain: "\(table).\(sourceColumn)")
            try withStatement("UPDATE \(table) SET \(tokenColumn) = ? WHERE rowid = ?") { update in bindText(update, 1, token); sqlite3_bind_int64(update, 2, row.rowID); try stepDone(update) }
            for column in columns {
                try withStatement("SELECT \(column) FROM \(table) WHERE rowid = ?") { read in
                    sqlite3_bind_int64(read, 1, row.rowID)
                    guard sqlite3_step(read) == SQLITE_ROW, sqlite3_column_type(read, 0) != SQLITE_NULL else { return }
                    let sealed = try cipher.seal(columnText(read, 0), context: "\(table).\(column).\(token)")
                    try withStatement("UPDATE \(table) SET \(column) = ? WHERE rowid = ?") { update in bindData(update, 1, sealed); sqlite3_bind_int64(update, 2, row.rowID); try stepDone(update) }
                }
            }
        }
    }

    private func fillBindingTokens() throws {
        try withStatement("SELECT rowid, binding_id, file_path, cloud_object_id, binding_token FROM archive_bindings") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(stmt, 0)
                let binding = try decryptColumn(stmt, 1, table: "archive_bindings", column: "binding_id", token: columnText(stmt, 4))
                let file = try decryptColumn(stmt, 2, table: "archive_bindings", column: "file_path", token: columnText(stmt, 4))
                let object = try decryptColumn(stmt, 3, table: "archive_bindings", column: "cloud_object_id", token: columnText(stmt, 4))
                try withStatement("UPDATE archive_bindings SET file_path_token = ?, cloud_object_token = ? WHERE rowid = ?") { update in
                    bindText(update, 1, cipher.token(file, domain: "files.path")); bindText(update, 2, cipher.token(object, domain: "cloud_objects.cloud_object_id")); sqlite3_bind_int64(update, 3, rowID); try stepDone(update)
                }
                _ = binding
            }
        }
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
            let token = cipher.token(file.path, domain: "files.path")
            bindData(stmt, 1, try encrypted(file.path, table: "files", column: "path", token: token))
            bindText(stmt, 2, file.objectType.rawValue)
            bindData(stmt, 3, try encrypted(file.accountHash, table: "files", column: "account_hash", token: token))
            bindData(stmt, 4, try encrypted(file.accountName, table: "files", column: "account_name", token: token))
            try bindOptionalEncrypted(stmt, 5, file.conversationName, table: "files", column: "conversation_name", token: token)
            bindData(stmt, 6, try encrypted(file.conversationResolution, table: "files", column: "conversation_resolution", token: token))
            bindData(stmt, 7, try encrypted(file.filename, table: "files", column: "original_filename", token: token))
            bindText(stmt, 8, file.fileExtension)
            bindOptionalText(stmt, 9, file.month)
            sqlite3_bind_int64(stmt, 10, file.sizeBytes)
            sqlite3_bind_int64(stmt, 11, file.allocatedBytes)
            sqlite3_bind_int64(stmt, 12, Int64(bitPattern: file.inode))
            sqlite3_bind_int64(stmt, 13, Int64(bitPattern: file.nlink))
            sqlite3_bind_double(stmt, 14, file.mtime.timeIntervalSince1970)
            bindOptionalText(stmt, 15, file.sha256)
            bindText(stmt, 16, file.status.rawValue)
            try bindOptionalEncrypted(stmt, 17, file.duplicateGroupID, table: "files", column: "duplicate_group_id", token: token)
            try bindOptionalEncrypted(stmt, 18, file.candidateReason, table: "files", column: "candidate_reason", token: token)
            bindData(stmt, 19, try encrypted(file.relativePath, table: "files", column: "relative_path", token: token))
            sqlite3_bind_double(stmt, 20, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
        try withStatement("UPDATE files SET path_token = ? WHERE rowid = last_insert_rowid()") { stmt in bindText(stmt, 1, cipher.token(file.path, domain: "files.path")); try stepDone(stmt) }
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
            let token = cipher.token(family.id, domain: "families.id")
            bindData(stmt, 1, try encrypted(family.id, table: "families", column: "id", token: token))
            bindText(stmt, 2, family.familyType.rawValue)
            bindData(stmt, 3, try encrypted(family.accountHash, table: "families", column: "account_hash", token: token))
            bindData(stmt, 4, try encrypted(family.accountName, table: "families", column: "account_name", token: token))
            bindOptionalText(stmt, 5, family.month)
            bindData(stmt, 6, try encrypted(family.prefix, table: "families", column: "prefix", token: token))
            bindData(stmt, 7, try encrypted(family.highOrRawPath, table: "families", column: "high_or_raw_path", token: token))
            try bindOptionalEncrypted(stmt, 8, family.displayOrPlaybackPath, table: "families", column: "display_or_playback_path", token: token)
            try bindOptionalEncrypted(stmt, 9, family.bubbleOrThumbPath, table: "families", column: "bubble_or_thumb_path", token: token)
            sqlite3_bind_int(stmt, 10, family.isCandidate ? 1 : 0)
            bindData(stmt, 11, try encrypted(family.reason, table: "families", column: "reason", token: token))
            bindData(stmt, 12, try encrypted(pathsJSON, table: "families", column: "member_paths_json", token: token))
            sqlite3_bind_double(stmt, 13, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
        try withStatement("UPDATE families SET id_token = ? WHERE rowid = last_insert_rowid()") { stmt in bindText(stmt, 1, cipher.token(family.id, domain: "families.id")); try stepDone(stmt) }
    }

    private func insert(_ group: DuplicateGroup) throws {
        let pathsJSON = try String(data: JSONEncoder().encode(group.paths), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT OR REPLACE INTO duplicate_groups (
            id, sha256, size_bytes, duplicate_count, reclaimable_bytes, paths_json, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            let token = cipher.token(group.id, domain: "duplicate_groups.id")
            bindData(stmt, 1, try encrypted(group.id, table: "duplicate_groups", column: "id", token: token))
            bindText(stmt, 2, group.sha256)
            sqlite3_bind_int64(stmt, 3, group.sizeBytes)
            sqlite3_bind_int(stmt, 4, Int32(group.duplicateCount))
            sqlite3_bind_int64(stmt, 5, group.reclaimableBytes)
            bindData(stmt, 6, try encrypted(pathsJSON, table: "duplicate_groups", column: "paths_json", token: token))
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
        try withStatement("UPDATE duplicate_groups SET id_token = ? WHERE rowid = last_insert_rowid()") { stmt in bindText(stmt, 1, cipher.token(group.id, domain: "duplicate_groups.id")); try stepDone(stmt) }
    }

    public func verifiedCloudObject(sha256: String, provider: String, bucket: String, objectKey: String) throws -> CloudObject? {
        let sql = """
        SELECT cloud_object_id, sha256, size_bytes, storage_provider, bucket_or_container, object_key,
               uploaded_at, verified_at, verify_status, ref_count, cloud_object_token
        FROM cloud_objects
        WHERE sha256 = ? AND verify_status = ?
        """
        var result: CloudObject?
        try withStatement(sql) { stmt in
            bindText(stmt, 1, sha256)
            bindText(stmt, 2, CloudVerifyStatus.verified.rawValue)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let object = try readCloudObject(stmt, token: columnText(stmt, 10))
                if object.storageProvider == provider && object.bucketOrContainer == bucket && object.objectKey == objectKey { result = object; break }
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
               ab.placeholder_format, ab.placeholder_sha256, ab.placeholder_size, ab.binding_token, co.cloud_object_token
        FROM archive_bindings ab
        JOIN cloud_objects co ON co.cloud_object_token = ab.cloud_object_token
        """
        var snapshots: [String: CloudArchiveSnapshot] = [:]
        try withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bindingToken = columnText(stmt, 24)
                let object = try readCloudObject(stmt, token: columnText(stmt, 25))
                let binding = ArchiveBinding(
                    bindingID: try decryptColumn(stmt, 10, table: "archive_bindings", column: "binding_id", token: bindingToken),
                    filePath: try decryptColumn(stmt, 11, table: "archive_bindings", column: "file_path", token: bindingToken),
                    cloudObjectID: object.cloudObjectID,
                    archiveState: ArchiveBindingState(rawValue: columnText(stmt, 12)) ?? .uploaded,
                    localState: LocalArchiveState(rawValue: columnText(stmt, 13)) ?? .localPresent,
                    restoredAt: optionalDate(stmt, 14),
                    lastRestoreCheckAt: optionalDate(stmt, 15),
                    releasedAt: optionalDate(stmt, 16),
                    quarantinedAt: optionalDate(stmt, 17),
                    quarantinePath: try decryptOptionalColumn(stmt, 18, table: "archive_bindings", column: "quarantine_path", token: bindingToken),
                    placeholderPath: try decryptOptionalColumn(stmt, 19, table: "archive_bindings", column: "placeholder_path", token: bindingToken),
                    placeholderCreatedAt: optionalDate(stmt, 20),
                    placeholderFormat: try decryptOptionalColumn(stmt, 21, table: "archive_bindings", column: "placeholder_format", token: bindingToken),
                    placeholderSHA256: try decryptOptionalColumn(stmt, 22, table: "archive_bindings", column: "placeholder_sha256", token: bindingToken),
                    placeholderSize: optionalInt64(stmt, 23)
                )
                snapshots[binding.filePath] = CloudArchiveSnapshot(object: object, binding: binding)
            }
        }
        return snapshots
    }

    public func archivedFileSnapshots() throws -> [String: ArchivedFileSnapshot] {
        Dictionary(try readArchivedSnapshots().map { ($0.archivedFile.filePath, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func archivedFileSnapshot(bindingID: String) throws -> ArchivedFileSnapshot? {
        try readArchivedSnapshots(bindingID: bindingID).first
    }

    public func archivedFilePage(limit: Int = 50, offset: Int = 0) throws -> [ArchivedFileSnapshot] {
        try readArchivedSnapshots(limit: min(100, max(1, limit)), offset: max(0, offset))
    }

    private func readArchivedSnapshots(bindingID: String? = nil, limit: Int? = nil, offset: Int = 0) throws -> [ArchivedFileSnapshot] {
        var sql = """
        SELECT af.file_path, af.object_type, af.original_filename, af.relative_path, af.account_hash, af.account_name,
               af.month, af.size_bytes, af.sha256, af.mtime, af.family_id, af.display_or_playback_path,
               af.bubble_or_thumb_path, af.archived_at, af.updated_at,
               ab.binding_id, ab.archive_state, ab.local_state, ab.restored_at, ab.last_restore_check_at,
               ab.released_at, ab.quarantined_at, ab.quarantine_path, ab.placeholder_path, ab.placeholder_created_at,
               ab.placeholder_format, ab.placeholder_sha256, ab.placeholder_size,
               co.cloud_object_id, co.sha256, co.size_bytes, co.storage_provider, co.bucket_or_container, co.object_key,
               co.uploaded_at, co.verified_at, co.verify_status, co.ref_count,
               af.file_path_token, ab.binding_token, co.cloud_object_token
        FROM archived_files af
        JOIN archive_bindings ab ON ab.file_path_token = af.file_path_token
        JOIN cloud_objects co ON co.cloud_object_token = ab.cloud_object_token
        """
        if bindingID != nil { sql += " WHERE ab.binding_token = ?" }
        sql += " ORDER BY af.archived_at DESC, ab.binding_token ASC"
        if let limit { sql += " LIMIT \(limit) OFFSET \(offset)" }
        var snapshots: [ArchivedFileSnapshot] = []
        try withStatement(sql) { stmt in
            if let bindingID { bindText(stmt, 1, cipher.token(bindingID, domain: "archive_bindings.binding_id")) }
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let fileToken = columnText(stmt, 38), bindingToken = columnText(stmt, 39)
                let archivedFile = try readArchivedFile(stmt, token: fileToken)
                let binding = ArchiveBinding(
                    bindingID: try decryptColumn(stmt, 15, table: "archive_bindings", column: "binding_id", token: bindingToken),
                    filePath: archivedFile.filePath,
                    cloudObjectID: try decryptColumn(stmt, 28, table: "cloud_objects", column: "cloud_object_id", token: columnText(stmt, 40)),
                    archiveState: ArchiveBindingState(rawValue: columnText(stmt, 16)) ?? .uploaded,
                    localState: LocalArchiveState(rawValue: columnText(stmt, 17)) ?? .localPresent,
                    restoredAt: optionalDate(stmt, 18),
                    lastRestoreCheckAt: optionalDate(stmt, 19),
                    releasedAt: optionalDate(stmt, 20),
                    quarantinedAt: optionalDate(stmt, 21),
                    quarantinePath: try decryptOptionalColumn(stmt, 22, table: "archive_bindings", column: "quarantine_path", token: bindingToken),
                    placeholderPath: try decryptOptionalColumn(stmt, 23, table: "archive_bindings", column: "placeholder_path", token: bindingToken),
                    placeholderCreatedAt: optionalDate(stmt, 24),
                    placeholderFormat: try decryptOptionalColumn(stmt, 25, table: "archive_bindings", column: "placeholder_format", token: bindingToken),
                    placeholderSHA256: try decryptOptionalColumn(stmt, 26, table: "archive_bindings", column: "placeholder_sha256", token: bindingToken),
                    placeholderSize: optionalInt64(stmt, 27)
                )
                let object = try readCloudObject(stmt, offset: 28, token: columnText(stmt, 40))
                snapshots.append(ArchivedFileSnapshot(archivedFile: archivedFile, binding: binding, object: object))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw WeVaultError.sqlite("无法读取归档记录") }
        }
        return snapshots
    }

    public func updateRestoreState(bindingID: String, archiveState: ArchiveBindingState, localState: LocalArchiveState, restoredAt: Date?, lastRestoreCheckAt: Date?) throws {
        try withStatement("""
        UPDATE archive_bindings
        SET archive_state = ?, local_state = ?, restored_at = ?, last_restore_check_at = ?, updated_at = ?
        WHERE binding_token = ?
        """) { stmt in
            bindText(stmt, 1, archiveState.rawValue)
            bindText(stmt, 2, localState.rawValue)
            bindOptionalDate(stmt, 3, restoredAt)
            bindOptionalDate(stmt, 4, lastRestoreCheckAt)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            bindText(stmt, 6, cipher.token(bindingID, domain: "archive_bindings.binding_id"))
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
        WHERE binding_token = ?
        """) { stmt in
            bindText(stmt, 1, archiveState.rawValue)
            bindText(stmt, 2, localState.rawValue)
            bindOptionalDate(stmt, 3, releasedAt)
            bindOptionalDate(stmt, 4, quarantinedAt)
            let token = cipher.token(bindingID, domain: "archive_bindings.binding_id")
            try bindOptionalEncrypted(stmt, 5, quarantinePath, table: "archive_bindings", column: "quarantine_path", token: token)
            try bindOptionalEncrypted(stmt, 6, placeholderPath, table: "archive_bindings", column: "placeholder_path", token: token)
            bindOptionalDate(stmt, 7, placeholderCreatedAt)
            try bindOptionalEncrypted(stmt, 8, placeholderFormat, table: "archive_bindings", column: "placeholder_format", token: token)
            try bindOptionalEncrypted(stmt, 9, placeholderSHA256, table: "archive_bindings", column: "placeholder_sha256", token: token)
            bindOptionalInt64(stmt, 10, placeholderSize)
            sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970)
            bindText(stmt, 12, token)
            try stepDone(stmt)
        }
    }

    public func clearPlaceholderState(bindingID: String) throws {
        try withStatement("""
        UPDATE archive_bindings
        SET placeholder_path = NULL, placeholder_created_at = NULL, placeholder_format = NULL,
            placeholder_sha256 = NULL, placeholder_size = NULL, quarantine_path = NULL,
            updated_at = ?
        WHERE binding_token = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            bindText(stmt, 2, cipher.token(bindingID, domain: "archive_bindings.binding_id"))
            try stepDone(stmt)
        }
    }

    public func saveCloudObject(_ object: CloudObject, binding: ArchiveBinding, archivedFile: ArchivedFile) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try upsert(object)
            if let existing = try archivedFileSnapshot(bindingID: binding.bindingID),
               existing.archivedFile.sha256 == archivedFile.sha256,
               existing.archivedFile.sizeBytes == archivedFile.sizeBytes {
                // Repeated uploads must not reset cooling, restore or quarantine state.
            } else {
                try upsert(binding)
                try upsert(archivedFile)
            }
            try refreshRefCount(cloudObjectID: object.cloudObjectID)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // Encrypted disk-backed work records. Scope names never contain user paths.
    public func workPut<T: Encodable>(scope: String, key: String, value: T, group: String? = nil) throws {
        let token = cipher.token(key, domain: scope)
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try withStatement("INSERT INTO pipeline_records(scope,token,grouping,payload) VALUES(?,?,?,?) ON CONFLICT(scope,token) DO UPDATE SET payload=excluded.payload,grouping=excluded.grouping") { stmt in
            bindText(stmt, 1, scope); bindText(stmt, 2, token)
            bindOptionalText(stmt, 3, group.map { cipher.token($0, domain: scope + ".group") })
            bindData(stmt, 4, try encrypted(json, table: scope, column: "payload", token: token)); try stepDone(stmt)
        }
    }

    public func workGet<T: Decodable>(_ type: T.Type, scope: String, key: String) throws -> T? {
        var value: T?
        let token = cipher.token(key, domain: scope)
        try withStatement("SELECT payload FROM pipeline_records WHERE scope=? AND token=?") { stmt in
            bindText(stmt, 1, scope); bindText(stmt, 2, token)
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW {
                let json = try decryptColumn(stmt, 0, table: scope, column: "payload", token: token)
                value = try JSONDecoder().decode(T.self, from: Data(json.utf8))
            } else if status != SQLITE_DONE { throw WeVaultError.sqlite(lastError) }
        }
        return value
    }

    public func workPage<T: Decodable>(_ type: T.Type, scope: String, after: Int64 = 0, limit: Int = 50) throws -> [(id: Int64, value: T)] {
        var rows: [(Int64, T)] = []
        try withStatement("SELECT id,token,payload FROM pipeline_records WHERE scope=? AND id>? ORDER BY id LIMIT ?") { stmt in
            bindText(stmt, 1, scope); sqlite3_bind_int64(stmt, 2, after); sqlite3_bind_int(stmt, 3, Int32(min(100, max(1, limit))))
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let json = try decryptColumn(stmt, 2, table: scope, column: "payload", token: columnText(stmt, 1))
                rows.append((sqlite3_column_int64(stmt, 0), try JSONDecoder().decode(T.self, from: Data(json.utf8))))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw WeVaultError.sqlite(lastError) }
        }
        return rows
    }

    public func workCount(scope: String, group: String) throws -> Int {
        var count = 0
        try withStatement("SELECT COUNT(*) FROM pipeline_records WHERE scope=? AND grouping=?") { stmt in
            bindText(stmt, 1, scope); bindText(stmt, 2, cipher.token(group, domain: scope + ".group"))
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw WeVaultError.sqlite(lastError) }
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    public func workDelete(scope: String, key: String? = nil) throws {
        try withStatement("DELETE FROM pipeline_records WHERE scope=?" + (key == nil ? "" : " AND token=?")) { stmt in
            bindText(stmt, 1, scope)
            if let key { bindText(stmt, 2, cipher.token(key, domain: scope)) }
            try stepDone(stmt)
        }
    }

    public func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func discardAbandonedScans() throws {
        let current = try currentScanSession()
        var cursor: Int64 = 0
        while true {
            let rows = try workPage(String.self, scope: "scan-sessions", after: cursor)
            if rows.isEmpty { break }
            for row in rows {
                cursor = row.id
                if row.value == current { continue }
                for suffix in [".files", ".families", ".members", ".metadata", ".groups"] { try workDelete(scope: row.value + suffix) }
                try workDelete(scope: "scan-sessions", key: row.value)
            }
        }
    }

    public func publishScan(session: String) throws {
        // Publishing is an atomic pointer change; aborted scans leave the previous view intact.
        try workPut(scope: "scan-publication", key: "current", value: session)
    }

    public func currentScanSession() throws -> String? {
        try workGet(String.self, scope: "scan-publication", key: "current")
    }

    public func archivedSnapshot(path: String) throws -> ArchivedFileSnapshot? {
        var binding: String?
        try withStatement("SELECT binding_id,binding_token FROM archive_bindings WHERE file_path_token=? ORDER BY rowid DESC LIMIT 1") { stmt in
            bindText(stmt, 1, cipher.token(path, domain: "files.path"))
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW { binding = try decryptColumn(stmt, 0, table: "archive_bindings", column: "binding_id", token: columnText(stmt, 1)) }
            else if status != SQLITE_DONE { throw WeVaultError.sqlite(lastError) }
        }
        return try binding.flatMap { try archivedFileSnapshot(bindingID: $0) }
    }

    public func archiveBindingPage(after: Int64 = 0) throws -> [(id: Int64, bindingID: String)] {
        var rows: [(Int64, String)] = []
        try withStatement("SELECT rowid,binding_id,binding_token FROM archive_bindings WHERE rowid>? ORDER BY rowid LIMIT 50") { stmt in
            sqlite3_bind_int64(stmt, 1, after)
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                rows.append((sqlite3_column_int64(stmt, 0), try decryptColumn(stmt, 1, table: "archive_bindings", column: "binding_id", token: columnText(stmt, 2))))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw WeVaultError.sqlite(lastError) }
        }
        return rows
    }

    public func updateFileStatus(path: String, status: ArchiveStatus) throws {
        try withStatement("UPDATE files SET status = ?, updated_at = ? WHERE path_token = ?") { stmt in
            bindText(stmt, 1, status.rawValue)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, 3, cipher.token(path, domain: "files.path"))
            try stepDone(stmt)
        }
    }

    public func logOperation(_ event: String, detail: String?) throws {
        try withStatement("INSERT INTO operations (event, detail, created_at) VALUES (?, ?, ?)") { stmt in
            bindText(stmt, 1, event)
            // Event names are sufficient for the activity feed. Raw diagnostics can contain
            // paths, filenames, object keys, or provider responses, so P3 never persists them
            // in plaintext logs.
            bindOptionalText(stmt, 2, detail == nil ? nil : "[redacted]")
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    /// Stores only a tightly validated provider diagnostic (HTTP status,
    /// provider error code and request ID). Paths, keys and credentials are
    /// deliberately rejected and continue through the redacted logger above.
    public func logDiagnosticOperation(_ event: String, diagnostic: String) throws {
        guard diagnostic.range(of: "^HTTP [0-9]{3}( [A-Za-z0-9_-]{1,80})?( request=[A-Za-z0-9_-]{1,120})?$", options: .regularExpression) != nil else {
            try logOperation(event, detail: diagnostic)
            return
        }
        try withStatement("INSERT INTO operations (event, detail, created_at) VALUES (?, ?, ?)") { stmt in
            bindText(stmt, 1, event)
            bindText(stmt, 2, diagnostic)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    public func recentOperations(limit: Int = 20) throws -> [OperationRecord] {
        let safeLimit = min(max(limit, 1), 200)
        var records: [OperationRecord] = []
        try withStatement("SELECT id, event, detail, created_at, id_token FROM operations ORDER BY id DESC LIMIT ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(safeLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let token = columnText(stmt, 4)
                records.append(OperationRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    event: columnText(stmt, 1),
                    detail: token.isEmpty ? optionalText(stmt, 2) : try decryptOptionalColumn(stmt, 2, table: "operations", column: "detail", token: token),
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
            bindText(stmt, 1, run.id); bindText(stmt, 2, run.taskID); bindText(stmt, 3, run.status.rawValue); bindText(stmt, 4, run.stage.rawValue); sqlite3_bind_int(stmt, 5, Int32(run.completedUnits)); sqlite3_bind_int(stmt, 6, Int32(run.totalUnits)); try bindOptionalEncrypted(stmt, 7, run.failureReason, table: "automation_task_runs", column: "failure_reason", token: run.id); bindOptionalText(stmt, 8, run.retryOfRunID); bindOptionalDate(stmt, 9, run.startedAt); bindOptionalDate(stmt, 10, run.finishedAt); sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970); try stepDone(stmt)
        }
    }

    public func latestAutomationRun(taskID: String) throws -> AutomationTaskRun? {
        var run: AutomationTaskRun?
        try withStatement("SELECT id, task_id, status, stage, completed_units, total_units, failure_reason, retry_of_run_id, started_at, finished_at FROM automation_task_runs WHERE task_id = ? ORDER BY rowid DESC LIMIT 1") { stmt in
            bindText(stmt, 1, taskID)
            if sqlite3_step(stmt) == SQLITE_ROW { run = AutomationTaskRun(id: columnText(stmt, 0), taskID: columnText(stmt, 1), status: AutomationRunStatus(rawValue: columnText(stmt, 2)) ?? .failed, stage: AutomationStage(rawValue: columnText(stmt, 3)) ?? .finished, completedUnits: Int(sqlite3_column_int(stmt, 4)), totalUnits: Int(sqlite3_column_int(stmt, 5)), failureReason: sqlite3_column_type(stmt, 6) == SQLITE_BLOB ? try decryptOptionalColumn(stmt, 6, table: "automation_task_runs", column: "failure_reason", token: columnText(stmt, 0)) : optionalText(stmt, 6), retryOfRunID: sqlite3_column_type(stmt, 7) == SQLITE_BLOB ? try decryptOptionalColumn(stmt, 7, table: "automation_task_runs", column: "retry_of_run_id", token: columnText(stmt, 0)) : optionalText(stmt, 7), startedAt: optionalDate(stmt, 8), finishedAt: optionalDate(stmt, 9)) }
        }
        return run
    }

    public func logAutomation(runID: String?, event: String, detail: String?) throws {
        let token = UUID().uuidString
        try withStatement("INSERT INTO automation_task_logs (run_id, event, detail, created_at, id_token) VALUES (?, ?, ?, ?, ?)") { stmt in
            bindOptionalText(stmt, 1, runID); bindText(stmt, 2, event)
            try bindOptionalEncrypted(stmt, 3, detail, table: "automation_task_logs", column: "detail", token: token)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970); bindText(stmt, 5, token); try stepDone(stmt)
        }
    }

    public func recentAutomationLogs(taskID: String, limit: Int = 20) throws -> [AutomationTaskLog] {
        var logs: [AutomationTaskLog] = []; let safeLimit = min(max(limit, 1), 200)
        try withStatement("SELECT l.id, l.run_id, l.event, l.detail, l.created_at, l.id_token FROM automation_task_logs l JOIN automation_task_runs r ON r.id = l.run_id WHERE r.task_id = ? ORDER BY l.id DESC LIMIT ?") { stmt in
            bindText(stmt, 1, taskID); sqlite3_bind_int(stmt, 2, Int32(safeLimit))
            while sqlite3_step(stmt) == SQLITE_ROW { logs.append(AutomationTaskLog(id: sqlite3_column_int64(stmt, 0), runID: optionalText(stmt, 1), event: columnText(stmt, 2), detail: sqlite3_column_type(stmt, 3) == SQLITE_BLOB ? try decryptOptionalColumn(stmt, 3, table: "automation_task_logs", column: "detail", token: columnText(stmt, 5)) : optionalText(stmt, 3), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))) }
        }
        return logs
    }

    private func upsert(_ object: CloudObject) throws {
        let sql = """
        INSERT OR REPLACE INTO cloud_objects (
            cloud_object_id, sha256, size_bytes, storage_provider, bucket_or_container, object_key,
            uploaded_at, verified_at, verify_status, ref_count, updated_at, cloud_object_token
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            let token = cipher.token(object.cloudObjectID, domain: "cloud_objects.cloud_object_id")
            bindData(stmt, 1, try encrypted(object.cloudObjectID, table: "cloud_objects", column: "cloud_object_id", token: token))
            bindText(stmt, 2, object.sha256)
            sqlite3_bind_int64(stmt, 3, object.sizeBytes)
            bindData(stmt, 4, try encrypted(object.storageProvider, table: "cloud_objects", column: "storage_provider", token: token))
            bindData(stmt, 5, try encrypted(object.bucketOrContainer, table: "cloud_objects", column: "bucket_or_container", token: token))
            bindData(stmt, 6, try encrypted(object.objectKey, table: "cloud_objects", column: "object_key", token: token))
            sqlite3_bind_double(stmt, 7, object.uploadedAt.timeIntervalSince1970)
            bindOptionalDate(stmt, 8, object.verifiedAt)
            bindText(stmt, 9, object.verifyStatus.rawValue)
            sqlite3_bind_int(stmt, 10, Int32(object.refCount))
            sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970); bindText(stmt, 12, token)
            try stepDone(stmt)
        }
    }

    private func upsert(_ binding: ArchiveBinding) throws {
        let sql = """
        INSERT INTO archive_bindings (
            binding_id, file_path, cloud_object_id, archive_state, local_state,
            restored_at, last_restore_check_at, released_at, quarantined_at, quarantine_path,
            placeholder_path, placeholder_created_at, placeholder_format, placeholder_sha256,
            placeholder_size, updated_at, binding_token, file_path_token, cloud_object_token
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(binding_token) DO UPDATE SET
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
            let token = cipher.token(binding.bindingID, domain: "archive_bindings.binding_id")
            bindData(stmt, 1, try encrypted(binding.bindingID, table: "archive_bindings", column: "binding_id", token: token))
            bindData(stmt, 2, try encrypted(binding.filePath, table: "archive_bindings", column: "file_path", token: token))
            bindData(stmt, 3, try encrypted(binding.cloudObjectID, table: "archive_bindings", column: "cloud_object_id", token: token))
            bindText(stmt, 4, binding.archiveState.rawValue)
            bindText(stmt, 5, binding.localState.rawValue)
            bindOptionalDate(stmt, 6, binding.restoredAt)
            bindOptionalDate(stmt, 7, binding.lastRestoreCheckAt)
            bindOptionalDate(stmt, 8, binding.releasedAt)
            bindOptionalDate(stmt, 9, binding.quarantinedAt)
            try bindOptionalEncrypted(stmt, 10, binding.quarantinePath, table: "archive_bindings", column: "quarantine_path", token: token)
            try bindOptionalEncrypted(stmt, 11, binding.placeholderPath, table: "archive_bindings", column: "placeholder_path", token: token)
            bindOptionalDate(stmt, 12, binding.placeholderCreatedAt)
            try bindOptionalEncrypted(stmt, 13, binding.placeholderFormat, table: "archive_bindings", column: "placeholder_format", token: token)
            try bindOptionalEncrypted(stmt, 14, binding.placeholderSHA256, table: "archive_bindings", column: "placeholder_sha256", token: token)
            bindOptionalInt64(stmt, 15, binding.placeholderSize)
            sqlite3_bind_double(stmt, 16, Date().timeIntervalSince1970)
            bindText(stmt, 17, token); bindText(stmt, 18, cipher.token(binding.filePath, domain: "files.path")); bindText(stmt, 19, cipher.token(binding.cloudObjectID, domain: "cloud_objects.cloud_object_id"))
            try stepDone(stmt)
        }
    }

    private func upsert(_ archivedFile: ArchivedFile) throws {
        let sql = """
        INSERT INTO archived_files (
            file_path, object_type, original_filename, relative_path, account_hash, account_name,
            month, size_bytes, sha256, mtime, family_id, display_or_playback_path,
            bubble_or_thumb_path, archived_at, updated_at, file_path_token
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_path_token) DO UPDATE SET
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
            let token = cipher.token(archivedFile.filePath, domain: "files.path")
            bindData(stmt, 1, try encrypted(archivedFile.filePath, table: "archived_files", column: "file_path", token: token))
            bindText(stmt, 2, archivedFile.objectType.rawValue)
            bindData(stmt, 3, try encrypted(archivedFile.originalFilename, table: "archived_files", column: "original_filename", token: token))
            bindData(stmt, 4, try encrypted(archivedFile.relativePath, table: "archived_files", column: "relative_path", token: token))
            bindData(stmt, 5, try encrypted(archivedFile.accountHash, table: "archived_files", column: "account_hash", token: token))
            bindData(stmt, 6, try encrypted(archivedFile.accountName, table: "archived_files", column: "account_name", token: token))
            bindOptionalText(stmt, 7, archivedFile.month)
            sqlite3_bind_int64(stmt, 8, archivedFile.sizeBytes)
            bindData(stmt, 9, try encrypted(archivedFile.sha256, table: "archived_files", column: "sha256", token: token))
            sqlite3_bind_double(stmt, 10, archivedFile.mtime.timeIntervalSince1970)
            try bindOptionalEncrypted(stmt, 11, archivedFile.familyID, table: "archived_files", column: "family_id", token: token)
            try bindOptionalEncrypted(stmt, 12, archivedFile.displayOrPlaybackPath, table: "archived_files", column: "display_or_playback_path", token: token)
            try bindOptionalEncrypted(stmt, 13, archivedFile.bubbleOrThumbPath, table: "archived_files", column: "bubble_or_thumb_path", token: token)
            sqlite3_bind_double(stmt, 14, archivedFile.archivedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 15, archivedFile.updatedAt.timeIntervalSince1970); bindText(stmt, 16, token)
            try stepDone(stmt)
        }
    }

    private func refreshRefCount(cloudObjectID: String) throws {
        let sql = """
        UPDATE cloud_objects
        SET ref_count = (SELECT COUNT(*) FROM archive_bindings WHERE cloud_object_token = ?), updated_at = ?
        WHERE cloud_object_token = ?
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, cipher.token(cloudObjectID, domain: "cloud_objects.cloud_object_id"))
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, 3, cipher.token(cloudObjectID, domain: "cloud_objects.cloud_object_id"))
            try stepDone(stmt)
        }
    }

    private func readArchivedFile(_ stmt: OpaquePointer?, token: String) throws -> ArchivedFile {
        ArchivedFile(
            filePath: try decryptColumn(stmt, 0, table: "archived_files", column: "file_path", token: token),
            objectType: ArchiveObjectType(rawValue: columnText(stmt, 1)) ?? .ordinaryFile,
            originalFilename: try decryptColumn(stmt, 2, table: "archived_files", column: "original_filename", token: token),
            relativePath: try decryptColumn(stmt, 3, table: "archived_files", column: "relative_path", token: token),
            accountHash: try decryptColumn(stmt, 4, table: "archived_files", column: "account_hash", token: token),
            accountName: try decryptColumn(stmt, 5, table: "archived_files", column: "account_name", token: token),
            month: optionalText(stmt, 6),
            sizeBytes: sqlite3_column_int64(stmt, 7),
            sha256: try decryptColumn(stmt, 8, table: "archived_files", column: "sha256", token: token),
            mtime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
            familyID: try decryptOptionalColumn(stmt, 10, table: "archived_files", column: "family_id", token: token),
            displayOrPlaybackPath: try decryptOptionalColumn(stmt, 11, table: "archived_files", column: "display_or_playback_path", token: token),
            bubbleOrThumbPath: try decryptOptionalColumn(stmt, 12, table: "archived_files", column: "bubble_or_thumb_path", token: token),
            archivedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
        )
    }

    private func readCloudObject(_ stmt: OpaquePointer?, offset: Int32 = 0, token: String) throws -> CloudObject {
        CloudObject(
            cloudObjectID: try decryptColumn(stmt, offset, table: "cloud_objects", column: "cloud_object_id", token: token),
            sha256: columnText(stmt, offset + 1),
            sizeBytes: sqlite3_column_int64(stmt, offset + 2),
            storageProvider: try decryptColumn(stmt, offset + 3, table: "cloud_objects", column: "storage_provider", token: token),
            bucketOrContainer: try decryptColumn(stmt, offset + 4, table: "cloud_objects", column: "bucket_or_container", token: token),
            objectKey: try decryptColumn(stmt, offset + 5, table: "cloud_objects", column: "object_key", token: token),
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

    private func verifyIntegrity() throws {
        var healthy = false
        try withStatement("PRAGMA quick_check") { stmt in
            healthy = sqlite3_step(stmt) == SQLITE_ROW && columnText(stmt, 0).lowercased() == "ok"
        }
        guard healthy else { throw WeVaultError.manifest(.sqliteCorrupt) }
        // Validate every encrypted row at open. This is intentionally streaming and fail-closed;
        // P7 can optimize scheduling but must not weaken this security gate.
        for (table, tokenColumn, columns) in [
            ("files", "path_token", ["path", "original_filename", "relative_path"]),
            ("families", "id_token", ["high_or_raw_path", "member_paths_json"]),
            ("cloud_objects", "cloud_object_token", ["cloud_object_id", "bucket_or_container", "object_key"]),
            ("archive_bindings", "binding_token", ["binding_id", "file_path", "cloud_object_id"]),
            ("archived_files", "file_path_token", ["file_path", "original_filename"])
        ] {
            try withStatement("SELECT \(tokenColumn), \(columns.joined(separator: ", ")) FROM \(table)") { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let token = columnText(stmt, 0)
                    guard !token.isEmpty else { throw WeVaultError.manifest(.malformedEncryptedField) }
                    for (offset, column) in columns.enumerated() {
                        _ = try decryptColumn(stmt, Int32(offset + 1), table: table, column: column, token: token)
                    }
                }
            }
        }
    }

    private func encrypted(_ value: String, table: String, column: String, token: String) throws -> Data {
        do { return try cipher.seal(value, context: "\(table).\(column).\(token)") }
        catch let failure as ManifestFailure { throw WeVaultError.manifest(failure) }
    }

    private func bindOptionalEncrypted(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?, table: String, column: String, token: String) throws {
        if let value { bindData(stmt, index, try encrypted(value, table: table, column: column, token: token)) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func decryptColumn(_ stmt: OpaquePointer?, _ index: Int32, table: String, column: String, token: String) throws -> String {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return "" }
        guard let bytes = sqlite3_column_blob(stmt, index) else { throw WeVaultError.manifest(.malformedEncryptedField) }
        let length = Int(sqlite3_column_bytes(stmt, index))
        do { return try cipher.open(Data(bytes: bytes, count: length), context: "\(table).\(column).\(token)") }
        catch let failure as ManifestFailure { throw WeVaultError.manifest(failure) }
    }

    private func decryptOptionalColumn(_ stmt: OpaquePointer?, _ index: Int32, table: String, column: String, token: String) throws -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return try decryptColumn(stmt, index, table: table, column: column, token: token)
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

private func bindData(_ stmt: OpaquePointer?, _ index: Int32, _ value: Data) {
    _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
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
