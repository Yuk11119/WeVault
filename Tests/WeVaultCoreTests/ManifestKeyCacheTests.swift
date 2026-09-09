import Foundation
import Security
import Testing
@testable import WeVaultCore

@Suite("Manifest Keychain authorization reuse")
struct ManifestKeyCacheTests {
    @Test("Concurrent connections and create reuse one successful authorization")
    func concurrentReads() throws {
        var reads = 0 // Accessed only while the provider's lock is held.
        let key = Data(repeating: 0x42, count: 32)
        let provider = KeychainManifestKeyProvider { _, result in
            reads += 1
            result.pointee = key as CFData
            return errSecSuccess
        }
        DispatchQueue.concurrentPerform(iterations: 30) { _ in
            do { #expect(try provider.existingKey() == key) }
            catch { Issue.record(error) }
        }
        #expect(try provider.createKey() == key)
        #expect(reads == 1)
    }

    @Test("Denied, missing and invalid reads allow a later successful retry")
    func retry() throws {
        for firstStatus in [errSecAuthFailed, errSecItemNotFound, errSecSuccess] {
            var reads = 0
            let key = Data(repeating: 0x42, count: 32)
            let provider = KeychainManifestKeyProvider { _, result in
                reads += 1
                result.pointee = (reads == 1 ? Data([0]) : key) as CFData
                return reads == 1 ? firstStatus : errSecSuccess
            }
            if firstStatus == errSecItemNotFound {
                #expect(try provider.existingKey() == nil)
            } else {
                #expect(throws: firstStatus == errSecSuccess ? ManifestFailure.invalidKey : .keychainUnavailable) {
                    try provider.existingKey()
                }
            }
            #expect(try provider.existingKey() == key)
            #expect(try provider.existingKey() == key)
            #expect(reads == 2)
        }
    }
}
