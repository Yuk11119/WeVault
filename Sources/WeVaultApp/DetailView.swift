import SwiftUI
import WeVaultCore

struct DetailView: View {
    @State private var createTombstone = true

    let file: FileRecord?
    let families: [FamilyRecord]
    let cloudSnapshot: CloudArchiveSnapshot?
    let archivedSnapshot: ArchivedFileSnapshot?
    let isRestoring: Bool
    let isReleasing: Bool
    let onOpenRestoreCenter: () -> Void
    let onQuarantineLocal: (Bool) -> Void
    let onRollbackLocal: () -> Void
    let onFinalizeLocalRelease: () -> Void

    var family: FamilyRecord? {
        guard let file else { return nil }
        return families.first { $0.highOrRawPath == file.path }
    }

    var uploadStatus: UserUploadStatus? {
        file.map { UserUploadStatus(file: $0, cloudSnapshot: cloudSnapshot) }
    }

    var canQuarantineLocal: Bool {
        guard let archivedSnapshot else { return false }
        switch archivedSnapshot.archivedFile.objectType {
        case .ordinaryFile:
            return LocalReleaseService.isEligibleForPhase5Quarantine(archivedSnapshot) && !isReleasing
        case .imageHighLayer:
            return LocalReleaseService.isEligibleForPhase6ImageHighLayerRelease(archivedSnapshot) && !isReleasing
        case .videoRawLayer:
            return LocalReleaseService.isEligibleForPhase7VideoRawLayerRelease(archivedSnapshot) && !isReleasing
        }
    }

    var canRollbackLocal: Bool {
        guard let archivedSnapshot else { return false }
        let originalExists = FileManager.default.fileExists(atPath: archivedSnapshot.archivedFile.filePath)
        let imageHighLayerCanRollback = archivedSnapshot.archivedFile.objectType == .imageHighLayer && !originalExists
        let videoRawLayerCanRollback = archivedSnapshot.archivedFile.objectType == .videoRawLayer && !originalExists
        let ordinaryCanRollback = archivedSnapshot.archivedFile.objectType == .ordinaryFile
        return (ordinaryCanRollback || imageHighLayerCanRollback || videoRawLayerCanRollback) &&
            (archivedSnapshot.binding.localState == .quarantined || archivedSnapshot.binding.localState == .tombstoned) &&
            archivedSnapshot.binding.quarantinePath != nil &&
            !isReleasing
    }

    var canFinalizeLocalRelease: Bool {
        guard let archivedSnapshot else { return false }
        return archivedSnapshot.archivedFile.objectType == .ordinaryFile &&
            (archivedSnapshot.binding.localState == .quarantined || archivedSnapshot.binding.localState == .tombstoned) &&
            archivedSnapshot.binding.quarantinePath != nil &&
            !isReleasing
    }

