import CryptoKit
import Foundation
import Security

/// The manifest master key never leaves a `ManifestKeyProvider` as text. Production uses
/// Keychain; the in-memory implementation is only intended for isolated package tests.
public protocol ManifestKeyProvider: Sendable {
    func existingKey() throws -> Data?
    func createKey() throws -> Data
}

public enum ManifestFailure: Error, Equatable, Sendable {
    case keychainUnavailable
    case keyMissing
    case invalidKey
    case keyMismatch
    case malformedEncryptedField
    case authenticationFailed
    case sqliteCorrupt
    case missingNeedsCloudIndexFallback
}

public final class KeychainManifestKeyProvider: ManifestKeyProvider, @unchecked Sendable {
    public static let shared = KeychainManifestKeyProvider()
    private let service = "com.wevault.manifest.master-key"
    private let account = "default"

    public init() {}

    public func existingKey() throws -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ManifestFailure.keychainUnavailable }
        guard data.count == 32 else { throw ManifestFailure.invalidKey }
        return data
    }

    public func createKey() throws -> Data {
        if let existing = try existingKey() { return existing }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let attributes: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                            kSecAttrAccount: account, kSecValueData: data,
                                            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { return try existingKey().flatMap { $0 } ?? data }
        guard status == errSecSuccess else { throw ManifestFailure.keychainUnavailable }
        return data
    }
}

public final class InMemoryManifestKeyProvider: ManifestKeyProvider, @unchecked Sendable {
    private var key: Data?
    private let failure: ManifestFailure?
    public init(key: Data? = nil, failure: ManifestFailure? = nil) { self.key = key; self.failure = failure }
    public func existingKey() throws -> Data? { if let failure { throw failure }; return key }
    public func createKey() throws -> Data { if let failure { throw failure }; if let key { return key }; let created = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }); key = created; return created }
}

struct ManifestCipher {
    private let encryptionKey: SymmetricKey
    private let tokenKey: SymmetricKey

    init(masterKey: Data, databaseID: String) throws {
        guard masterKey.count == 32 else { throw ManifestFailure.invalidKey }
        let root = SymmetricKey(data: masterKey)
        let salt = Data(databaseID.utf8)
        encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt, info: Data("wevault-manifest-aes-gcm-v1".utf8), outputByteCount: 32)
        tokenKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt, info: Data("wevault-manifest-token-v1".utf8), outputByteCount: 32)
    }

    func token(_ value: String, domain: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data((domain + "\\u{0}" + value).utf8), using: tokenKey).map { String(format: "%02x", $0) }.joined()
    }

    func seal(_ value: String, context: String) throws -> Data {
        let box = try AES.GCM.seal(Data(value.utf8), using: encryptionKey, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw ManifestFailure.authenticationFailed }
        return Data([1]) + combined
    }

    func open(_ data: Data, context: String) throws -> String {
        guard data.count > 1, data.first == 1 else { throw ManifestFailure.malformedEncryptedField }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst())
            let plain = try AES.GCM.open(box, using: encryptionKey, authenticating: Data(context.utf8))
            guard let value = String(data: plain, encoding: .utf8) else { throw ManifestFailure.authenticationFailed }
            return value
        } catch let error as ManifestFailure { throw error }
          catch { throw ManifestFailure.authenticationFailed }
    }

    func verifier(databaseID: String) -> String { token("key-verifier", domain: databaseID) }
}

public enum ManifestRecoveryState: Equatable, Sendable {
    case ready
    case needsCloudIndexFallback
}

/// P3 deliberately records only this local state. P2 can later satisfy it through a backend
/// object index or provider HEAD request without allowing a blind re-upload today.
public protocol ManifestCloudIndexFallback: Sendable {
    func requestIndexRecovery() async -> ManifestRecoveryState
}
