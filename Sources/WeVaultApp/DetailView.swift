import SwiftUI
import WeVaultCore

struct DetailView: View {
    let file: FileRecord?
    let families: [FamilyRecord]

    var family: FamilyRecord? {
        guard let file else { return nil }
        return families.first { $0.highOrRawPath == file.path }
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
}
