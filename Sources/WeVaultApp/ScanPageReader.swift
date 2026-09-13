import Foundation
import WeVaultCore

struct ScanPage: Sendable {
    let session: String
    let result: ScanResult
    let archived: [String: ArchivedFileSnapshot]
    let cloud: [String: CloudArchiveSnapshot]
    let count: Int
    let hasNext: Bool
    let lastBoundary: FileRecord?
}

enum ScanPageReader {
    /// Plaintext sort fields remain in memory for at most a database batch and 51 matches.
    static func load(store: ManifestStore, root: URL, previousSession: String?, boundary: FileRecord?,
                     filter: RecordFilter, sort: [KeyPathComparator<FileRecord>], threshold: Int64) throws -> ScanPage? {
        try store.readTransaction {
            let storedSession = try store.currentScanSession()
            let hasScan = try storedSession.map { try store.workGet(String.self, scope: $0 + ".metadata", key: "root") == root.standardizedFileURL.path } ?? false
            let session = hasScan ? storedSession! : "archive-only"
            let boundary = session == previousSession ? boundary : nil
            func precedes(_ lhs: FileRecord, _ rhs: FileRecord) -> Bool {
                for comparator in sort {
                    let value = comparator.compare(lhs, rhs)
                    if value != .orderedSame { return value == .orderedAscending }
                }
                return lhs.path < rhs.path
            }
            func matches(_ file: FileRecord) -> Bool {
                switch filter {
                case .all: true
                case .ordinary: file.objectType == .ordinaryFile
                case .image: file.objectType == .imageHighLayer
                case .video: file.objectType == .videoRawLayer
                case .duplicates: file.duplicateGroupID != nil
                }
            }
            var rows: [FileRecord] = [], cursor: Int64 = 0, count = 0
            var archiveSummary = ScanSummary.zero
            func include(_ file: FileRecord) {
                guard matches(file) else { return }
                count += 1
                if let boundary, !precedes(boundary, file) { return }
                let index = rows.firstIndex { precedes(file, $0) } ?? rows.endIndex
                if index < 51 {
                    rows.insert(file, at: index)
                    if rows.count > 51 { rows.removeLast() }
                }
            }
            while true {
                try Task.checkCancellation()
                if hasScan {
                    let batch = try store.workPage(FileRecord.self, scope: session + ".files", after: cursor)
                    guard let last = batch.last else { break }
                    cursor = last.id
                    for row in batch {
                        var file = row.value
                        if let snapshot = try store.archivedSnapshot(path: file.path),
                           snapshot.archivedFile.sha256 == file.sha256,
                           snapshot.object.verifyStatus == .verified {
                            file = snapshot.displayFileRecord
                            file.duplicateGroupID = row.value.duplicateGroupID
                        }
                        // Sort and paginate the same original metadata that the table displays.
                        include(file)
                    }
                } else {
                    let batch = try store.archiveBindingPage(after: cursor)
                    guard let last = batch.last else { break }
                    cursor = last.id
                    for row in batch {
                        guard let snapshot = try store.archivedFileSnapshot(bindingID: row.bindingID),
                              LocalReleaseService.isUnderRoot(snapshot.archivedFile.filePath, root: root) else { continue }
                        let file = snapshot.displayFileRecord
                        include(file)
                        archiveSummary = archiveSummary.adding(summary(for: file, threshold: threshold))
                    }
                }
            }
            // Older automatic scans contain only files found on disk. Merge missing
            // released originals before filtering/pagination, without duplicating paths.
            if hasScan {
                var archiveCursor: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let batch = try store.archiveBindingPage(after: archiveCursor)
                    guard let last = batch.last else { break }
                    archiveCursor = last.id
                    for row in batch {
                        guard let snapshot = try store.archivedFileSnapshot(bindingID: row.bindingID),
                              LocalReleaseService.isUnderRoot(snapshot.archivedFile.filePath, root: root),
                              [.quarantined, .tombstoned, .localReleased].contains(snapshot.binding.localState),
                              try store.workGet(FileRecord.self, scope: session + ".files", key: snapshot.archivedFile.filePath) == nil else { continue }
                        include(snapshot.displayFileRecord)
                    }
                }
            }
            var visible: [FileRecord] = [], families: [FamilyRecord] = []
            var archived: [String: ArchivedFileSnapshot] = [:], cloud: [String: CloudArchiveSnapshot] = [:]
            for row in rows.prefix(50) {
                var file = row
                if let snapshot = try store.archivedSnapshot(path: file.path), snapshot.archivedFile.sha256 == file.sha256 {
                    archived[file.path] = snapshot
                    cloud[file.path] = CloudArchiveSnapshot(object: snapshot.object, binding: snapshot.binding)
                    if snapshot.object.verifyStatus == .verified {
                        file = ScanViewModel.displayRecord(for: snapshot)
                        file.duplicateGroupID = row.duplicateGroupID
                    }
                }
                if let family = try store.workGet(FamilyRecord.self, scope: session + ".families", key: file.path) { families.append(family) }
                visible.append(file)
            }
            let summary = hasScan ? try store.workGet(ScanSummary.self, scope: session + ".metadata", key: "summary") ?? .zero : archiveSummary
            return ScanPage(session: session, result: ScanResult(rootPath: root.path, scannedAt: Date(), largeFileThresholdBytes: threshold, files: visible, families: families, duplicateGroups: [], summary: summary),
                archived: archived, cloud: cloud, count: count, hasNext: rows.count > 50, lastBoundary: rows.prefix(50).last)
        }
    }
    private static func summary(for file: FileRecord, threshold: Int64) -> ScanSummary {
        let ordinary = file.objectType == .ordinaryFile, image = file.objectType == .imageHighLayer, video = file.objectType == .videoRawLayer
        let large = ordinary && file.sizeBytes >= threshold
        return ScanSummary(ordinaryCount: ordinary ? 1 : 0, ordinaryBytes: ordinary ? file.sizeBytes : 0,
            largeOrdinaryCount: large ? 1 : 0, largeOrdinaryBytes: large ? file.sizeBytes : 0,
            imageHighCandidateCount: image ? 1 : 0, imageHighCandidateBytes: image ? file.sizeBytes : 0,
            videoRawCandidateCount: video ? 1 : 0, videoRawCandidateBytes: video ? file.sizeBytes : 0,
            videoRawDiscoveredCount: video ? 1 : 0, videoRawDiscoveredBytes: video ? file.sizeBytes : 0,
            videoPlaybackDiscoveredCount: 0, videoPlaybackDiscoveredBytes: 0, duplicateReclaimableBytes: 0)
    }

}
