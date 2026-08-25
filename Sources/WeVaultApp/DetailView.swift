import SwiftUI
import WeVaultCore

struct DetailView: View {
    let file: FileRecord?
    let families: [FamilyRecord]
    let cloudSnapshot: CloudArchiveSnapshot?
    let archivedSnapshot: ArchivedFileSnapshot?
    let isRestoring: Bool
    let onRestoreDefault: () -> Void
    let onRestoreToDirectory: () -> Void
    let onRestoreOriginalPath: () -> Void

    var family: FamilyRecord? {
        guard let file else { return nil }
        return families.first { $0.highOrRawPath == file.path }
    }

    var canRestore: Bool {
        guard let archivedSnapshot else { return false }
        return archivedSnapshot.object.verifyStatus == .verified &&
            (archivedSnapshot.binding.archiveState == .verified || archivedSnapshot.binding.archiveState == .restored) &&
            !isRestoring
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
                            row("类型", file.objectType.rawValue)
                            row("状态", file.status.rawValue)
                            row("候选说明", file.candidateReason ?? family?.reason ?? "-")
                            row("会话/来源", file.conversationName ?? "未解析")
                            row("会话解析", file.conversationResolution)
                            row("月份", file.month ?? "-")
                            row("账号 hash", file.accountHash)
                        }

                        detailSection("文件") {
                            row("原始路径", file.path)
                            row("大小", humanBytes(file.sizeBytes))
                            row("Allocated", humanBytes(file.allocatedBytes))
                            row("SHA-256", file.sha256 ?? "未计算")
                            row("inode / nlink", "\(file.inode) / \(file.nlink)")
                            row("mtime", file.mtime.formatted(date: .numeric, time: .standard))
                            row("重复组", file.duplicateGroupID ?? "-")
                        }

                        if let cloudSnapshot {
                            detailSection("云端") {
                                row("Cloud Object ID", cloudSnapshot.object.cloudObjectID)
                                row("Provider", cloudSnapshot.object.storageProvider)
                                row("Bucket", cloudSnapshot.object.bucketOrContainer)
                                row("Object Key", cloudSnapshot.object.objectKey)
                                row("上传时间", cloudSnapshot.object.uploadedAt.formatted(date: .numeric, time: .standard))
                                row("校验时间", cloudSnapshot.object.verifiedAt?.formatted(date: .numeric, time: .standard) ?? "-")
                                row("校验状态", cloudSnapshot.object.verifyStatus.rawValue)
                                row("引用数量", "\(cloudSnapshot.object.refCount)")
                                row("Binding", cloudSnapshot.binding.bindingID)
                                row("本地状态", cloudSnapshot.binding.localState.rawValue)
                                row("恢复时间", cloudSnapshot.binding.restoredAt?.formatted(date: .numeric, time: .standard) ?? "-")
                                row("最后恢复校验", cloudSnapshot.binding.lastRestoreCheckAt?.formatted(date: .numeric, time: .standard) ?? "-")
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
                                HStack {
                                    Button("恢复到下载目录", action: onRestoreDefault)
                                        .disabled(!canRestore)
                                    Button("选择目录恢复", action: onRestoreToDirectory)
                                        .disabled(!canRestore)
                                }
                                if file.objectType == .imageHighLayer || file.objectType == .videoRawLayer {
                                    Button("受控恢复到原微信路径", action: onRestoreOriginalPath)
                                        .disabled(!canRestore)
                                    Text("不会覆盖已有的不同文件；不会生成占位文件。")
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
                ContentUnavailableView("请选择一项", systemImage: "doc.text.magnifyingglass", description: Text("详情会显示原始路径、SHA、family 成员和归档候选原因。"))
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
}
