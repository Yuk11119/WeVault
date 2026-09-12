import Foundation
import Security
import WeVaultCore

enum ManagedAccountLoginFailure: LocalizedError {
    case disabledForIsolation

    var errorDescription: String? {
        "隔离验收模式不连接真实云端。本次设置验收无需登录，请保持自动化关闭。"
    }
}

private struct ManagedAccountRecord: Codable {
    var session: WeVaultSession
    var accessExpiresAt: Date
    var clientDeviceID: String
    var deviceID: String?
    var email: String
}

/// Stores OAuth-like session material in Keychain; neither UserDefaults nor
/// the manifest ever contains a refresh token or cloud credential.
@MainActor
final class ManagedAccount: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var isReady = false
    @Published private(set) var status = "未登录"

    private let service = "online.wevault.api"
    private let account = "managed-session-v1"
    private let api: WeVaultAPIClient
    private let memoryOnly: Bool
    private let permitsLogin: Bool
    private var record: ManagedAccountRecord?
    private var refreshTask: Task<WeVaultSession, Error>?
    private var accountGeneration = 0

    var loginUnavailableMessage: String? {
        permitsLogin ? nil : ManagedAccountLoginFailure.disabledForIsolation.errorDescription
    }

    init(api: WeVaultAPIClient? = nil, memoryOnly: Bool = false, loginEnabled: Bool = true) {
        self.api = api ?? WeVaultAPIClient(baseURL: URL(string: "https://api.wevault.online")!)
        self.memoryOnly = memoryOnly || DevelopmentIsolation.root != nil
        self.permitsLogin = loginEnabled && (DevelopmentIsolation.root == nil || DevelopmentIsolation.permitsInteractiveAuthentication || api != nil)
        if !self.memoryOnly { load() }
    }

    func login(email: String, password: String, displayName: String = Host.current().localizedName ?? "Mac") async throws {
        guard permitsLogin else { throw ManagedAccountLoginFailure.disabledForIsolation }
        accountGeneration += 1
        let generation = accountGeneration
        refreshTask?.cancel(); refreshTask = nil
        let session = try await api.login(email: email, password: password)
        let clientDeviceID = record?.clientDeviceID ?? UUID().uuidString
        let device = try await api.registerDevice(accessToken: session.accessToken, clientDeviceId: clientDeviceID, displayName: displayName)
        guard generation == accountGeneration else { throw CancellationError() }
        try save(ManagedAccountRecord(session: session, accessExpiresAt: Date().addingTimeInterval(TimeInterval(session.expiresIn)), clientDeviceID: clientDeviceID, deviceID: device.deviceId, email: email))
        status = "已登录"
    }

    func register(email: String, password: String, invitationCode: String) async throws {
        guard permitsLogin else { throw ManagedAccountLoginFailure.disabledForIsolation }
        try await api.register(email: email, password: password, invitationCode: invitationCode)
    }

    func verifyEmail(email: String, code: String) async throws {
        guard permitsLogin else { throw ManagedAccountLoginFailure.disabledForIsolation }
        try await api.verifyEmail(email: email, code: code)
    }

    func resendVerification(email: String) async throws {
        guard permitsLogin else { throw ManagedAccountLoginFailure.disabledForIsolation }
        try await api.resendVerification(email: email)
    }

    func logout() async {
        let token = record?.session.accessToken
        remove(); status = "已退出登录"
        if let token { try? await api.logout(accessToken: token) }
    }

    func accessToken() async throws -> String {
        guard var current = record, let deviceID = current.deviceID else { throw WeVaultError.cloud("请先登录 WeVault 云端") }
        if current.accessExpiresAt <= Date().addingTimeInterval(60) {
            let generation = accountGeneration
            let task: Task<WeVaultSession, Error>
            if let existing = refreshTask { task = existing }
            else {
                let token = current.session.refreshToken
                task = Task { try await api.refresh(refreshToken: token) }
                refreshTask = task
            }
            defer { if generation == accountGeneration { refreshTask = nil } }
            let refreshed = try await task.value
            guard generation == accountGeneration, record?.deviceID == deviceID else { throw CancellationError() }
            current.session = refreshed
            current.accessExpiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn))
            try save(current)
        }
        guard deviceID == current.deviceID else { throw WeVaultError.cloud("设备注册状态无效") }
        return current.session.accessToken
    }

    func withAuthorizedDevice() async throws -> (api: WeVaultAPIClient, accessToken: String, deviceID: String) {
        guard let deviceID = record?.deviceID else { throw WeVaultError.cloud("请先登录 WeVault 云端") }
        return (api, try await accessToken(), deviceID)
    }

    private func load() {
        guard let data = readKeychain(), let loaded = try? JSONDecoder().decode(ManagedAccountRecord.self, from: data) else { return }
        record = loaded; email = loaded.email; isReady = loaded.deviceID != nil; status = isReady ? "已登录：\(loaded.email)" : "设备注册未完成"
    }

    private func save(_ value: ManagedAccountRecord) throws {
        let data = try JSONEncoder().encode(value)
        if !memoryOnly { try writeKeychain(data) }; record = value; email = value.email; isReady = value.deviceID != nil
    }

    private func remove() {
        accountGeneration += 1
        refreshTask?.cancel(); refreshTask = nil
        if !memoryOnly { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary) }
        record = nil; email = nil; isReady = false
    }

    private func readKeychain() -> Data? {
        var item: CFTypeRef?; let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true] as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }

    private func writeKeychain(_ data: Data) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        let attributes = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        let result = SecItemUpdate(query, attributes)
        if result == errSecItemNotFound { guard SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil) == errSecSuccess else { throw WeVaultError.cloud("无法写入 Keychain 会话") } }
        else if result != errSecSuccess { throw WeVaultError.cloud("无法更新 Keychain 会话") }
    }
}
