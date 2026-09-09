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
    let onClose: () -> Void
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
                        HStack(alignment: .top) {
                            Text(file.filename).font(.title2.bold()).textSelection(.enabled)
                            Spacer()
                            Button(action: onClose) { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .help("关闭详情").accessibilityLabel("关闭详情")
                        }

                        detailSection("文件信息") {
                            row("类型", file.objectType.displayName)
                            row("上传状态", uploadStatus?.title ?? "未上传")
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
                            DisclosureGroup("关联文件") {
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
                                Button("预览与恢复", action: onOpenRestoreCenter)
                                    .disabled(isRestoring || isReleasing)
                            }
                        }

                        if archivedSnapshot != nil {
                            DisclosureGroup("管理本地副本") {
                                releaseCopy(for: file.objectType)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                switch file.objectType {
                                case .ordinaryFile:
                                    HStack {
                                        Button("移入暂存区") {
                                            onQuarantineLocal(createTombstone)
                                        }
                                            .disabled(!canQuarantineLocal)
                                        Button("撤回到原位置", action: onRollbackLocal)
                                            .disabled(!canRollbackLocal)
                                    }
                                    Toggle("在原位置保留恢复提示", isOn: $createTombstone)
                                        .disabled(!canQuarantineLocal)
                                    Button("确认释放空间", action: onFinalizeLocalRelease)
                                        .disabled(!canFinalizeLocalRelease)
                                case .imageHighLayer:
                                    HStack {
                                        Button("暂存高清原件") {
                                            onQuarantineLocal(false)
                                        }
                                            .disabled(!canQuarantineLocal)
                                        Button("撤回到原位置", action: onRollbackLocal)
                                            .disabled(!canRollbackLocal)
                                    }
                                case .videoRawLayer:
                                    HStack {
                                        Button("暂存原画视频") {
                                            onQuarantineLocal(false)
                                        }
                                            .disabled(!canQuarantineLocal)
                                        Button("撤回到原位置", action: onRollbackLocal)
                                            .disabled(!canRollbackLocal)
                                    }
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
            return "查看内容，或恢复到指定位置。"
        case .imageHighLayer:
            return "高清版本已归档；如需保存高清/原图，请先恢复高清版本。"
        case .videoRawLayer:
            return "需要原画视频时，可从云端恢复。"
        }
    }

    private func releaseCopy(for objectType: ArchiveObjectType) -> Text {
        switch objectType {
        case .ordinaryFile: Text("暂存后可撤回；释放空间后需联网恢复。转发前请恢复原件。")
        case .imageHighLayer: Text("保留普通查看版本，保存高清图片前需恢复原件。")
        case .videoRawLayer: Text("保留普通播放版本，导出原画视频前需恢复原件。")
        }
    }
}
