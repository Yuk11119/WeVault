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
              (parts.percentEncodedPath == parts.path || parts.percentEncodedPath == parts.path.replacingOccurrences(of: "\u{2}", with: "%02")), parts.path.hasPrefix("/") else {
            throw WeVaultError.fileSystem("无效的 WeVault 恢复链接")
        }
        // Older CoreText PDF text extraction represented the prefix hyphen as
        // U+0002. Accept only this exact position; the entire ID is still validated.
        let path = parts.path.hasPrefix("/binding\u{2}")
            ? "/binding-" + parts.path.dropFirst("/binding\u{2}".count) : parts.path
        try self.init(bindingID: String(path.dropFirst()))
    }

    /// Browser bridge for readers that treat custom schemes as local files.
    /// The fragment never reaches the server or its access logs.
    public var browserURL: URL { URL(string: "https://api.wevault.online/restore#\(bindingID)")! }

    /// User-pasted text may contain PDF line breaks. URL event parsing stays strict.
    public init(lookupText: String) throws {
        let text = lookupText.components(separatedBy: .whitespacesAndNewlines).joined()
        if text.hasPrefix("binding\u{2}") { try self.init(bindingID: "binding-" + text.dropFirst("binding\u{2}".count)); return }
        if text.hasPrefix("binding-") { try self.init(bindingID: text); return }
        guard let url = URL(string: text) else { throw WeVaultError.fileSystem("无效的 WeVault 恢复链接") }
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           parts.scheme == "https", parts.host == "api.wevault.online",
           parts.user == nil, parts.password == nil, parts.port == nil,
           parts.percentEncodedPath == "/restore", parts.query == nil,
           let id = parts.fragment, parts.percentEncodedFragment == id {
            try self.init(bindingID: id)
        } else { try self.init(url: url) }
    }

    public var url: URL { URL(string: "wevault://restore/\(bindingID)")! }
}
