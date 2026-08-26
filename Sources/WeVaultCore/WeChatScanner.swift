import Foundation

public struct ScanOptions: Sendable {
    public var largeFileThresholdBytes: Int64
    public var knownPlaceholderPaths: Set<String>

    public init(largeFileThresholdBytes: Int64 = 50 * 1024 * 1024, knownPlaceholderPaths: Set<String> = []) {
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.knownPlaceholderPaths = knownPlaceholderPaths
    }
}

public final class WeChatScanner: Sendable {
    public init() {}

    public func scan(root: URL, options: ScanOptions = ScanOptions()) throws -> ScanResult {
        let scanRoot = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scanRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WeVaultError.invalidScanRoot(scanRoot.path)
        }

        let accountRoots = try accountDirectories(for: scanRoot)
        var files: [FileRecord] = []
        var imageMembers: [String: [String: URL]] = [:]
        var videoMembers: [String: [String: URL]] = [:]
        var videoPlaybackStats = ByteCountStats()

        for accountRoot in accountRoots {
            let accountName = accountRoot.lastPathComponent
            let accountHash = String(sha256Hex(accountName).prefix(16))
            let baseRoot = accountRoot.deletingLastPathComponent()
            let ordinaryRoot = accountRoot.appendingPathComponent("msg/file")
            let attachRoot = accountRoot.appendingPathComponent("msg/attach")
            let videoRoot = accountRoot.appendingPathComponent("msg/video")

            files.append(contentsOf: try scanOrdinaryFiles(root: ordinaryRoot, baseRoot: baseRoot, accountName: accountName, accountHash: accountHash, knownPlaceholderPaths: options.knownPlaceholderPaths))
            collectImageMembers(root: attachRoot, accountName: accountName, accountHash: accountHash, members: &imageMembers)
            collectVideoMembers(root: videoRoot, accountName: accountName, accountHash: accountHash, members: &videoMembers, playbackStats: &videoPlaybackStats)
        }

        let imageFamilies = buildImageFamilies(imageMembers)
        let videoFamilies = buildVideoFamilies(videoMembers)
        files.append(contentsOf: try recordsForCandidateFamilies(imageFamilies))
        files.append(contentsOf: try recordsForCandidateFamilies(videoFamilies))

        hashLargeOrdinaryCandidates(&files, threshold: options.largeFileThresholdBytes)
        hashMediaCandidates(&files)
        let duplicateGroups = try hashAndGroupOrdinaryDuplicates(&files)
        let families = imageFamilies + videoFamilies
        let summary = summarize(files: files, duplicateGroups: duplicateGroups, threshold: options.largeFileThresholdBytes, videoPlaybackStats: videoPlaybackStats)

