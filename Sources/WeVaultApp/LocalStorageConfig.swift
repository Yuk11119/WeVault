import Foundation
import WeVaultCore

enum LocalStorageConfig {
    static let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WeVault", isDirectory: true)
            .appendingPathComponent("storage-config.json")
    }()

    static func load() -> S3CompatibleStorageConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(S3CompatibleStorageConfig.self, from: data) else {
            return S3CompatibleStorageConfig()
        }
        return config
    }
}
