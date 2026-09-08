import Foundation

public struct RestoreLink: Equatable, Sendable {
    public let bindingID: String

    public init(bindingID: String) throws {
        guard bindingID.range(of: "^binding-([a-f0-9]{32}|[a-f0-9]{64})$", options: .regularExpression) != nil else {
            throw WeVaultError.fileSystem("无效的归档恢复编号")
        }
        self.bindingID = bindingID
    }

    public init(url: URL) throws {
        // PowerPoint appends this fixed origin tag when opening custom schemes.
        // No user-controlled parameters, duplicate tags or encoded variants are accepted.
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "wevault", parts.host == "restore",
              parts.user == nil, parts.password == nil, parts.port == nil,
              (parts.percentEncodedQuery == nil || parts.percentEncodedQuery == "OR=PowerPoint"), parts.fragment == nil,
              parts.percentEncodedPath == parts.path, parts.path.hasPrefix("/") else {
            throw WeVaultError.fileSystem("无效的 WeVault 恢复链接")
        }
        try self.init(bindingID: String(parts.path.dropFirst()))
    }

    public var url: URL { URL(string: "wevault://restore/\(bindingID)")! }
}
