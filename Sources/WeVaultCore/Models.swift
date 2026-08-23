import Foundation

public enum ArchiveObjectType: String, Codable, CaseIterable, Sendable {
    case ordinaryFile = "ORDINARY_FILE"
    case imageHighLayer = "IMAGE_HIGH_LAYER"
    case videoRawLayer = "VIDEO_RAW_LAYER"
}

public enum ArchiveStatus: String, Codable, CaseIterable, Sendable {
    case discovered = "DISCOVERED"
    case hashed = "HASHED"
    case duplicateGrouped = "DUPLICATE_GROUPED"
    case notArchivable = "NOT_ARCHIVABLE"
}

public struct FileRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }

    public let path: String
    public let relativePath: String
    public let objectType: ArchiveObjectType
    public let accountHash: String
    public let accountName: String
    public let conversationName: String?
    public let conversationResolution: String
    public let filename: String
    public let fileExtension: String
    public let month: String?
    public let sizeBytes: Int64
    public let allocatedBytes: Int64
    public let inode: UInt64
    public let nlink: UInt64
    public let mtime: Date
    public var sha256: String?
    public var status: ArchiveStatus
    public var duplicateGroupID: String?
    public var candidateReason: String?

    public init(
        path: String,
        relativePath: String,
        objectType: ArchiveObjectType,
        accountHash: String,
        accountName: String,
        conversationName: String? = nil,
        conversationResolution: String = "未解析：微信 4.x 会话数据库不是标准 SQLite，路径本身不包含会话名",
        filename: String,
        fileExtension: String,
        month: String?,
        sizeBytes: Int64,
        allocatedBytes: Int64,
        inode: UInt64,
        nlink: UInt64,
        mtime: Date,
        sha256: String? = nil,
        status: ArchiveStatus = .discovered,
        duplicateGroupID: String? = nil,
        candidateReason: String? = nil
    ) {
        self.path = path
        self.relativePath = relativePath
        self.objectType = objectType
        self.accountHash = accountHash
        self.accountName = accountName
        self.conversationName = conversationName
        self.conversationResolution = conversationResolution
        self.filename = filename
        self.fileExtension = fileExtension
        self.month = month
        self.sizeBytes = sizeBytes
        self.allocatedBytes = allocatedBytes
        self.inode = inode
        self.nlink = nlink
        self.mtime = mtime
        self.sha256 = sha256
        self.status = status
        self.duplicateGroupID = duplicateGroupID
        self.candidateReason = candidateReason
    }
}

public struct FamilyRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let familyType: ArchiveObjectType
    public let accountHash: String
    public let accountName: String
    public let month: String?
    public let prefix: String
    public let highOrRawPath: String
    public let displayOrPlaybackPath: String?
    public let bubbleOrThumbPath: String?
    public let isCandidate: Bool
    public let reason: String
    public let memberPaths: [String]

    public init(
        id: String,
        familyType: ArchiveObjectType,
        accountHash: String,
        accountName: String,
        month: String?,
        prefix: String,
        highOrRawPath: String,
        displayOrPlaybackPath: String?,
        bubbleOrThumbPath: String?,
        isCandidate: Bool,
        reason: String,
        memberPaths: [String]
    ) {
        self.id = id
        self.familyType = familyType
        self.accountHash = accountHash
        self.accountName = accountName
        self.month = month
        self.prefix = prefix
        self.highOrRawPath = highOrRawPath
        self.displayOrPlaybackPath = displayOrPlaybackPath
        self.bubbleOrThumbPath = bubbleOrThumbPath
        self.isCandidate = isCandidate
        self.reason = reason
        self.memberPaths = memberPaths
    }
}

public struct DuplicateGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sha256: String
    public let sizeBytes: Int64
    public let duplicateCount: Int
    public let reclaimableBytes: Int64
    public let paths: [String]

    public init(id: String, sha256: String, sizeBytes: Int64, duplicateCount: Int, reclaimableBytes: Int64, paths: [String]) {
        self.id = id
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.duplicateCount = duplicateCount
        self.reclaimableBytes = reclaimableBytes
        self.paths = paths
    }
}

public struct ScanSummary: Codable, Equatable, Sendable {
    public let ordinaryCount: Int
    public let ordinaryBytes: Int64
    public let largeOrdinaryCount: Int
    public let largeOrdinaryBytes: Int64
    public let imageHighCandidateCount: Int
    public let imageHighCandidateBytes: Int64
    public let videoRawCandidateCount: Int
    public let videoRawCandidateBytes: Int64
    public let videoRawDiscoveredCount: Int
    public let videoRawDiscoveredBytes: Int64
    public let videoPlaybackDiscoveredCount: Int
    public let videoPlaybackDiscoveredBytes: Int64
    public let duplicateReclaimableBytes: Int64
}

public struct ScanResult: Codable, Sendable {
    public let rootPath: String
    public let scannedAt: Date
    public let largeFileThresholdBytes: Int64
    public var files: [FileRecord]
    public let families: [FamilyRecord]
    public let duplicateGroups: [DuplicateGroup]
    public let summary: ScanSummary
}

public struct S3CompatibleStorageConfig: Codable, Equatable, Sendable {
    public var endpoint: String
    public var bucket: String
    public var region: String
    public var accessKeyReference: String
    public var secretKeyReference: String
    public var pathStyle: Bool

    public init(endpoint: String = "", bucket: String = "", region: String = "", accessKeyReference: String = "", secretKeyReference: String = "", pathStyle: Bool = true) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.accessKeyReference = accessKeyReference
        self.secretKeyReference = secretKeyReference
        self.pathStyle = pathStyle
    }
}
