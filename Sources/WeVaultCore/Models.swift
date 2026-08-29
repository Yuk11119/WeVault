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
    case uploadPending = "UPLOAD_PENDING"
    case uploading = "UPLOADING"
    case uploaded = "UPLOADED"
    case verified = "VERIFIED"
    case releaseEligible = "RELEASE_ELIGIBLE"
    case localReleased = "LOCAL_RELEASED"
    case tombstoned = "TOMBSTONED"
    case uploadFailed = "UPLOAD_FAILED"
    case verifyFailed = "VERIFY_FAILED"
    case releaseFailed = "RELEASE_FAILED"
}

public enum CloudVerifyStatus: String, Codable, CaseIterable, Sendable {
    case uploaded = "UPLOADED"
    case verified = "VERIFIED"
    case uploadFailed = "UPLOAD_FAILED"
    case verifyFailed = "VERIFY_FAILED"
}

public enum ArchiveBindingState: String, Codable, CaseIterable, Sendable {
    case uploaded = "UPLOADED"
    case verified = "VERIFIED"
    case localReleased = "LOCAL_RELEASED"
    case verifyFailed = "VERIFY_FAILED"
    case restorePending = "RESTORE_PENDING"
    case restored = "RESTORED"
    case restoreFailed = "RESTORE_FAILED"
    case releaseFailed = "RELEASE_FAILED"
}

public enum LocalArchiveState: String, Codable, CaseIterable, Sendable {
    case localPresent = "LOCAL_PRESENT"
    case quarantined = "QUARANTINED"
    case tombstoned = "TOMBSTONED"
    case localReleased = "LOCAL_RELEASED"
    case restored = "RESTORED"
    case restoreFailed = "RESTORE_FAILED"
    case releaseFailed = "RELEASE_FAILED"
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

public struct OperationRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: Int64
    public let event: String
    public let detail: String?
    public let createdAt: Date

    public init(id: Int64, event: String, detail: String?, createdAt: Date) {
        self.id = id
        self.event = event
        self.detail = detail
        self.createdAt = createdAt
    }

    public var isFailure: Bool {
        event.contains("FAILED") || event.contains("ERROR")
    }
}

public struct CloudObject: Identifiable, Codable, Hashable, Sendable {
    public var id: String { cloudObjectID }

    public let cloudObjectID: String
    public let sha256: String
    public let sizeBytes: Int64
    public let storageProvider: String
    public let bucketOrContainer: String
    public let objectKey: String
    public let uploadedAt: Date
    public let verifiedAt: Date?
    public let verifyStatus: CloudVerifyStatus
    public let refCount: Int

    public init(
        cloudObjectID: String,
        sha256: String,
        sizeBytes: Int64,
        storageProvider: String,
        bucketOrContainer: String,
        objectKey: String,
        uploadedAt: Date,
        verifiedAt: Date?,
        verifyStatus: CloudVerifyStatus,
        refCount: Int
    ) {
        self.cloudObjectID = cloudObjectID
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.storageProvider = storageProvider
        self.bucketOrContainer = bucketOrContainer
        self.objectKey = objectKey
        self.uploadedAt = uploadedAt
        self.verifiedAt = verifiedAt
        self.verifyStatus = verifyStatus
        self.refCount = refCount
    }
}

public struct ArchiveBinding: Identifiable, Codable, Hashable, Sendable {
    public var id: String { bindingID }

    public let bindingID: String
    public let filePath: String
    public let cloudObjectID: String
    public let archiveState: ArchiveBindingState
    public let localState: LocalArchiveState
    public let restoredAt: Date?
    public let lastRestoreCheckAt: Date?
    public let releasedAt: Date?
    public let quarantinedAt: Date?
    public let quarantinePath: String?
    public let placeholderPath: String?
    public let placeholderCreatedAt: Date?
    public let placeholderFormat: String?
    public let placeholderSHA256: String?
    public let placeholderSize: Int64?

