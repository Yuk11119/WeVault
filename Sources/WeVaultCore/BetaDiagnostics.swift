import Foundation

/// User-facing messages never echo server bodies, credentials or private paths.
public struct UserFacingFailure: Equatable, Sendable {
    public let code: String
    public let message: String
    public var description: String { "\(message)（\(code)）" }

    public static func describe(_ error: Error) -> Self {
        if error is CancellationError { return .init(code: "CANCELLED", message: "任务已停止。已完成的归档仍保留，可以重新检查并继续。") }
        if let api = error as? WeVaultAPIFailure {
            switch api.statusCode {
            case 401: return .init(code: "AUTH_EXPIRED", message: "登录或临时授权已失效。请重新登录后重试；当前失败对象不会因此释放。")
            case 403: return .init(code: "ACCESS_DENIED", message: "当前账号或设备没有访问权限。请检查云端账号与授权范围。")
            case 404: return .init(code: "ARCHIVE_UNAVAILABLE", message: "云端归档或授权不可用。请保留本地和隔离副本，稍后重试或联系支持。")
            case 429: return .init(code: "RATE_LIMITED", message: "云端请求过于频繁。请稍后重试。")
            default: return .init(code: "CLOUD_REQUEST_FAILED", message: "云端请求未完成。请检查连接后重试；如果持续失败，请导出诊断日志。")
            }
        }
        if let error = error as? WeVaultError {
            switch error {
            case .manifest(let failure):
                switch failure {
                case .keychainUnavailable: return .init(code: "KEYCHAIN_LOCKED", message: "无法访问钥匙串。请解锁本机钥匙串并允许 WeVault 访问，然后重试。")
                case .missingNeedsCloudIndexFallback: return .init(code: "MANIFEST_MISSING", message: "本地归档索引已丢失。请保留现有数据并联系支持；云端对象索引不能重建微信原路径。")
                default: return .init(code: "MANIFEST_UNREADABLE", message: "归档索引损坏或密钥不匹配。请保留索引与隔离副本，不要重置钥匙串；可导出诊断信息联系支持。")
                }
            case .invalidScanRoot: return .init(code: "SCAN_ROOT_UNAVAILABLE", message: "微信目录不存在或无法读取。请重新连接磁盘，并在设置中选择可访问的微信目录。")
            case .sqlite: return .init(code: "INDEX_WRITE_FAILED", message: "无法读写归档索引。请检查磁盘空间和目录权限，保留现有文件后重试。")
            case .fileSystem: return .init(code: "FILE_CONFLICT", message: "文件已变化、保留层不完整或无法安全读写。请检查原件与隔离副本；恢复时可改选下载目录，避免覆盖冲突文件。")
            case .cloud: return .init(code: "CLOUD_VERIFY_FAILED", message: "云端传输或完整性校验未通过。请检查网络和短期凭证后重试，保留本地与隔离副本。")
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return .init(code: "NETWORK_UNAVAILABLE", message: "网络连接中断或请求超时。请检查网络后重试；已完成的归档会继续复用。")
        }
        return .init(code: "OPERATION_FAILED", message: "操作未完成。请检查磁盘空间和权限后重试；如仍失败，请导出诊断日志联系支持。")
    }
}

public struct DiagnosticEntry: Codable, Sendable {
    public let id: Int64
    public let source: String
    public let event: String
    public let createdAt: Date
    public let detail: String?
    public var runID: String? = nil
    public var stage: String? = nil
    public var status: String? = nil
    public var completedUnits: Int? = nil
    public var totalUnits: Int? = nil
}

/// Export uses an allowlist, not regex removal from potentially secret diagnostic prose.
public enum DiagnosticPrivacy {
    public static func safeDetail(_ value: String?) -> String? {
        guard let value, value.range(of: "^HTTP [0-9]{3}( [A-Za-z0-9_-]{1,80})?( request=[A-Za-z0-9_-]{1,120})?$", options: .regularExpression) != nil else { return nil }
        return value
    }
    public static func safeEvent(_ value: String) -> String {
        value.range(of: "^[A-Z][A-Z0-9_]{0,79}$", options: .regularExpression) == nil ? "UNKNOWN_EVENT" : value
    }
}

public enum DiagnosticExporter {
    /// A JSONL file is streamed in bounded pages. The database and private diagnostics
    /// are never copied into the export; a failed export removes its staging file.
    public static func export(to destination: URL, store: ManifestStore?, version: String, build: String) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".wevault-diagnostics-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw WeVaultError.fileSystem("无法创建诊断文件") }
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        let metadata = ["format": "wevault-diagnostics-v1", "version": version, "build": build,
                        "os": ProcessInfo.processInfo.operatingSystemVersionString,
                        "privacy": "No paths, filenames, account IDs, object keys, tokens or file contents",
                        "index": store == nil ? "unavailable" : "available"]
        try handle.write(contentsOf: encoder.encode(metadata)); try handle.write(contentsOf: Data([10]))
        if let store {
            for source in ["operations", "automation_task_logs", "automation_task_runs"] {
                let upperBound = try store.diagnosticHighWatermark(source: source)
                var cursor: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let entries = try store.diagnosticPage(source: source, after: cursor, through: upperBound)
                    guard let last = entries.last else { break }
                    for entry in entries { try handle.write(contentsOf: encoder.encode(entry)); try handle.write(contentsOf: Data([10])) }
                    cursor = last.id
                }
            }
        }
        try handle.synchronize(); try handle.close()
        // The user chooses a new export name; never silently replace an existing file.
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}
