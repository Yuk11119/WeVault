import AppKit
import SwiftUI
import WeVaultCore

struct SetupWizard: View {
    @State private var risksAccepted = false
    @State private var draft: ProductSettings
    let onFinish: (ProductSettings) -> Void

    init(initial: ProductSettings = .default, onFinish: @escaping (ProductSettings) -> Void) {
        _draft = State(initialValue: initial)
        _risksAccepted = State(initialValue: initial.riskAcknowledgementVersion == 1)
        self.onFinish = onFinish
    }

    var managedAccount: ManagedAccount? = nil
    var selfManagedCloud: SelfManagedCloud? = nil
    @State private var showSupport = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !draft.onboardingCompleted {
                    Section { Text("选择微信文件夹，开始整理大文件。") }
                }
                Section("文件") {
                    LabeledContent("微信文件夹") {
                        HStack {
                            Text(draft.scanRootPath ?? "尚未选择").lineLimit(1).truncationMode(.middle)
                            Button("选择…", action: chooseDirectory)
                        }
                    }
                    NumberSettingRow(title: "大文件起点", value: $draft.largeFileThresholdMB, range: 1...500, unit: "MB")
                    HStack {
                        Toggle("普通文件", isOn: $draft.archiveOrdinaryFiles)
                        Toggle("高清图片", isOn: $draft.archiveImageHighLayers)
                        Toggle("原画视频", isOn: $draft.archiveVideoRawLayers)
                    }.toggleStyle(.checkbox)
                }
                Section("自动整理") {
                    Toggle("定时归档并释放本地空间", isOn: $draft.automaticTasksEnabled)
                    if draft.automaticTasksEnabled {
                        NumberSettingRow(title: "运行间隔", value: $draft.runIntervalHours, range: 1...720, unit: "小时")
                        Text("归档 \(draft.coolingPeriodDays) 天后移入暂存区，再保留 \(draft.quarantineRetentionDays) 天后释放空间。")
                            .font(.caption).foregroundStyle(.secondary)
                        if draft.cloudMode == .selfManaged {
                            Text("自动整理需要使用 WeVault 云端。").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section("账户") {
                    Picker("存储位置", selection: $draft.cloudMode) {
                        Text("WeVault 云端").tag(ProductSettings.CloudMode.weVault)
                        Text("自备云存储").tag(ProductSettings.CloudMode.selfManaged)
                    }
                    if draft.cloudMode == .weVault, let managedAccount {
                        ManagedLoginSection(account: managedAccount)
                    } else if draft.cloudMode == .selfManaged, let selfManagedCloud {
                        DisclosureGroup("配置 OSS / COS") { SelfManagedCloudSection(cloud: selfManagedCloud) }
                    } else if draft.cloudMode == .weVault {
                        Text("完成后可在设置中登录。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("高级选项") {
                        NumberSettingRow(title: "原件保留", value: $draft.coolingPeriodDays, range: 0...365, unit: "天")
                        NumberSettingRow(title: "暂存保留", value: $draft.quarantineRetentionDays, range: 1...365, unit: "天")
                        Text("上传 → 保留原件 → 暂存 → 释放空间")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("在原位置保留恢复提示", isOn: $draft.createTombstones)
                        TextField("仅归档这些扩展名", text: Binding(
                            get: { draft.allowedExtensions.joined(separator: ", ") },
                            set: { draft.allowedExtensions = $0.split(separator: ",").map(String.init) }
                        ))
                        Text("逗号分隔，留空表示全部类型。").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("归档与恢复说明") {
                        Text("释放后，转发文件或保存高清图片、原画视频前需先恢复原件；关闭恢复提示会使原路径留空。")
                        Text("暂存期间可撤回，但不会立即腾出空间。到期释放后，恢复需要联网。请保留本机索引与钥匙串。")
                        Text("上传内容未在客户端加密，云存储和下载可能产生费用。应用关闭后不运行自动整理；热点或低电量时可手动暂停。")
                    }.font(.callout)
                    if draft.riskAcknowledgementVersion != 1 && draft.automaticTasksEnabled {
                        Text("自动整理会在暂存期结束后删除本地原件，之后需从云端恢复。").font(.callout)
                        Toggle("我已了解归档与恢复的影响", isOn: $risksAccepted)
                    }
                }
            }.formStyle(.grouped)
            HStack {
                if draft.onboardingCompleted { Button("帮助与反馈") { showSupport = true } }
                Spacer()
                Button(draft.onboardingCompleted ? "保存" : "开始使用") {
                    if risksAccepted { draft.riskAcknowledgementVersion = 1 }
                    draft.normalize()
                    onFinish(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.scanRootPath == nil || (draft.automaticTasksEnabled && !risksAccepted))
            }.padding()
        }
        .frame(minWidth: 580, minHeight: 580)
        .sheet(isPresented: $showSupport) { BetaSupportView() }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if let isolationRoot = DevelopmentIsolation.root {
            panel.directoryURL = isolationRoot.deletingLastPathComponent().appendingPathComponent("synthetic-input", isDirectory: true)
        } else if let defaultURL = WeChatDirectory.defaultXWeChatFilesURL() {
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
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.title2.bold())
                Spacer()
                Button("取消") { dismiss() }
            }.padding()
            SetupWizard(initial: draft) { updated in
                onSave(updated)
                dismiss()
            }
            .withAccounts(managedAccount, selfManagedCloud)
        }
        .frame(width: 650, height: 720)
    }
}

extension SetupWizard {
    func withAccounts(_ account: ManagedAccount, _ cloud: SelfManagedCloud) -> SetupWizard {
        var view = self
        view.managedAccount = account
        view.selfManagedCloud = cloud
        return view
    }
}

struct NumberSettingRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: $text)
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 72)
                    .multilineTextAlignment(.trailing).focused($focused)
                    .onChange(of: text) { _, newValue in
                        if let number = Int(newValue), range.contains(number) { value = number }
                    }
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, active in if !active { commit() } }
                Text(unit).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                Stepper(title, value: $value, in: range).labelsHidden()
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, number in if Int(text) != number { text = String(number) } }
        .help("\(range.lowerBound)–\(range.upperBound) \(unit)")
    }

    private func commit() {
        if let number = Int(text) { value = min(max(number, range.lowerBound), range.upperBound) }
        text = String(value)
    }
}