        return ScanResult(
            rootPath: scanRoot.path,
            scannedAt: Date(),
            largeFileThresholdBytes: options.largeFileThresholdBytes,
            files: files.sorted { lhs, rhs in
                if lhs.objectType.rawValue != rhs.objectType.rawValue {
                    return lhs.objectType.rawValue < rhs.objectType.rawValue
                }
                return lhs.sizeBytes > rhs.sizeBytes
            },
            families: families,
            duplicateGroups: duplicateGroups,
            summary: summary
        )
    }

    private func accountDirectories(for root: URL) throws -> [URL] {
        if root.lastPathComponent.hasPrefix("wxid_") {
            return [root]
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let accounts = children.filter { url in
            guard url.lastPathComponent.hasPrefix("wxid_") else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }
        if accounts.isEmpty {
            throw WeVaultError.invalidScanRoot("No wxid_* account directory found under \(root.path)")
        }
        return accounts.sorted { $0.path < $1.path }
    }

    private func scanOrdinaryFiles(root: URL, baseRoot: URL, accountName: String, accountHash: String, knownPlaceholderPaths: Set<String>) throws -> [FileRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [FileRecord] = []
        let months = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard isMonth(url.lastPathComponent) else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }

        for monthURL in months {
            guard let enumerator = FileManager.default.enumerator(
                at: monthURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                if knownPlaceholderPaths.contains(url.path) {
                    continue
                }
                let stat = try fileStat(url.path)
                if Tombstone.isTombstone(url) {
                    result.append(FileRecord(
                        path: url.path,
                        relativePath: url.pathRelative(to: baseRoot),
                        objectType: .ordinaryFile,
                        accountHash: accountHash,
                        accountName: accountName,
                        filename: url.lastPathComponent,
                        fileExtension: url.pathExtension.lowercased(),
                        month: monthURL.lastPathComponent,
                        sizeBytes: stat.size,
                        allocatedBytes: stat.allocated,
                        inode: stat.inode,
                        nlink: stat.nlink,
                        mtime: stat.mtime,
                        status: .notArchivable,
                        candidateReason: "疑似转发了 WeVault tombstone 占位文件；请恢复原件后重新发送"
                    ))
                    continue
                }
                result.append(FileRecord(
                    path: url.path,
                    relativePath: url.pathRelative(to: baseRoot),
                    objectType: .ordinaryFile,
                    accountHash: accountHash,
                    accountName: accountName,
                    filename: url.lastPathComponent,
                    fileExtension: url.pathExtension.lowercased(),
                    month: monthURL.lastPathComponent,
                    sizeBytes: stat.size,
                    allocatedBytes: stat.allocated,
                    inode: stat.inode,
                    nlink: stat.nlink,
                    mtime: stat.mtime,
                    status: .discovered
                ))
            }
        }
        return result
    }

    private func collectImageMembers(root: URL, accountName: String, accountHash: String, members: inout [String: [String: URL]]) {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let filename = url.lastPathComponent
            guard let prefix = datFamilyPrefix(filename) else { continue }
            let parts = url.pathComponents
            let month = parts.first(where: isMonth)
            let resourceID = resourceIDForAttachPath(parts)
            let role = imageRole(filename)
            let key = [accountHash, accountName, month ?? "", resourceID ?? "", prefix].joined(separator: "|")
            members[key, default: [:]][role] = url
        }
    }

    private func collectVideoMembers(root: URL, accountName: String, accountHash: String, members: inout [String: [String: URL]], playbackStats: inout ByteCountStats) {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let parsed = videoFamilyPrefixAndRole(url.lastPathComponent) else { continue }
            if parsed.role == "play", let size = try? fileStat(url.path).size {
                playbackStats.count += 1
                playbackStats.bytes += size
            }
            let parts = url.pathComponents
            let month = parts.first(where: isMonth)
            let key = [accountHash, accountName, month ?? "", parsed.prefix].joined(separator: "|")
            members[key, default: [:]][parsed.role] = url
        }
    }

    private func buildImageFamilies(_ groups: [String: [String: URL]]) -> [FamilyRecord] {
        groups.compactMap { key, members in
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5 else { return nil }
            let accountHash = parts[0]
            let accountName = parts[1]
            let month = parts[2].isEmpty ? nil : parts[2]
            let prefix = parts[4]
            let high = members["high"] ?? members["highMedium"]
            guard let high else { return nil }
            let display = members["normal"] ?? members["medium"]
            let bubble = members["bubble"] ?? members["thumb"]
            let isCandidate = display != nil
            let reason = isCandidate
                ? "高清层候选：普通查看层保留在本地"
                : "不可归档候选：缺少普通查看层"
            return FamilyRecord(
                id: "image|\(key)",
                familyType: .imageHighLayer,
                accountHash: accountHash,
                accountName: accountName,
                month: month,
                prefix: prefix,
                highOrRawPath: high.path,
                displayOrPlaybackPath: display?.path,
                bubbleOrThumbPath: bubble?.path,
                isCandidate: isCandidate,
                reason: reason,
                memberPaths: members.values.map(\.path).sorted()
            )
        }.sorted { $0.highOrRawPath < $1.highOrRawPath }
    }

    private func buildVideoFamilies(_ groups: [String: [String: URL]]) -> [FamilyRecord] {
        groups.compactMap { key, members in
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return nil }
            guard let raw = members["raw"] else { return nil }
            var play = members["play"]
            let thumb = members["thumb"] ?? members["cover"]
            var isCandidate = play != nil
            var reason = isCandidate
                ? "Raw 层候选：普通播放 .mp4 保留在本地"
                : "不可归档候选：缺少普通播放 .mp4"
            if let play {
                let rawSize = (try? fileStat(raw.path).size) ?? 0
                let playSize = (try? fileStat(play.path).size) ?? 0
                if rawSize <= playSize {
                    isCandidate = false
                    reason = "不可归档候选：_raw.mp4 不大于普通播放 .mp4"
                }
            } else {
                let siblingPlay = raw.deletingLastPathComponent().appendingPathComponent("\(parts[3]).mp4")
                if FileManager.default.fileExists(atPath: siblingPlay.path) {
                    play = siblingPlay
                    isCandidate = true
                    reason = "Raw 层候选：按同目录同 prefix 发现普通播放 .mp4"
                }
            }
            return FamilyRecord(
                id: "video|\(key)",
                familyType: .videoRawLayer,
                accountHash: parts[0],
                accountName: parts[1],
                month: parts[2].isEmpty ? nil : parts[2],
                prefix: parts[3],
                highOrRawPath: raw.path,
                displayOrPlaybackPath: play?.path,
                bubbleOrThumbPath: thumb?.path,
                isCandidate: isCandidate,
                reason: reason,
                memberPaths: members.values.map(\.path).sorted()
            )
        }.sorted { $0.highOrRawPath < $1.highOrRawPath }
    }

    private func recordsForCandidateFamilies(_ families: [FamilyRecord]) throws -> [FileRecord] {
        try families.map { family in
            let url = URL(fileURLWithPath: family.highOrRawPath)
            let stat = try fileStat(url.path)
            return FileRecord(
                path: url.path,
                relativePath: url.path,
                objectType: family.familyType,
                accountHash: family.accountHash,
                accountName: family.accountName,
                filename: url.lastPathComponent,
                fileExtension: url.pathExtension.lowercased(),
                month: family.month,
                sizeBytes: stat.size,
                allocatedBytes: stat.allocated,
                inode: stat.inode,
                nlink: stat.nlink,
                mtime: stat.mtime,
                status: family.isCandidate ? .discovered : .notArchivable,
                candidateReason: family.reason
            )
        }
    }

    private func hashMediaCandidates(_ files: inout [FileRecord]) {
        for index in files.indices where files[index].objectType != .ordinaryFile && files[index].status != .notArchivable {
            if let digest = try? sha256File(URL(fileURLWithPath: files[index].path)) {
                files[index].sha256 = digest
                files[index].status = .hashed
            }
        }
    }

    private func hashLargeOrdinaryCandidates(_ files: inout [FileRecord], threshold: Int64) {
        for index in files.indices where files[index].objectType == .ordinaryFile && files[index].sizeBytes >= threshold {
            if let digest = try? sha256File(URL(fileURLWithPath: files[index].path)) {
                files[index].sha256 = digest
                files[index].status = .hashed
                files[index].candidateReason = "普通大文件候选：达到当前阈值 \(humanBytes(threshold))"
            }
        }
    }

    private func hashAndGroupOrdinaryDuplicates(_ files: inout [FileRecord]) throws -> [DuplicateGroup] {
        var ordinaryBySize: [Int64: [Int]] = [:]
        for index in files.indices where files[index].objectType == .ordinaryFile {
            ordinaryBySize[files[index].sizeBytes, default: []].append(index)
        }

        for indices in ordinaryBySize.values where indices.count > 1 {
            for index in indices {
                if files[index].sha256 == nil {
                    files[index].sha256 = try sha256File(URL(fileURLWithPath: files[index].path))
                    files[index].status = .hashed
                }
            }
        }

        var byHash: [String: [Int]] = [:]
        for index in files.indices where files[index].objectType == .ordinaryFile {
            guard let digest = files[index].sha256 else { continue }
            byHash[digest, default: []].append(index)
        }

        var groups: [DuplicateGroup] = []
        var number = 1
        for (digest, indices) in byHash where indices.count > 1 {
            let size = files[indices[0]].sizeBytes
            let groupID = "dup-\(number)"
            number += 1
            for index in indices {
                files[index].duplicateGroupID = groupID
                files[index].status = .duplicateGrouped
            }
            groups.append(DuplicateGroup(
                id: groupID,
                sha256: digest,
                sizeBytes: size,
                duplicateCount: indices.count,
                reclaimableBytes: Int64(indices.count - 1) * size,
                paths: indices.map { files[$0].path }.sorted()
            ))
        }
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private func summarize(files: [FileRecord], duplicateGroups: [DuplicateGroup], threshold: Int64, videoPlaybackStats: ByteCountStats) -> ScanSummary {
        let ordinary = files.filter { $0.objectType == .ordinaryFile }
        let largeOrdinary = ordinary.filter { $0.sizeBytes >= threshold }
        let imageCandidates = files.filter { $0.objectType == .imageHighLayer && $0.status != .notArchivable }
        let videoRawDiscovered = files.filter { $0.objectType == .videoRawLayer }
        let videoCandidates = videoRawDiscovered.filter { $0.status != .notArchivable }
        return ScanSummary(
            ordinaryCount: ordinary.count,
            ordinaryBytes: ordinary.reduce(0) { $0 + $1.sizeBytes },
            largeOrdinaryCount: largeOrdinary.count,
            largeOrdinaryBytes: largeOrdinary.reduce(0) { $0 + $1.sizeBytes },
            imageHighCandidateCount: imageCandidates.count,
            imageHighCandidateBytes: imageCandidates.reduce(0) { $0 + $1.sizeBytes },
            videoRawCandidateCount: videoCandidates.count,
            videoRawCandidateBytes: videoCandidates.reduce(0) { $0 + $1.sizeBytes },
            videoRawDiscoveredCount: videoRawDiscovered.count,
            videoRawDiscoveredBytes: videoRawDiscovered.reduce(0) { $0 + $1.sizeBytes },
            videoPlaybackDiscoveredCount: videoPlaybackStats.count,
            videoPlaybackDiscoveredBytes: videoPlaybackStats.bytes,
            duplicateReclaimableBytes: duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
        )
    }

    private func imageRole(_ filename: String) -> String {
        let stem = filename.hasSuffix(".dat") ? String(filename.dropLast(4)) : filename
        if stem.hasSuffix("_h_M") { return "highMedium" }
        if stem.hasSuffix("_h") { return "high" }
        if stem.hasSuffix("_M") { return "medium" }
        if stem.hasSuffix("_b") { return "bubble" }
        if stem.hasSuffix("_t") { return "thumb" }
        return "normal"
    }

    private func resourceIDForAttachPath(_ parts: [String]) -> String? {
        guard let index = parts.firstIndex(of: "attach"), index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }
}

private struct ByteCountStats {
    var count = 0
    var bytes: Int64 = 0
}
