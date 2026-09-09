import Foundation

/// Debug-only fixture storage for desktop smoke tests. Release builds ignore the flag.
/// It never uses production Keychain material or a user-selected WeChat root.
public enum DevelopmentIsolation {
    public static var root: URL? {
        #if DEBUG
        return fixtureRoot(
            environmentPath: ProcessInfo.processInfo.environment["WEVAULT_P5_TEST_DIRECTORY"],
            bundlePath: Bundle.main.object(forInfoDictionaryKey: "WeVaultDevelopmentFixtureDirectory") as? String
        )
        #else
        return nil
        #endif
    }

    #if DEBUG
    // A dedicated smoke bundle must remain isolated when Launch Services or UI tools
    // relaunch it without the shell's environment. Release builds ignore this key.
    static func fixtureRoot(environmentPath: String?, bundlePath: String?) -> URL? {
        guard let path = environmentPath ?? bundlePath, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent("synthetic-wevault", isDirectory: true)
    }
    #endif

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
