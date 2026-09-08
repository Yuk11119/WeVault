import Foundation
import Security
import WeVaultCore

struct SelfManagedTemporaryConfig: Codable, Equatable {
    var provider: String = "Aliyun OSS (STS)"
    var endpoint = ""
    var bucket = ""
    var region = ""
    var accessKeyID = ""
    var secretAccessKey = ""
    var securityToken = ""
    var expiration = ""

    func storageConfig() throws -> S3CompatibleStorageConfig {
        guard let expiry = ISO8601DateFormatter().date(from: expiration), expiry > Date(), !endpoint.isEmpty, !bucket.isEmpty, !region.isEmpty, !accessKeyID.isEmpty, !secretAccessKey.isEmpty, !securityToken.isEmpty else { throw WeVaultError.cloud("自配云端需要未过期的临时 STS 凭证") }
        return S3CompatibleStorageConfig(provider: provider, endpoint: endpoint, bucket: bucket, region: region, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: securityToken)
    }
}

@MainActor
final class SelfManagedCloud: ObservableObject {
    @Published private(set) var configuration: SelfManagedTemporaryConfig?
    private let service = "online.wevault.api"; private let account = "self-managed-sts-v1"
    private let memoryOnly: Bool
    private let permitsSave: Bool
    init(memoryOnly: Bool = false) {
        self.memoryOnly = memoryOnly || DevelopmentIsolation.root != nil
        self.permitsSave = memoryOnly || DevelopmentIsolation.root == nil || DevelopmentIsolation.permitsInteractiveAuthentication
        if !self.memoryOnly, let data = read(), let config = try? JSONDecoder().decode(SelfManagedTemporaryConfig.self, from: data) { configuration = config }
    }
    func save(_ config: SelfManagedTemporaryConfig) throws {
        guard permitsSave else { throw WeVaultError.cloud("隔离测试模式不保存云端凭证") }
        _ = try config.storageConfig()
        if !memoryOnly {
            let data = try JSONEncoder().encode(config)
            let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
            let attrs = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
            let result = SecItemUpdate(query, attrs)
            if result == errSecItemNotFound {
                guard SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil) == errSecSuccess else { throw WeVaultError.cloud("无法写入自配云端 Keychain 凭证") }
            } else if result != errSecSuccess { throw WeVaultError.cloud("无法更新自配云端 Keychain 凭证") }
        }
        configuration = config
    }
    func storageConfig() throws -> S3CompatibleStorageConfig { guard let configuration else { throw WeVaultError.cloud("请在高级设置中配置自配云端临时凭证") }; return try configuration.storageConfig() }
    private func read() -> Data? { var item: CFTypeRef?; return SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true] as CFDictionary, &item) == errSecSuccess ? item as? Data : nil }
}