    public init(
        bindingID: String,
        filePath: String,
        cloudObjectID: String,
        archiveState: ArchiveBindingState,
        localState: LocalArchiveState,
        restoredAt: Date? = nil,
        lastRestoreCheckAt: Date? = nil,
        releasedAt: Date? = nil,
        quarantinedAt: Date? = nil,
        quarantinePath: String? = nil,
        placeholderPath: String? = nil,
        placeholderCreatedAt: Date? = nil,
        placeholderFormat: String? = nil,
        placeholderSHA256: String? = nil,
        placeholderSize: Int64? = nil
    ) {
        self.bindingID = bindingID
        self.filePath = filePath
        self.cloudObjectID = cloudObjectID
        self.archiveState = archiveState
        self.localState = localState
        self.restoredAt = restoredAt
        self.lastRestoreCheckAt = lastRestoreCheckAt
        self.releasedAt = releasedAt
        self.quarantinedAt = quarantinedAt
        self.quarantinePath = quarantinePath
        self.placeholderPath = placeholderPath
        self.placeholderCreatedAt = placeholderCreatedAt
        self.placeholderFormat = placeholderFormat
        self.placeholderSHA256 = placeholderSHA256
        self.placeholderSize = placeholderSize
    }
}

public struct CloudArchiveSnapshot: Codable, Hashable, Sendable {
    public let object: CloudObject
    public let binding: ArchiveBinding

    public init(object: CloudObject, binding: ArchiveBinding) {
        self.object = object
        self.binding = binding
    }
}

public struct ArchivedFile: Identifiable, Codable, Hashable, Sendable {
    public var id: String { filePath }

    public let filePath: String
    public let objectType: ArchiveObjectType
    public let originalFilename: String
    public let relativePath: String
    public let accountHash: String
    public let accountName: String
    public let month: String?
    public let sizeBytes: Int64
    public let sha256: String
    public let mtime: Date
    public let familyID: String?
    public let displayOrPlaybackPath: String?
    public let bubbleOrThumbPath: String?
    public let archivedAt: Date
    public let updatedAt: Date

    public init(
        filePath: String,
        objectType: ArchiveObjectType,
        originalFilename: String,
        relativePath: String,
        accountHash: String,
        accountName: String,
        month: String?,
        sizeBytes: Int64,
        sha256: String,
        mtime: Date,
        familyID: String?,
        displayOrPlaybackPath: String?,
        bubbleOrThumbPath: String?,
        archivedAt: Date,
        updatedAt: Date
    ) {
        self.filePath = filePath
        self.objectType = objectType
        self.originalFilename = originalFilename
        self.relativePath = relativePath
        self.accountHash = accountHash
        self.accountName = accountName
        self.month = month
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.mtime = mtime
        self.familyID = familyID
        self.displayOrPlaybackPath = displayOrPlaybackPath
        self.bubbleOrThumbPath = bubbleOrThumbPath
        self.archivedAt = archivedAt
        self.updatedAt = updatedAt
    }
}

public struct ArchivedFileSnapshot: Codable, Hashable, Sendable {
    public let archivedFile: ArchivedFile
    public let binding: ArchiveBinding
    public let object: CloudObject

    public init(archivedFile: ArchivedFile, binding: ArchiveBinding, object: CloudObject) {
        self.archivedFile = archivedFile
        self.binding = binding
        self.object = object
    }
}

public struct S3CompatibleStorageConfig: Codable, Equatable, Sendable {
    public var provider: String
    public var endpoint: String
    public var bucket: String
    public var region: String
    public var accessKeyID: String
    public var secretAccessKey: String
    /// Present only for short-lived STS credentials.  User-managed S3 settings
    /// continue to use long-lived keys and leave this value nil.
    public var sessionToken: String?
    public var pathStyle: Bool

    public init(provider: String = "Aliyun OSS", endpoint: String = "https://s3.oss-cn-hangzhou.aliyuncs.com", bucket: String = "wevault-demo-yuk177", region: String = "cn-hangzhou", accessKeyID: String = "", secretAccessKey: String = "", sessionToken: String? = nil, pathStyle: Bool = false) {
        self.provider = provider
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.pathStyle = pathStyle
    }
}