private struct SelfManagedCloudSection: View {
    @ObservedObject var cloud: SelfManagedCloud
    @State private var config = SelfManagedTemporaryConfig()
    @State private var error: String?
    var body: some View {
        GroupBox("自配 OSS / COS 高级设置") {
            Text(DevelopmentIsolation.root == nil ? "仅接受短期 STS 凭证；不会保存长期 AccessKey 或 Secret。凭证仅存入本机 Keychain。" : "隔离验收：短期 STS 配置仅保留在内存。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("提供商", selection: $config.provider) { Text("阿里云 OSS").tag("Aliyun OSS (STS)"); Text("腾讯云 COS").tag("Tencent COS (STS)") }
            TextField("Endpoint", text: $config.endpoint); TextField("Bucket", text: $config.bucket); TextField("Region", text: $config.region)
            TextField("临时 AccessKey ID", text: $config.accessKeyID); SecureField("临时 AccessKey Secret", text: $config.secretAccessKey); SecureField("Security Token", text: $config.securityToken); TextField("过期时间（ISO-8601）", text: $config.expiration)
            HStack { Button("保存短期凭证") { do { try cloud.save(config); error = nil } catch { self.error = UserFacingFailure.describe(error).description } }; if let error { Text(error).foregroundStyle(.red) } }
        }.padding(.horizontal)
    }
}

private struct ManagedLoginSection: View {
    private enum Field: Hashable { case email, password, invitation, code }
    private enum Mode: String, CaseIterable { case login = "登录", register = "注册" }

    @ObservedObject var account: ManagedAccount
    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var invitationCode = ""
    @State private var verificationCode = ""
    @State private var awaitingVerification = false
    @State private var message: String?
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = account.loginUnavailableMessage {
                Text(notice)
                    .fixedSize(horizontal: false, vertical: true)
            } else if account.isReady {
                HStack { Text(account.status); Spacer(); Button("退出登录") { Task { await account.logout() } } }
            } else {
                Picker("云端账号", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("邮箱", text: $email)
                    .textContentType(.emailAddress)
                    .focused($focusedField, equals: .email)
                SecureField("密码", text: $password)
                    .focused($focusedField, equals: .password)
                if mode == .register {
                    SecureField("邀请码", text: $invitationCode)
                        .focused($focusedField, equals: .invitation)
                    if awaitingVerification {
                        TextField("邮箱验证码", text: $verificationCode)
                            .focused($focusedField, equals: .code)
                        Text("验证码已发送到邮箱。完成验证后，可以直接用邮箱和密码登录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if mode == .login {
                        Button("登录") { Task { await login() } }
                            .disabled(busy || email.isEmpty || password.isEmpty)
                    } else {
                        Button(awaitingVerification ? "完成验证" : "创建账号") { Task { awaitingVerification ? await verify() : await register() } }
                            .disabled(busy || email.isEmpty || password.isEmpty || (awaitingVerification ? verificationCode.isEmpty : invitationCode.isEmpty))
                        if awaitingVerification {
                            Button("重发验证码") { Task { await resendVerification() } }
                                .disabled(busy || email.isEmpty)
                        }
                    }
                    if busy { ProgressView().controlSize(.small) }
                    if let error { Text(error).foregroundStyle(.red) }
                    else if let message { Text(message).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.horizontal)

    }

    private func login() async {
        await perform {
            try await account.login(email: email, password: password)
            password = ""; message = "已登录"
        }
    }

    private func register() async {
        await perform {
            try await account.register(email: email, password: password, invitationCode: invitationCode)
            awaitingVerification = true
            verificationCode = ""
            invitationCode = ""
            message = "验证码已发送"
        }
    }

    private func verify() async {
        await perform {
            try await account.verifyEmail(email: email, code: verificationCode)
            verificationCode = ""
            awaitingVerification = false
            mode = .login
            message = "邮箱已验证，请登录"
        }
    }

    private func resendVerification() async {
        await perform {
            try await account.resendVerification(email: email)
            message = "验证码已重新发送"
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do { try await action() }
        catch let failure as ManagedAccountLoginFailure { error = failure.localizedDescription }
        catch let caught { error = UserFacingFailure.describe(caught).description }
    }
}
