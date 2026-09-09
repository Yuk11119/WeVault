import AppKit
import Combine
import WeVaultCore

@MainActor
final class BetaSupportModel: ObservableObject {
    @Published var message = ""
    @Published var busy = false
    @Published private(set) var release: BetaRelease?
    let version: String
    let build: String
    let feedbackAddress: String?
    private let feed: URL?
    private let system: OperatingSystemVersion
    private let checker: (URL) async throws -> BetaRelease
    private let openURL: (URL) -> Bool

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
         checker: @escaping (URL) async throws -> BetaRelease = { try await BetaUpdateChecker.check(feed: $0) },
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        version = info["CFBundleShortVersionString"] as? String ?? "development"
        build = info["CFBundleVersion"] as? String ?? "0"
        let address = info["WeVaultFeedbackEmail"] as? String ?? ""
        feedbackAddress = BetaFeedback.mailURL(address: address, version: version, build: build) == nil ? nil : address
        feed = (info["WeVaultUpdateFeedURL"] as? String).flatMap(URL.init(string:))
        self.system = system
        self.checker = checker
        self.openURL = openURL
    }

    func feedback() {
        guard let address = feedbackAddress,
              let url = BetaFeedback.mailURL(address: address, version: version, build: build) else {
            message = "此工程准备版本尚未配置反馈邮箱。可以先导出日志；正式分发构建必须配置接收地址。"; return
        }
        message = openURL(url)
            ? "已请求打开邮件草稿。请自行检查内容并决定是否发送。"
            : "未能打开邮件应用。请复制上方接收地址，自行撰写反馈。"
    }

    func checkUpdates() async {
        guard !busy else { return }
        release = nil
        guard let feed, BetaRelease.isWebURL(feed) else {
            message = "此工程准备版本尚未配置更新源。正式分发构建必须配置 HTTPS 版本地址。"; return
        }
        busy = true; message = "正在检查更新…"
        defer { busy = false }
        do {
            let found = try await checker(feed)
            try found.validate()
            guard found.build > (Int(build) ?? 0) else { message = "当前已是最新版本。"; return }
            guard found.supports(system) else {
                message = "新版本需要 macOS \(found.minimumSystemVersion) 或更高版本。当前应用可以继续使用。"; return
            }
            release = found; message = "已找到新版本，请查看说明后手动下载。"
        } catch { message = "检查更新失败。请检查网络后重试；当前应用可以继续使用。" }
    }

    func openDownload() {
        guard let release else { return }
        message = openURL(release.downloadURL)
            ? "已请求打开下载页面。下载后请按说明手动替换应用。"
            : "未能打开下载页面。请检查默认浏览器后重试；当前应用可以继续使用。"
    }
}
