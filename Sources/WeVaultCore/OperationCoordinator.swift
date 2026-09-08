import Foundation

/// Short synchronous leases also cover file commits which cannot suspend mid-rename.
public final class OperationCoordinator: @unchecked Sendable {
    public static let shared = OperationCoordinator()
    private let lock = NSLock()
    private var active: Set<String> = []
    public init() {}
    public static func bindingKey(_ id: String, store: ManifestStore) -> String { store.databaseURL.standardizedFileURL.path + "|binding:" + id }
    public static func pipelineKey(_ url: URL = ManifestStore.defaultDatabaseURL()) -> String { url.standardizedFileURL.path + "|scan-upload" }
    public func acquire(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !active.contains(key) else { throw WeVaultError.fileSystem("相关任务正在运行，请稍后重试") }
        active.insert(key)
    }
    public func release(_ key: String) { lock.lock(); defer { lock.unlock() }; active.remove(key) }
    public func isBusy(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return active.contains(key) }
}

public enum AutomationFailure {
    public static func isFatal(_ error: Error) -> Bool {
        if error is CancellationError || error is ManifestFailure || error is DecodingError { return true }
        if let api = error as? WeVaultAPIFailure, [401, 403].contains(api.statusCode) { return true }
        if let error = error as? WeVaultError {
            switch error { case .sqlite, .manifest: return true; default: break }
        }
        return false
    }
}
