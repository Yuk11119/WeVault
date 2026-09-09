import WeVaultCore

/// One clear next step; partial operations remain available in More.
enum ArchivePrimaryAction {
    case chooseFolder, login, reviewRules, enableAutomation, configureStorage, organize, upload

    static func resolve(settings: ProductSettings, hasRoot: Bool, accountReady: Bool, storageReady: Bool) -> Self {
        guard hasRoot else { return .chooseFolder }
        if settings.cloudMode == .selfManaged { return storageReady ? .upload : .configureStorage }
        guard accountReady else { return .login }
        guard settings.onboardingCompleted, settings.riskAcknowledgementVersion == 1 else { return .reviewRules }
        guard settings.automaticTasksEnabled else { return .enableAutomation }
        return .organize
    }

    var title: String {
        switch self {
        case .chooseFolder: "选择文件夹"
        case .login: "登录云端"
        case .reviewRules: "完成整理设置"
        case .enableAutomation: "开启自动整理"
        case .configureStorage: "连接云存储"
        case .organize: "立即整理"
        case .upload: "仅上传"
        }
    }

    var hint: String {
        switch self {
        case .organize: "扫描、上传，并按保留期限释放本地空间"
        case .upload: "上传到自备云存储，保留本地原件"
        case .enableAutomation: "前往设置开启；仅扫描或仅上传可使用更多操作"
        default: "前往设置完成这一步"
        }
    }
}
