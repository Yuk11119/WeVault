import Foundation

/// Debug-only fixture storage for desktop smoke tests. Release builds ignore the flag.
/// It never uses production Keychain material or a user-selected WeChat root.
public enum DevelopmentIsolation {
    public static var root: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["WEVAULT_P5_TEST_DIRECTORY"], path.hasPrefix("/"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent("synthetic-wevault", isDirectory: true)
        #else
        return nil
        #endif
    }

    public static var permitsInteractiveAuthentication: Bool {
        #if DEBUG
        return root != nil && ProcessInfo.processInfo.environment["WEVAULT_P5_INTERACTIVE_AUTH"] == "1"
        #else
        return false
        #endif
    }

    static var keyProvider: any ManifestKeyProvider {
        root == nil ? KeychainManifestKeyProvider.shared : InMemoryManifestKeyProvider(key: Data(repeating: 0x51, count: 32))
    }
}
