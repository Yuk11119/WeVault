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
    @ObservedObject var managedAccount: ManagedAccount
    @ObservedObject var selfManagedCloud: SelfManagedCloud
    let onSave: (ProductSettings) -> Void

    init(settings: ProductSettings, managedAccount: ManagedAccount, selfManagedCloud: SelfManagedCloud, onSave: @escaping (ProductSettings) -> Void) {
        _draft = State(initialValue: settings)
        self.managedAccount = managedAccount
        self.selfManagedCloud = selfManagedCloud
        self.onSave = onSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WeVault 设置").font(.title2.bold())
                SetupWizard(initial: draft) { updated in
                    onSave(updated)
                    dismiss()
                }
                ManagedLoginSection(account: managedAccount)
                SelfManagedCloudSection(cloud: selfManagedCloud)
            }
            .padding(.vertical)
        }
        .frame(minWidth: 650, minHeight: 680)
    }
}

private struct SelfManagedCloudSection: View {
    @ObservedObject var cloud: SelfManagedCloud
    @State private var config = SelfManagedTemporaryConfig()
    @State private var error: String?
    var body: some View {
        GroupBox("自配 OSS / COS 高级设置") {
            Text("仅接受短期 STS 凭证；不会保存长期 AccessKey 或 Secret。凭证仅存入本机 Keychain。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("提供商", selection: $config.provider) { Text("阿里云 OSS").tag("Aliyun OSS (STS)"); Text("腾讯云 COS").tag("Tencent COS (STS)") }
            TextField("Endpoint", text: $config.endpoint); TextField("Bucket", text: $config.bucket); TextField("Region", text: $config.region)
            TextField("临时 AccessKey ID", text: $config.accessKeyID); SecureField("临时 AccessKey Secret", text: $config.secretAccessKey); SecureField("Security Token", text: $config.securityToken); TextField("过期时间（ISO-8601）", text: $config.expiration)
            HStack { Button("保存短期凭证") { do { try cloud.save(config); error = nil } catch { self.error = error.localizedDescription } }; if let error { Text(error).foregroundStyle(.red) } }
        }.padding(.horizontal)
    }
}

private struct ManagedLoginSection: View {
    private enum Field: Hashable { case email, password }

    @ObservedObject var account: ManagedAccount
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        GroupBox("WeVault 云端账户") {
            if account.isReady {
                HStack { Text(account.status); Spacer(); Button("退出登录") { Task { await account.logout() } } }
            } else {
                TextField("邮箱", text: $email)
                    .textContentType(.emailAddress)
                    .focused($focusedField, equals: .email)
                SecureField("密码", text: $password)
                    .focused($focusedField, equals: .password)
                HStack { Button("登录并注册本机") { Task { do { try await account.login(email: email, password: password) } catch { self.error = error.localizedDescription } } }; if let error { Text(error).foregroundStyle(.red) } }
            }
        }
        .padding(.horizontal)
        .onAppear {
            if !account.isReady { focusedField = .email }
        }
    }
}