    var body: some View {
        Group {
            if let file {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(file.filename)
                            .font(.title2.bold())
                            .textSelection(.enabled)

                        detailSection("对象") {
                            row("类型", file.objectType.displayName)
                            row("上传状态", uploadStatus?.title ?? "未上传")
                            row("候选说明", file.candidateReason ?? family?.reason ?? "-")
                            row("会话/来源", file.conversationName ?? "未解析")
                            row("月份", file.month ?? "-")
                        }

                        detailSection("文件") {
                            row("原始路径", file.path)
                            row("大小", humanBytes(file.sizeBytes))
                            DisclosureGroup("查看文件技术信息") {
                                row("Allocated", humanBytes(file.allocatedBytes))
                                row("SHA-256", file.sha256 ?? "未计算")
                                row("inode / nlink", "\(file.inode) / \(file.nlink)")
                                row("mtime", file.mtime.formatted(date: .numeric, time: .standard))
                                row("重复组", file.duplicateGroupID ?? "-")
                                row("账号 hash", file.accountHash)
                                row("会话解析", file.conversationResolution)
                            }
                        }

                        if let cloudSnapshot {
                            detailSection("云端归档") {
                                row("上传状态", uploadStatus?.title ?? "未上传")
                                row("上传时间", cloudSnapshot.object.uploadedAt.formatted(date: .numeric, time: .standard))
                                row("校验时间", cloudSnapshot.object.verifiedAt?.formatted(date: .numeric, time: .standard) ?? "-")
                                DisclosureGroup("查看云端技术信息") {
                                    row("Cloud Object ID", cloudSnapshot.object.cloudObjectID)
                                    row("Provider", cloudSnapshot.object.storageProvider)
                                    row("Bucket", cloudSnapshot.object.bucketOrContainer)
                                    row("Object Key", cloudSnapshot.object.objectKey)
                                    row("校验状态", cloudSnapshot.object.verifyStatus.rawValue)
                                    row("Binding", cloudSnapshot.binding.bindingID)
                                    row("本地状态", cloudSnapshot.binding.localState.rawValue)
                                }
                            }
                        }

                        if let family {
                            detailSection("Family") {
                                row("prefix", family.prefix)
                                row("候选", family.isCandidate ? "是" : "否")
                                row("高清/Raw 层", family.highOrRawPath)
                                row("普通查看/播放层", family.displayOrPlaybackPath ?? "-")
                                row("气泡/缩略层", family.bubbleOrThumbPath ?? "-")
                                row("成员", family.memberPaths.joined(separator: "\n"))
                            }
                        }

                        if archivedSnapshot != nil {
                            detailSection("恢复") {
                                Text(restoreHint(for: file.objectType))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("打开恢复中心", action: onOpenRestoreCenter)
                                    .disabled(isRestoring || isReleasing)
                            }
                        }

                        if archivedSnapshot != nil {
                            detailSection("本地释放") {
                                releaseCopy(for: file.objectType)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                switch file.objectType {
                                case .ordinaryFile:
                                    HStack {
                                        Button("释放本地原件") {
                                            onQuarantineLocal(createTombstone)
                                        }
                                            .disabled(!canQuarantineLocal)
                                        Button("从隔离区回滚", action: onRollbackLocal)
                                            .disabled(!canRollbackLocal)
                                    }
                                    Toggle("在微信原路径生成 tombstone 占位提示", isOn: $createTombstone)
                                        .disabled(!canQuarantineLocal)
                                    Button("确认释放空间", action: onFinalizeLocalRelease)
                                        .disabled(!canFinalizeLocalRelease)
                                    Text("默认会把原件移动到工具 quarantine；支持同类型 tombstone 的文件会在微信原路径写入 WeVault 占位文件。微信中直接转发或导出该附件时，可能得到占位提示，不是原件。确认释放只删除隔离副本，不删除云端对象或 manifest。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                case .imageHighLayer:
                                    HStack {
                                        Button("受控释放高清层") {
                                            onQuarantineLocal(false)
                                        }
                                            .disabled(!canQuarantineLocal)
                                        Button("从隔离区回滚", action: onRollbackLocal)
                                            .disabled(!canRollbackLocal)
                                    }
                                    Text("阶段 6 只移动 _h.dat / _h_M.dat 高清层到工具 quarantine；原高清路径保持为空，不生成 tombstone。普通查看层和气泡/缩略层必须继续留在本地。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                case .videoRawLayer:
                                    HStack {
                                        Button("受控释放 Raw 层") {
                                            onQuarantineLocal(false)
                                        }
                                            .disabled(!canQuarantineLocal)
                                        Button("从隔离区回滚", action: onRollbackLocal)
                                            .disabled(!canRollbackLocal)
                                    }
                                    Text("阶段 7 只移动 _raw.mp4 到工具 quarantine；Raw 原路径保持为空，不生成 tombstone。普通播放 .mp4 和封面/缩略图必须继续留在本地；保存/导出会降级为普通播放版，高质量导出前请先恢复 Raw 层。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("请选择一项", systemImage: "doc.text.magnifyingglass", description: Text("选择文件后可查看是否已上传及恢复选项。"))
            }
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
    }

    private func restoreHint(for objectType: ArchiveObjectType) -> String {
        switch objectType {
        case .ordinaryFile:
            return "默认恢复到工具下载目录，并以 SHA-256 一致作为成功标准。"
        case .imageHighLayer:
            return "高清版本已归档；如需保存高清/原图，请先恢复高清版本。"
        case .videoRawLayer:
            return "视频可正常播放；高质量导出版本已归档，如需保存/导出高清版本，请先恢复 Raw 层。"
        }
    }

    private func releaseCopy(for objectType: ArchiveObjectType) -> Text {
        switch objectType {
        case .ordinaryFile:
            return Text("阶段 5 仅支持已校验普通文件的受控本地释放；支持同类型 tombstone 的文件默认在微信原路径生成强标识占位文件，占位不是原件。")
        case .imageHighLayer:
            return Text("阶段 6 支持图片高清层受控释放：普通查看版本保留在本地，高清/原图需要时从云端恢复；不会生成 tombstone，也不会移动 .dat / _M.dat / _b.dat / _t.dat。")
        case .videoRawLayer:
            return Text("阶段 7 支持视频 Raw 层受控释放：普通播放版本、封面或缩略图保留在本地；保存/导出高质量版本前需要从云端恢复 _raw.mp4。")
        }
    }
}
