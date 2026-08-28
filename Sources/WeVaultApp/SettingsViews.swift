import AppKit
import SwiftUI
import WeVaultCore

struct SetupWizard: View {
    @State private var draft: ProductSettings
    let onFinish: (ProductSettings) -> Void

    init(initial: ProductSettings = .default, onFinish: @escaping (ProductSettings) -> Void) {
        _draft = State(initialValue: initial)
        self.onFinish = onFinish
    }

    var body: some View {
        Form {
            Section("欢迎使用 WeVault") {
                Text("WeVault 会归档已验证的微信大对象；P1 只保存本地策略，不会自动释放文件，也不会保存云端密钥。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            policySections
            Section {
                Button("完成设置并打开状态中心") {
                    onFinish(draft)
                }
                .disabled(draft.scanRootPath == nil)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 620, minHeight: 620)
    }

    var policySections: some View {
        Group {
            scanRootSection
            scheduleSection
            archiveSection
            cloudSection
        }
    }

    var scanRootSection: some View {
        Section("微信目录与阈值") {
            LabeledContent("扫描目录") {
                HStack {
                    Text(draft.scanRootPath ?? "尚未选择")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("选择目录", action: chooseDirectory)
                }
            }
            Stepper("大文件阈值：\(draft.largeFileThresholdMB) MB", value: $draft.largeFileThresholdMB, in: 1...500)
        }
    }

    var scheduleSection: some View {
        Section("自动化策略") {
            Toggle("完成 P2 云端接入后启用自动任务", isOn: $draft.automaticTasksEnabled)
            Stepper("运行频率：每 \(draft.runIntervalHours) 小时", value: $draft.runIntervalHours, in: 1...720)
            Stepper("自动释放冷却期：\(draft.coolingPeriodDays) 天", value: $draft.coolingPeriodDays, in: 0...365)
            Stepper("quarantine 保留：\(draft.quarantineRetentionDays) 天", value: $draft.quarantineRetentionDays, in: 1...365)
            Toggle("后台运行优先", isOn: $draft.preferBackgroundExecution)
            Toggle("限制受限网络上传", isOn: $draft.limitUploadsOnMeteredNetwork)
        }
    }

    var archiveSection: some View {
        Section("归档范围") {
            Toggle("普通大文件", isOn: $draft.archiveOrdinaryFiles)
            Toggle("图片高清层", isOn: $draft.archiveImageHighLayers)
            Toggle("视频 Raw 层", isOn: $draft.archiveVideoRawLayers)
            Toggle("普通文件生成 tombstone", isOn: $draft.createTombstones)
            TextField("允许扩展名（逗号分隔；留空为不限制）", text: Binding(
                get: { draft.allowedExtensions.joined(separator: ", ") },
                set: { draft.allowedExtensions = $0.split(separator: ",").map(String.init) }
            ))
        }
    }

    var cloudSection: some View {
        Section("云端模式") {
            Picker("模式", selection: $draft.cloudMode) {
                Text("WeVault 云端（P2 登录后可用）").tag(ProductSettings.CloudMode.weVault)
                Text("自配 OSS/COS（P2 高级设置后可用）").tag(ProductSettings.CloudMode.selfManaged)
            }
            Text("此版本不输入或保存长期 AccessKey / Secret。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if let defaultURL = WeChatDirectory.defaultXWeChatFilesURL() {
            panel.directoryURL = defaultURL
        }
        if panel.runModal() == .OK {
            draft.scanRootPath = panel.url?.path
        }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProductSettings
    let onSave: (ProductSettings) -> Void

    init(settings: ProductSettings, onSave: @escaping (ProductSettings) -> Void) {
        _draft = State(initialValue: settings)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WeVault 设置").font(.title2.bold())
            SetupWizard(initial: draft) { updated in
                onSave(updated)
                dismiss()
            }
        }
        .frame(minWidth: 650, minHeight: 680)
    }
}
