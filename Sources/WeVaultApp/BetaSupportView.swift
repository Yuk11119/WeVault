import AppKit
import SwiftUI
import WeVaultCore
import UniformTypeIdentifiers

struct BetaSupportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BetaSupportModel()

    var body: some View {
        Form {
            Section("WeVault Beta · \(model.version) (\(model.build))") {
                Text("测试版主要面向 macOS 14+、微信 4.x。遇到异常时，请先暂停自动任务，保留原件与隔离副本。")
            }
            Section("诊断日志") {
                Text("导出操作时间、事件类型和安全错误码；不包含原路径、文件名、账号、凭证、原件或完整归档索引。导出后请自行检查，再决定是否发送。")
                Button("导出诊断日志…", action: exportDiagnostics).disabled(model.busy)
            }
            Section("反馈") {
                Button("通过邮件反馈", action: model.feedback)
                Text("仅打开邮件草稿，不会自动发送或附加日志。没有邮件应用时，可复制接收地址后自行发送。")
                if let address = model.feedbackAddress {
                    Text(address).textSelection(.enabled)
                    Button("复制反馈邮箱") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) }
                }
            }
            Section("软件更新") {
                Button("检查新版本") { Task { await model.checkUpdates() } }.disabled(model.busy)
                if let release = model.release {
                    Text("可用版本：\(release.version) (\(release.build))")
                    Text(release.releaseNotes).textSelection(.enabled)
                    Button("打开下载页面", action: model.openDownload)
                    Text("下载后等待当前任务完成，退出 WeVault，再替换应用。保留 Application Support 中的 WeVault 索引、钥匙串和隔离目录。")
                }
            }
            if model.busy { ProgressView() }
            if !model.message.isEmpty { Text(model.message).textSelection(.enabled) }
            Button("关闭") { dismiss() }.disabled(model.busy)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: 650)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WeVault-diagnostics-\(Int(Date().timeIntervalSince1970)).jsonl"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Exporter's exclusive move preserves an existing export even if a panel offered replacement.
        model.busy = true; model.message = "正在导出已脱敏的诊断信息…"
        Task {
            defer { model.busy = false }
            do {
                let version = model.version, build = model.build
                let worker = Task.detached(priority: .utility) {
                    try DiagnosticExporter.export(to: destination, store: try? ManifestStore(), version: version, build: build)
                }
                try await worker.value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                model.message = "日志已导出。请先检查内容，再手动添加到反馈邮件。"
            } catch { model.message = "导出未完成。请使用新的文件名，并检查目标目录权限与磁盘空间。" }
        }
    }
}
