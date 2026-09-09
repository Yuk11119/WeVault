import Foundation

public struct BetaRelease: Codable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let downloadURL: URL
    public let releaseNotes: String

    public func validate() throws {
        guard !version.isEmpty, version.count <= 40, build > 0,
              Self.systemComponents(minimumSystemVersion) != nil,
              Self.isWebURL(downloadURL), releaseNotes.count <= 12_000 else {
            throw WeVaultError.cloud("更新信息无效")
        }
    }

    public func supports(_ system: OperatingSystemVersion) -> Bool {
        guard let required = Self.systemComponents(minimumSystemVersion) else { return false }
        return ![system.majorVersion, system.minorVersion, system.patchVersion].lexicographicallyPrecedes(required)
    }

    public static func isWebURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func systemComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ (0...999).contains($0) }) else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

public enum BetaUpdateChecker {
    public static func check(feed: URL, session: URLSession? = nil) async throws -> BetaRelease {
        guard BetaRelease.isWebURL(feed) else { throw WeVaultError.cloud("更新地址必须使用 HTTPS") }
        let connection = session ?? URLSession(configuration: .ephemeral)
        defer { if session == nil { connection.invalidateAndCancel() } }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await connection.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, BetaRelease.isWebURL(final), final.host == feed.host,
              response.expectedContentLength <= 65_536 else { throw WeVaultError.cloud("无法读取更新信息") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw WeVaultError.cloud("更新信息过大") }
            data.append(byte)
        }
        let release = try JSONDecoder().decode(BetaRelease.self, from: data)
        try release.validate()
        return release
    }
}

public enum BetaFeedback {
    public static func mailURL(address: String, version: String, build: String) -> URL? {
        guard address.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"; components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: "WeVault Beta \(version) (\(build)) 反馈"),
            URLQueryItem(name: "body", value: "问题描述：\n\n复现步骤：\n\n预期结果与实际结果：\n\n如需诊断，请先在 WeVault 导出并检查日志，再手动添加附件。请勿发送原件、密钥或完整归档索引。")]
        return components.url
    }
}
