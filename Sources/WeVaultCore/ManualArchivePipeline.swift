import Foundation

public struct ManualUploadSummary: Sendable {
    public var attempted = 0
    public var verified = 0
    public var failed = 0
}

/// Manual work shares the scanner's encrypted disk staging, but never invokes release.
public enum ManualArchivePipeline {
    public typealias Upload = @Sendable ([FileRecord], [FamilyRecord], ManifestStore) async throws -> Void

    public static func scan(root: URL, threshold: Int64, store: ManifestStore) async throws -> String {
        try store.logOperation("SCAN_STARTED", detail: nil)
        do {
            let session = try await WeChatScanner().scanBatches(root: root, options: ScanOptions(largeFileThresholdBytes: threshold), store: store, includeArchivedRecords: true) { _, _ in }
            try store.logOperation("SCAN_FINISHED", detail: nil)
            return session
        } catch {
            try? store.logOperation(error is CancellationError ? "SCAN_CANCELLED" : "SCAN_FAILED", detail: nil)
            throw error
        }
    }

    public static func upload(session: String, root: URL, threshold: Int64, store: ManifestStore,
                              progress: @Sendable (ManualUploadSummary) async -> Void = { _ in },
                              upload: Upload) async throws -> ManualUploadSummary {
        guard try store.currentScanSession() == session,
              try store.workGet(String.self, scope: session + ".metadata", key: "root") == root.standardizedFileURL.path else {
            throw WeVaultError.fileSystem("扫描范围已变化，请重新扫描")
        }
        var summary = ManualUploadSummary(), cursor: Int64 = 0
        while true {
            try Task.checkCancellation()
            let page = try store.workPage(FileRecord.self, scope: session + ".files", after: cursor)
            guard let last = page.last else { break }
            cursor = last.id
            let candidates = page.map(\.value).filter {
                $0.sha256 != nil && ![.notArchivable, .tombstoned, .localReleased, .releaseEligible].contains($0.status) &&
                ($0.objectType != .ordinaryFile || $0.sizeBytes >= threshold || $0.duplicateGroupID != nil)
            }
            guard !candidates.isEmpty else { continue }
            let families = try candidates.compactMap { try store.workGet(FamilyRecord.self, scope: session + ".families", key: $0.path) }
            try await upload(candidates, families, store)
            for var file in candidates {
                let archive = try store.archivedSnapshot(path: file.path)
                let verified = archive?.object.verifyStatus == .verified && archive?.archivedFile.sha256 == file.sha256
                file.status = verified ? .verified : .uploadFailed
                summary.attempted += 1
                if verified { summary.verified += 1 } else { summary.failed += 1 }
                try store.workPut(scope: session + ".files", key: file.path, value: file, group: file.objectType == .ordinaryFile ? file.sha256 : nil)
            }
            await progress(summary)
        }
        return summary
    }
}
