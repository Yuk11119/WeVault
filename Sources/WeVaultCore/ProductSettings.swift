import Foundation

/// Non-sensitive product settings. Credentials deliberately do not belong here:
/// production cloud authorization is introduced through the P2 backend flow.
public struct ProductSettings: Codable, Equatable, Sendable {
    public enum CloudMode: String, Codable, CaseIterable, Sendable {
        case weVault
        case selfManaged
    }

    public var onboardingCompleted: Bool
    public var scanRootPath: String?
    public var largeFileThresholdMB: Int
    public var automaticTasksEnabled: Bool
    public var runIntervalHours: Int
    public var coolingPeriodDays: Int
    public var quarantineRetentionDays: Int
    public var allowedExtensions: [String]
    public var archiveOrdinaryFiles: Bool
    public var archiveImageHighLayers: Bool
    public var archiveVideoRawLayers: Bool
    public var createTombstones: Bool
    public var limitUploadsOnMeteredNetwork: Bool
    public var preferBackgroundExecution: Bool
    public var cloudMode: CloudMode

    public init(
        onboardingCompleted: Bool = false,
        scanRootPath: String? = nil,
        largeFileThresholdMB: Int = 50,
        automaticTasksEnabled: Bool = true,
        runIntervalHours: Int = 24,
        coolingPeriodDays: Int = 7,
        quarantineRetentionDays: Int = 7,
        allowedExtensions: [String] = [],
        archiveOrdinaryFiles: Bool = true,
        archiveImageHighLayers: Bool = true,
        archiveVideoRawLayers: Bool = true,
        createTombstones: Bool = true,
        limitUploadsOnMeteredNetwork: Bool = false,
        preferBackgroundExecution: Bool = true,
        cloudMode: CloudMode = .weVault
    ) {
        self.onboardingCompleted = onboardingCompleted
        self.scanRootPath = scanRootPath
        self.largeFileThresholdMB = largeFileThresholdMB
        self.automaticTasksEnabled = automaticTasksEnabled
        self.runIntervalHours = runIntervalHours
        self.coolingPeriodDays = coolingPeriodDays
        self.quarantineRetentionDays = quarantineRetentionDays
        self.allowedExtensions = allowedExtensions
        self.archiveOrdinaryFiles = archiveOrdinaryFiles
        self.archiveImageHighLayers = archiveImageHighLayers
        self.archiveVideoRawLayers = archiveVideoRawLayers
        self.createTombstones = createTombstones
        self.limitUploadsOnMeteredNetwork = limitUploadsOnMeteredNetwork
        self.preferBackgroundExecution = preferBackgroundExecution
        self.cloudMode = cloudMode
    }

    public static let `default` = ProductSettings()

    public mutating func normalize() {
        largeFileThresholdMB = min(max(largeFileThresholdMB, 1), 500)
        runIntervalHours = min(max(runIntervalHours, 1), 24 * 30)
        coolingPeriodDays = min(max(coolingPeriodDays, 0), 365)
        quarantineRetentionDays = min(max(quarantineRetentionDays, 1), 365)
        allowedExtensions = Array(Set(allowedExtensions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }.filter { !$0.isEmpty })).sorted()
        if scanRootPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            scanRootPath = nil
        }
    }
}
