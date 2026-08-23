import CryptoKit
import Foundation

public enum WeVaultError: Error, LocalizedError {
    case invalidScanRoot(String)
    case sqlite(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidScanRoot(let value):
            return "Invalid scan root: \(value)"
        case .sqlite(let value):
            return "SQLite error: \(value)"
        case .fileSystem(let value):
            return "File system error: \(value)"
        }
    }
}

public func humanBytes(_ value: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var amount = Double(value)
    for unit in units {
        if amount < 1024 || unit == units.last {
            if unit == "B" {
                return "\(Int64(amount)) B"
            }
            return String(format: "%.2f %@", amount, unit)
        }
        amount /= 1024
    }
    return "\(value) B"
}

func sha256Hex(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func sha256File(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        try? handle.close()
    }

    var hasher = SHA256()
    while autoreleasepool(invoking: {
        let data = handle.readData(ofLength: 1024 * 1024)
        if data.isEmpty {
            return false
        }
        hasher.update(data: data)
        return true
    }) {}

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func isMonth(_ value: String) -> Bool {
    guard value.count == 7 else { return false }
    let parts = value.split(separator: "-")
    guard parts.count == 2, parts[0].count == 4, parts[1].count == 2 else { return false }
    guard let month = Int(parts[1]), (1...12).contains(month) else { return false }
    return parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber)
}

func datFamilyPrefix(_ filename: String) -> String? {
    guard filename.hasSuffix(".dat") else { return nil }
    var stem = String(filename.dropLast(4))
    for suffix in ["_h_M", "_h", "_t", "_b", "_M"] {
        if stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            return stem
        }
    }
    return stem
}

func videoFamilyPrefixAndRole(_ filename: String) -> (prefix: String, role: String)? {
    if filename.hasSuffix("_raw.mp4") {
        return (String(filename.dropLast("_raw.mp4".count)), "raw")
    }
    if filename.hasSuffix("_thumb.jpg") {
        return (String(filename.dropLast("_thumb.jpg".count)), "thumb")
    }
    if filename.hasSuffix(".mp4") {
        return (String(filename.dropLast(".mp4".count)), "play")
    }
    if filename.hasSuffix(".jpg") {
        return (String(filename.dropLast(".jpg".count)), "cover")
    }
    return nil
}

func fileStat(_ path: String) throws -> (size: Int64, allocated: Int64, inode: UInt64, nlink: UInt64, mtime: Date) {
    var st = stat()
    guard lstat(path, &st) == 0 else {
        throw WeVaultError.fileSystem("stat failed for \(path)")
    }
    return (
        size: Int64(st.st_size),
        allocated: Int64(st.st_blocks) * 512,
        inode: UInt64(st.st_ino),
        nlink: UInt64(st.st_nlink),
        mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
    )
}

extension URL {
    func pathRelative(to base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let selfPath = standardizedFileURL.path
        if selfPath == basePath {
            return lastPathComponent
        }
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if selfPath.hasPrefix(prefix) {
            return String(selfPath.dropFirst(prefix.count))
        }
        return selfPath
    }
}
