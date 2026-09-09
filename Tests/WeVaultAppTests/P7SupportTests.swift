import Foundation
import Testing
@testable import WeVaultApp
import WeVaultCore

@MainActor
struct P7SupportTests {
    private let info: [String: Any] = ["CFBundleShortVersionString": "0.7.0", "CFBundleVersion": "7",
        "WeVaultFeedbackEmail": "support@example.test", "WeVaultUpdateFeedURL": "https://updates.example.test/beta.json"]
    private let system = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)

    @Test("update results only offer compatible newer builds", arguments: [6, 7, 8])
    func versions(build: Int) async throws {
        let candidate = try release(build: build)
        var opens = 0
        let model = BetaSupportModel(info: info, system: system, checker: { _ in candidate }, openURL: { _ in opens += 1; return true })
        await model.checkUpdates()
        #expect(!model.busy)
        #expect((model.release != nil) == (build > 7))
        #expect(model.message.contains(build > 7 ? "已找到新版本" : "最新版本"))
        #expect(opens == 0)
    }

    @Test("incompatible releases never offer a download")
    func incompatible() async throws {
        let candidate = try release(system: "99.0")
        let model = BetaSupportModel(info: info, system: system, checker: { _ in candidate })
        await model.checkUpdates()
        #expect(model.release == nil && !model.busy)
        #expect(model.message.contains("macOS 99.0"))
    }

    @Test("offline retry clears a previously offered release and can recover")
    func retry() async throws {
        let candidate = try release()
        var calls = 0
        let model = BetaSupportModel(info: info, system: system, checker: { _ in
            calls += 1
            if calls == 2 { throw URLError(.notConnectedToInternet) }
            return candidate
        })
        await model.checkUpdates()
        #expect(model.release != nil)
        await model.checkUpdates()
        #expect(model.release == nil && !model.busy)
        #expect(model.message.contains("检查更新失败"))
        await model.checkUpdates()
        #expect(model.release != nil && !model.busy)
    }

    @Test("missing configuration does not contact a service or open another application")
    func missingConfiguration() async {
        var calls = 0
        let model = BetaSupportModel(info: [:], checker: { _ in calls += 1; throw URLError(.badURL) },
                                     openURL: { _ in calls += 1; return true })
        await model.checkUpdates()
        #expect(model.message.contains("尚未配置更新源"))
        model.feedback()
        #expect(model.message.contains("尚未配置反馈邮箱"))
        #expect(calls == 0 && model.feedbackAddress == nil)
    }

    @Test("feedback opens only a versioned draft and clears a previous launch failure")
    func feedbackDraft() throws {
        var requested: [URL] = []
        let model = BetaSupportModel(info: info, openURL: { url in requested.append(url); return requested.count > 1 })
        model.feedback()
        #expect(model.message.contains("未能打开邮件应用"))
        model.feedback()
        #expect(model.message.contains("已请求打开邮件草稿"))
        let url = try #require(requested.last)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto" && components.path == "support@example.test")
        let query = try #require(components.queryItems)
        #expect(Set(query.map(\.name)) == ["subject", "body"])
        #expect(query.first(where: { $0.name == "subject" })?.value?.contains("0.7.0 (7)") == true)
    }

    private func release(build: Int = 8, system: String = "14.0") throws -> BetaRelease {
        let data = try JSONSerialization.data(withJSONObject: ["version": "0.8.0", "build": build,
            "minimumSystemVersion": system, "downloadURL": "https://downloads.example.test/beta", "releaseNotes": "Fixture notes"])
        return try JSONDecoder().decode(BetaRelease.self, from: data)
    }

    @Test("download is explicit and browser failure can be retried")
    func downloadLaunch() async throws {
        let candidate = try release()
        var requested: [URL] = []
        let model = BetaSupportModel(info: info, system: system, checker: { _ in candidate },
                                     openURL: { requested.append($0); return requested.count > 1 })
        model.openDownload()
        #expect(requested.isEmpty)
        await model.checkUpdates()
        #expect(requested.isEmpty)
        model.openDownload()
        #expect(requested == [candidate.downloadURL])
        #expect(model.message.contains("未能打开下载页面"))
        model.openDownload()
        #expect(model.message.contains("已请求打开下载页面"))
    }
}
