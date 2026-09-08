import AppKit
import SwiftUI
import WeVaultCore

struct ContentView: View {
    @ObservedObject var viewModel: ScanViewModel
    @ObservedObject var managedAccount: ManagedAccount
    @ObservedObject var selfManagedCloud: SelfManagedCloud
    let settings: ProductSettings
    let automationSnapshot: AutomationTaskSnapshot?
    let isAutomationRunning: Bool
    let runAutomationNow: () -> Void
    let openSettings: () -> Void
    @State private var selection: FileRecord.ID?

    var selectedFile: FileRecord? {
        guard let selection else { return nil }
        return viewModel.displayFiles.first { $0.id == selection }
    }

    var selectedArchiveSnapshot: ArchivedFileSnapshot? {
        guard let selection else { return nil }
        return viewModel.archivedSnapshots[selection]
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 360)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            recordList
                .frame(minWidth: 440, idealWidth: 680)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            DetailView(
                file: selectedFile,
                families: viewModel.result?.families ?? [],
                cloudSnapshot: selectedFile.flatMap { viewModel.cloudSnapshots[$0.path] },
                archivedSnapshot: selectedArchiveSnapshot,
                isRestoring: viewModel.isRestoring,
                isReleasing: viewModel.isReleasing,
                onOpenRestoreCenter: {
                    if let selectedArchiveSnapshot {
                        AppState.shared.openRestoreCenter(bindingID: selectedArchiveSnapshot.binding.bindingID)
                    }
                },
                onQuarantineLocal: {
                    if let selectedArchiveSnapshot {
                        viewModel.quarantineLocal(snapshot: selectedArchiveSnapshot, createTombstone: $0)
                    }
                },
                onRollbackLocal: {
                    if let selectedArchiveSnapshot {
                        viewModel.rollbackLocal(snapshot: selectedArchiveSnapshot)
                    }
                },
                onFinalizeLocalRelease: {
                    if let selectedArchiveSnapshot {
                        viewModel.finalizeLocalRelease(snapshot: selectedArchiveSnapshot)
                    }
                }
            )
                .frame(minWidth: 280, idealWidth: 420)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("WeVault", isPresented: .constant(viewModel.alertMessage != nil), actions: {
            Button("OK") {
                viewModel.alertMessage = nil
            }
        }, message: {
            Text(viewModel.alertMessage ?? "")
        })
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WeVault")
                        .font(.largeTitle.bold())
                    Text("状态中心 · 手动任务")
                        .foregroundStyle(.secondary)
                }

                Button("打开恢复中心") { AppState.shared.openRestoreCenter() }
                Button("打开设置", action: openSettings)

                VStack(alignment: .leading, spacing: 8) {
                    Text("当前扫描范围")
                        .font(.headline)
                    Text(viewModel.selectedRoot?.path ?? "请选择 xwechat_files 或 wxid_* 账号目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack {
                        Button("开始扫描", action: viewModel.scan)
                            .disabled(viewModel.selectedRoot == nil || viewModel.isScanning || isAutomationRunning)
                        Button("修改设置", action: openSettings)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("当前策略")
                        .font(.headline)
                    Text("大文件 ≥ \(settings.largeFileThresholdMB) MB · 每 \(settings.runIntervalHours) 小时 · 冷却 \(settings.coolingPeriodDays) 天 · quarantine \(settings.quarantineRetentionDays) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("对象：\(settings.archiveOrdinaryFiles ? "普通文件" : "")\(settings.archiveImageHighLayers ? " 图片高清层" : "")\(settings.archiveVideoRawLayers ? " 视频 Raw 层" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isScanning {
                    ProgressView("只读扫描中...")
                }

                if viewModel.isAutomaticPage {
                    HStack {
                        Button("上一页") { viewModel.loadAutomaticPage(previous: true) }.disabled(viewModel.automaticPageNumber <= 1)
                        Text("第 \(viewModel.automaticPageNumber) / \(viewModel.automaticTotalPages) 页")
                        Button("下一页") { viewModel.loadAutomaticPage(next: true) }.disabled(!viewModel.hasNextAutomaticPage)
                    }
                }
                activitySection

                automationSection

                VStack(alignment: .leading, spacing: 8) {
                    Text("云端连接")
                        .font(.headline)
                    Text(settings.cloudMode == .weVault ? managedAccount.status : "自配 OSS/COS 高级配置使用短期 STS 凭证，不保存长期密钥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("上传已哈希对象") { viewModel.uploadHashedCandidates(managedAccount: managedAccount, selfManagedCloud: selfManagedCloud, mode: settings.cloudMode) }
                        .disabled(viewModel.result == nil || viewModel.isUploading || isAutomationRunning || (settings.cloudMode == .weVault && !managedAccount.isReady))
                }

                if !viewModel.restoreMessage.isEmpty || viewModel.isRestoring {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("云端恢复")
                            .font(.headline)
                        if viewModel.isRestoring {
                            ProgressView("下载并校验中...")
                        }
                        if !viewModel.restoreMessage.isEmpty {
                            Text(viewModel.restoreMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !viewModel.releaseMessage.isEmpty || viewModel.isReleasing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本地释放")
                            .font(.headline)
                        if viewModel.isReleasing {
                            ProgressView("更新本地副本状态中...")
                        }
                        if !viewModel.releaseMessage.isEmpty {
                            Text(viewModel.releaseMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let result = viewModel.result {
                    SummaryGrid(summary: result.summary)
                    Text("Manifest: \(viewModel.manifestURL.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Text("默认不会自动释放本地副本；支持同类型 tombstone 的普通文件经确认释放后，会在微信原路径生成 WeVault 占位文件，占位不是原件。不支持或关闭 tombstone 时原路径为空。不修改微信数据库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
            .padding(.bottom, 18)
            .padding(.leading, 28)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentMargins(.leading, 0, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var recordList: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("类型", selection: $viewModel.filter) {
                    ForEach(RecordFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                Spacer()
                Text(viewModel.isAutomaticPage ? "共 \(viewModel.automaticFilteredCount) 项 · 本页 \(viewModel.filteredFiles.count) 项" : "\(viewModel.filteredFiles.count) 项")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Table(viewModel.filteredFiles, selection: $selection, sortOrder: $viewModel.sortOrder) {
                    TableColumn("类型", value: \.sortTypeTitle) { file in
                        Text(file.objectType.displayName)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("文件名", value: \.filename) { file in
                        Text(file.filename)
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("会话/来源", value: \.sortConversationTitle) { file in
                        Text(file.conversationName ?? "未解析")
                            .foregroundStyle(file.conversationName == nil ? .secondary : .primary)
                    }
                    .width(min: 110, ideal: 150)

                    TableColumn("月份", value: \.sortMonthTitle) { file in
                        Text(file.month ?? "-")
                            .monospacedDigit()
                    }
                    .width(70)

                    TableColumn("大小", value: \.sizeBytes) { file in
                        Text(humanBytes(file.sizeBytes))
                            .monospacedDigit()
                    }
                    .width(90)

                    TableColumn("上传状态") { file in
                        let status = UserUploadStatus(file: file, cloudSnapshot: viewModel.cloudSnapshots[file.path])
                        Label(status.title, systemImage: status.systemImage)
                            .foregroundStyle(status.color)
                    }
                    .width(min: 100, ideal: 120)
            }
            .frame(minWidth: 680)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近任务")
                .font(.headline)
            if viewModel.recentOperations.isEmpty {
                Text("暂无任务记录。完成一次扫描后会在这里显示最近结果和异常。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.recentOperations.prefix(5)) { operation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(operation.eventTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(operation.isFailure ? .red : .primary)
                        Text(operation.detail ?? "-")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(operation.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("自动任务").font(.headline)
                Spacer()
                Button(isAutomationRunning ? "正在运行…" : (automationSnapshot?.latestRun?.status == .failed ? "立即重试" : "立即运行"), action: runAutomationNow)
                    .disabled(!settings.automaticTasksEnabled || isAutomationRunning)
            }
            if let snapshot = automationSnapshot {
                Text(snapshot.task.isPaused ? "已暂停" : "下次运行：\(snapshot.task.nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if let run = snapshot.latestRun {
                    Text(automationRunDescription(run))
                        .font(.caption).foregroundStyle(run.status == .failed ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("正在恢复任务状态…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func automationRunDescription(_ run: AutomationTaskRun) -> String {
        switch run.status {
        case .waitingForCloud:
            return "\(run.failureReason ?? "等待云端条件")；未扫描、上传或释放本地副本。"
        case .completed:
            return "已完成：\(run.completedUnits)/\(run.totalUnits) 项处理步骤（上传校验、隔离及到期释放）。"
        case .failed:
            return "失败（\(run.completedUnits)/\(run.totalUnits) 已完成）：\(run.failureReason ?? "可重试错误")"
        case .running:
            return "\(run.stage.displayName)：\(run.completedUnits)/\(run.totalUnits)"
        default:
            return run.failureReason ?? run.status.rawValue
        }
    }


}

enum WeChatDirectory {
    static func defaultXWeChatFilesURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var selectedRoot: URL?
    @Published var result: ScanResult?
    @Published var isScanning = false
    @Published var alertMessage: String?
    @Published var largeFileThresholdMB: Double = 50
    @Published var filter: RecordFilter = .all {
        didSet { if isAutomaticPage { loadAutomaticPage(reset: true) } }
    }
    @Published var cloudSnapshots: [String: CloudArchiveSnapshot] = [:]
    @Published var archivedSnapshots: [String: ArchivedFileSnapshot] = [:]
    @Published var isUploading = false
    @Published var uploadMessage = ""
    @Published var isRestoring = false
    @Published var restoreMessage = ""
    @Published var isReleasing = false
    @Published var releaseMessage = ""
    @Published var recentOperations: [OperationRecord] = []
    @Published var sortOrder = [KeyPathComparator(\FileRecord.filename, comparator: .localizedStandard)] {
        didSet { if isAutomaticPage { loadAutomaticPage(reset: true) } }
    }

    @Published var isAutomaticPage = false
    @Published var hasNextAutomaticPage = false
    @Published var automaticPageNumber = 1
    private var loadedScanSession: String?
    private let archiveStoreFactory: () throws -> ManifestStore
    @Published private(set) var automaticFilteredCount = 0
    var automaticTotalPages: Int { max(1, (automaticFilteredCount + 49) / 50) }
    private var automaticCursors: [FileRecord?] = [nil]

    private func matchesFilter(_ file: FileRecord) -> Bool {
        switch filter {
        case .all: return true
        case .ordinary: return file.objectType == .ordinaryFile
        case .image: return file.objectType == .imageHighLayer
        case .video: return file.objectType == .videoRawLayer
        case .duplicates: return file.duplicateGroupID != nil
        }
    }

    private func precedes(_ lhs: FileRecord, _ rhs: FileRecord) -> Bool {
        for comparator in sortOrder {
            let result = comparator.compare(lhs, rhs)
            if result != .orderedSame { return result == .orderedAscending }
        }
        return lhs.path < rhs.path
    }

    func loadAutomaticPage(reset: Bool = false, next: Bool = false, previous: Bool = false) {
        guard let root = selectedRoot else { return }
        do {
            let store = try archiveStoreFactory()
            try store.readTransaction {
            guard let session = try store.currentScanSession(),
                  try store.workGet(String.self, scope: session + ".metadata", key: "root") == root.standardizedFileURL.path else { return }
            if reset || loadedScanSession != session { automaticCursors = [nil]; automaticPageNumber = 1; loadedScanSession = session; hasNextAutomaticPage = false }
            if next, hasNextAutomaticPage { automaticPageNumber += 1 }
            if previous, automaticPageNumber > 1 { automaticPageNumber -= 1 }
            // Decrypt in bounded batches: keep only the next 51 globally ordered
            // matches, never the full scan or plaintext sort keys on disk.
            let boundary = automaticCursors[automaticPageNumber - 1]
            var rows: [FileRecord] = []
            var cursor: Int64 = 0
            var count = 0
            while true {
                let batch = try store.workPage(FileRecord.self, scope: session + ".files", after: cursor)
                guard let last = batch.last else { break }
                cursor = last.id
                for row in batch where matchesFilter(row.value) {
                    count += 1
                    if let boundary, !precedes(boundary, row.value) { continue }
                    let index = rows.firstIndex { precedes(row.value, $0) } ?? rows.endIndex
                    if index < 51 {
                        rows.insert(row.value, at: index)
                        if rows.count > 51 { rows.removeLast() }
                    }
                }
            }
            automaticFilteredCount = count
            hasNextAutomaticPage = rows.count > 50
            if let last = rows.prefix(50).last, automaticCursors.count == automaticPageNumber { automaticCursors.append(last) }
            var visible: [FileRecord] = [], families: [FamilyRecord] = []
            archivedSnapshots = [:]; cloudSnapshots = [:]
            for row in rows.prefix(50) {
                var file = row
                if let snapshot = try store.archivedSnapshot(path: file.path), snapshot.archivedFile.sha256 == file.sha256 {
                    archivedSnapshots[file.path] = snapshot
                    cloudSnapshots[file.path] = CloudArchiveSnapshot(object: snapshot.object, binding: snapshot.binding)
                    file = Self.displayRecord(for: snapshot)
                    file.duplicateGroupID = row.duplicateGroupID
                }
                if let family = try store.workGet(FamilyRecord.self, scope: session + ".families", key: file.path) { families.append(family) }
                visible.append(file)
            }
            let summary = try store.workGet(ScanSummary.self, scope: session + ".metadata", key: "summary") ?? .zero
            isAutomaticPage = true
            result = ScanResult(rootPath: root.path, scannedAt: Date(), largeFileThresholdBytes: Int64(largeFileThresholdMB * 1024 * 1024), files: visible, families: families, duplicateGroups: [], summary: summary)
            }
        } catch { alertMessage = error.localizedDescription }
    }

    let manifestURL = ManifestStore.defaultDatabaseURL()

    init(archiveStoreFactory: @escaping () throws -> ManifestStore = { try ManifestStore() }) {
        self.archiveStoreFactory = archiveStoreFactory
        selectedRoot = nil
    }

    func apply(_ settings: ProductSettings) {
        largeFileThresholdMB = Double(settings.largeFileThresholdMB)
        selectedRoot = settings.scanRootPath.map { URL(fileURLWithPath: $0) }
        restorePersistedArchiveView()
    }

    var activitySummary: String {
        if isScanning { return "正在执行手动扫描" }
        if let latest = recentOperations.first {
            return latest.isFailure ? "最近任务出现异常：\(latest.event)" : "最近任务：\(latest.event)"
        }
        return "尚无任务记录"
    }

    func reloadActivity() {
        recentOperations = (try? ManifestStore().recentOperations()) ?? []
    }

    /// Restores verified manifest bindings immediately after launch, so a completed
    /// background task remains visible without forcing another filesystem scan.
    private func restorePersistedArchiveView() {
        guard let selectedRoot else {
            result = nil
            cloudSnapshots = [:]
            archivedSnapshots = [:]
            return
        }
        do {
            let store = try archiveStoreFactory()
            if let session = try store.currentScanSession(),
               try store.workGet(String.self, scope: session + ".metadata", key: "root") == selectedRoot.standardizedFileURL.path {
                loadAutomaticPage(reset: true); return
            }
            let cloud: [String: CloudArchiveSnapshot] = [:]
            let archived = Dictionary(try store.archivedFilePage().map { ($0.archivedFile.filePath, $0) }, uniquingKeysWith: { first, _ in first })
            let rootPath = selectedRoot.standardizedFileURL.path
            let visible = archived.values.filter { snapshot in
                let path = URL(fileURLWithPath: snapshot.archivedFile.filePath).standardizedFileURL.path
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }
            let files = visible.map(Self.displayRecord(for:)).sorted { $0.relativePath < $1.relativePath }
            let threshold = Int64(largeFileThresholdMB * 1024 * 1024)
            let ordinary = files.filter { $0.objectType == .ordinaryFile }
            let largeOrdinary = ordinary.filter { $0.sizeBytes >= threshold }
            let images = files.filter { $0.objectType == .imageHighLayer }
            let videos = files.filter { $0.objectType == .videoRawLayer }
            let summary = ScanSummary(
                ordinaryCount: ordinary.count,
                ordinaryBytes: ordinary.reduce(0) { $0 + $1.sizeBytes },
                largeOrdinaryCount: largeOrdinary.count,
                largeOrdinaryBytes: largeOrdinary.reduce(0) { $0 + $1.sizeBytes },
                imageHighCandidateCount: images.count,
                imageHighCandidateBytes: images.reduce(0) { $0 + $1.sizeBytes },
                videoRawCandidateCount: videos.count,
                videoRawCandidateBytes: videos.reduce(0) { $0 + $1.sizeBytes },
                videoRawDiscoveredCount: videos.count,
                videoRawDiscoveredBytes: videos.reduce(0) { $0 + $1.sizeBytes },
                videoPlaybackDiscoveredCount: 0,
                videoPlaybackDiscoveredBytes: 0,
                duplicateReclaimableBytes: 0
            )
            cloudSnapshots = cloud
            archivedSnapshots = archived
            result = ScanResult(
                rootPath: rootPath,
                scannedAt: visible.map(\.archivedFile.updatedAt).max() ?? Date(),
                largeFileThresholdBytes: threshold,
                files: files,
                families: [],
                duplicateGroups: [],
                summary: summary
            )
        } catch {
            result = nil
            alertMessage = error.localizedDescription
        }
    }

    /// Publishes a completed background scan into the same state used by the
    /// center table. A result for an old root must not replace a newer selection.
    func applyAutomationResult(
        _ scanResult: ScanResult,
        root: URL,
        cloudSnapshots: [String: CloudArchiveSnapshot],
        archivedSnapshots: [String: ArchivedFileSnapshot],
        failedPaths: Set<String>
    ) {
        self.cloudSnapshots = cloudSnapshots
        self.archivedSnapshots = archivedSnapshots
        if selectedRoot?.standardizedFileURL == root.standardizedFileURL {
            var refreshed = scanResult
            for index in refreshed.files.indices {
                let path = refreshed.files[index].path
                if failedPaths.contains(path) {
                    refreshed.files[index].status = .uploadFailed
                } else if cloudSnapshots[path]?.object.verifyStatus == .verified {
                    refreshed.files[index].status = .verified
                }
            }
            result = Self.scanResultByAddingArchivedDisplayRecords(refreshed, archived: archivedSnapshots, under: root)
        }
        reloadActivity()
    }

    var filteredFiles: [FileRecord] {
        guard let files = result?.files else { return [] }
        if isAutomaticPage { return files }
        let filtered: [FileRecord] = switch filter {
        case .all:
            files
        case .ordinary:
            files.filter { $0.objectType == .ordinaryFile }
        case .image:
            files.filter { $0.objectType == .imageHighLayer }
        case .video:
            files.filter { $0.objectType == .videoRawLayer }
        case .duplicates:
            files.filter { $0.duplicateGroupID != nil }
        }
        return filtered.sorted(using: sortOrder)
    }

    var displayFiles: [FileRecord] {
        result?.files ?? []
    }

    var uploadScopeSummary: String {
        guard let files = result?.files else {
            return "扫描后可上传已有 SHA 的可归档对象；上传前会按当前阈值刷新扫描，普通大文件和重复文件会计算 SHA，重复对象云端只保存一份。"
        }
        let uploadable = uploadableFiles(from: files)
        guard !uploadable.isEmpty else {
            return "当前没有可上传对象。普通文件需达到当前大文件阈值或进入重复识别；图片高清层和视频 Raw 候选会计算 SHA。"
        }
        let ordinary = uploadable.filter { $0.objectType == .ordinaryFile }.count
        let image = uploadable.filter { $0.objectType == .imageHighLayer }.count
        let video = uploadable.filter { $0.objectType == .videoRawLayer }.count
        let uniqueObjects = Dictionary(grouping: uploadable, by: { $0.sha256 ?? $0.path }).values.compactMap(\.first)
        let uniqueBytes = uniqueObjects.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "将上传本次扫描中已有 SHA 且可归档的对象：普通文件 \(ordinary) 项、图片高清层 \(image) 项、视频 Raw 层 \(video) 项；按 SHA 去重后云端对象 \(uniqueObjects.count) 个，约 \(humanBytes(uniqueBytes))。上传前会按当前阈值刷新扫描；不会上传无 SHA、不可归档项，也不会移动或删除本地文件。"
    }

    func scan() {
        guard let selectedRoot else { return }
        do { try OperationCoordinator.shared.acquire(OperationCoordinator.pipelineKey()) }
        catch { alertMessage = error.localizedDescription; return }
        isScanning = true
        isAutomaticPage = false
        alertMessage = nil
        let threshold = Int64(largeFileThresholdMB * 1024 * 1024)

        Task {
            defer { OperationCoordinator.shared.release(OperationCoordinator.pipelineKey()) }
            do {
                let scanResult = try await Task.detached(priority: .userInitiated) {
                    let scanner = WeChatScanner()
                    let store = try ManifestStore()
                    let knownPlaceholders = try store.archivedFileSnapshots().values.compactMap(\.binding.placeholderPath)
                    let scanned = try scanner.scan(root: selectedRoot, options: ScanOptions(largeFileThresholdBytes: threshold, knownPlaceholderPaths: Set(knownPlaceholders)))
                    try store.save(scanResult: scanned)
                    let snapshots = try store.cloudArchiveSnapshots()
                    let archived = try store.archivedFileSnapshots()
                    let result = Self.scanResultByAddingArchivedDisplayRecords(scanned, archived: archived, under: selectedRoot)
                    return (result, snapshots, archived)
                }.value
                result = scanResult.0
                cloudSnapshots = scanResult.1
                archivedSnapshots = scanResult.2
                reloadActivity()
            } catch {
                alertMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    func uploadHashedCandidates(managedAccount: ManagedAccount, selfManagedCloud: SelfManagedCloud, mode: ProductSettings.CloudMode) {
        guard let selectedRoot else { return }
        do { try OperationCoordinator.shared.acquire(OperationCoordinator.pipelineKey()) }
        catch { alertMessage = error.localizedDescription; return }
        isUploading = true
        alertMessage = nil
        uploadMessage = "按当前阈值刷新扫描..."
        let threshold = Int64(largeFileThresholdMB * 1024 * 1024)

        Task {
            defer { OperationCoordinator.shared.release(OperationCoordinator.pipelineKey()) }
            do {
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    let scanner = WeChatScanner()
                    let store = try ManifestStore()
                    let knownPlaceholders = try store.archivedFileSnapshots().values.compactMap(\.binding.placeholderPath)
                    let scanned = try scanner.scan(root: selectedRoot, options: ScanOptions(largeFileThresholdBytes: threshold, knownPlaceholderPaths: Set(knownPlaceholders)))
                    try store.save(scanResult: scanned)
                    let cloudSnapshots = try store.cloudArchiveSnapshots()
                    let archivedSnapshots = try store.archivedFileSnapshots()
                    let scanResult = Self.scanResultByAddingArchivedDisplayRecords(scanned, archived: archivedSnapshots, under: selectedRoot)
                    return (scanResult, cloudSnapshots, archivedSnapshots)
                }.value
                result = refreshed.0
                cloudSnapshots = refreshed.1
                archivedSnapshots = refreshed.2
                uploadMessage = "准备上传：\(uploadableFiles(from: refreshed.0.files).count) 项绑定"

                let store = try ManifestStore()
                let snapshots: [String: CloudArchiveSnapshot]
                if mode == .weVault {
                    let authorization = try await managedAccount.withAuthorizedDevice()
                    snapshots = try await ManagedCloudArchiveService().upload(files: refreshed.0.files, families: refreshed.0.families, api: authorization.api, accessToken: authorization.accessToken, deviceId: authorization.deviceID, store: store) { [weak self] progress in
                        await MainActor.run { self?.apply(progress) }
                    }
                } else {
                    snapshots = try await CloudUploadService().upload(files: refreshed.0.files, families: refreshed.0.families, config: try selfManagedCloud.storageConfig(), store: store) { [weak self] progress in
                        await MainActor.run { self?.apply(progress) }
                    }
                }
                cloudSnapshots = snapshots
                archivedSnapshots = try store.archivedFileSnapshots()
                reloadActivity()
                uploadMessage = "上传完成：已校验 \(snapshots.values.filter { $0.object.verifyStatus == .verified }.count) 项绑定"
            } catch {
                alertMessage = error.localizedDescription
            }
            isUploading = false
        }
    }

    func restore(snapshot: ArchivedFileSnapshot, destination: RestoreDestination, managedAccount: ManagedAccount, selfManagedCloud: SelfManagedCloud) {
        guard !isRestoring, !isReleasing else { return }
        isRestoring = true
        restoreMessage = "准备恢复：\(snapshot.archivedFile.originalFilename)"

        Task {
            do {
                let store = try ManifestStore()
                guard let snapshot = try store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID) else { throw WeVaultError.fileSystem("归档记录不存在") }
                let result: CloudRestoreResult
                if snapshot.object.storageProvider == "WeVault Managed Cloud" {
                    let authorization = try await managedAccount.withAuthorizedDevice()
                    result = try await ManagedCloudArchiveService().restore(snapshot: snapshot, destination: destination, api: authorization.api, accessToken: authorization.accessToken, deviceId: authorization.deviceID, store: store)
                } else {
                    result = try await CloudRestoreService().restore(snapshot: snapshot, destination: destination, config: try selfManagedCloud.storageConfig(), store: store)
                }
                try refreshArchiveSnapshots(store: store)
                reloadActivity()
                restoreMessage = "恢复完成并通过 SHA-256 校验：\(result.destinationURL.path)"
                if case .originalPath = destination, snapshot.archivedFile.objectType != .ordinaryFile {
                    restoreMessage += snapshot.archivedFile.objectType == .imageHighLayer ? "\n请回微信保存高清/原图。" : "\n请回微信执行高质量保存/导出。"
                } else { NSWorkspace.shared.activateFileViewerSelecting([result.destinationURL]) }
            } catch {
                restoreMessage = "恢复失败：\(error.localizedDescription)"
                if let store = try? ManifestStore() {
                    try? refreshArchiveSnapshots(store: store)
                }
            }
            isRestoring = false
        }
    }

    func quarantineLocal(snapshot: ArchivedFileSnapshot, createTombstone: Bool) {
        guard !isReleasing, !isRestoring else { return }
        isReleasing = true
        alertMessage = nil
        releaseMessage = "准备释放本地原件：\(snapshot.archivedFile.originalFilename)"

        Task {
            do {
                let store = try ManifestStore()
                let releaseService = LocalReleaseService()
                let result: LocalReleaseResult
                result = try await Task.detached(priority: .utility) {
                    try releaseService.isolate(snapshot: snapshot, store: store, authorization: .manual(confirmed: true, skipRestoreTest: true), createTombstone: createTombstone)
                }.value
                try refreshArchiveSnapshots(store: store)
                reloadActivity()
                if snapshot.archivedFile.objectType == .imageHighLayer {
                    releaseMessage = "图片高清层已进入隔离区，原高清路径为空；普通查看层仍在本地，高清/原图需要时可从云端恢复。"
                } else if snapshot.archivedFile.objectType == .videoRawLayer {
                    releaseMessage = "视频 Raw 层已进入隔离区，原 Raw 路径为空；普通播放版本仍在本地，保存/导出高质量版本前请从云端恢复 Raw 层。"
                } else if let placeholder = result.placeholderURL {
                    releaseMessage = "原件已进入隔离区，微信原路径已写入 tombstone：\(placeholder.path)"
                } else if createTombstone {
                    releaseMessage = "原件已进入隔离区；当前文件类型未生成同类型 tombstone，微信原路径为空。"
                } else {
                    releaseMessage = "原件已进入隔离区；tombstone 已关闭，微信原路径为空。"
                }
            } catch {
                alertMessage = error.localizedDescription
                releaseMessage = "隔离失败：\(error.localizedDescription)"
                if let store = try? ManifestStore() {
                    try? refreshArchiveSnapshots(store: store)
                }
            }
            isReleasing = false
        }
    }

    func rollbackLocal(snapshot: ArchivedFileSnapshot) {
        guard !isReleasing, !isRestoring else { return }
        isReleasing = true
        alertMessage = nil
        releaseMessage = "准备从隔离区回滚：\(snapshot.archivedFile.originalFilename)"

        Task {
            do {
                let store = try ManifestStore()
                let key = OperationCoordinator.bindingKey(snapshot.binding.bindingID, store: store)
                try OperationCoordinator.shared.acquire(key)
                defer { OperationCoordinator.shared.release(key) }
                guard try !store.hasPendingRelease(bindingID: snapshot.binding.bindingID) else { throw WeVaultError.fileSystem("请先重试未完成的本地释放任务") }
                guard let current = try store.archivedFileSnapshot(bindingID: snapshot.binding.bindingID) else { throw WeVaultError.fileSystem("归档绑定不存在") }
                let result = try LocalReleaseService().rollback(snapshot: current, store: store)
                try refreshArchiveSnapshots(store: store)
                reloadActivity()
                releaseMessage = "已回滚并通过 SHA-256 校验：\(result.originalURL.path)"
                NSWorkspace.shared.activateFileViewerSelecting([result.originalURL])
            } catch {
                alertMessage = error.localizedDescription
                releaseMessage = "回滚失败：\(error.localizedDescription)"
                if let store = try? ManifestStore() {
                    try? refreshArchiveSnapshots(store: store)
                }
            }
            isReleasing = false
        }
    }

    func finalizeLocalRelease(snapshot: ArchivedFileSnapshot) {
        guard !isReleasing, !isRestoring else { return }
        isReleasing = true
        alertMessage = nil
        releaseMessage = "准备确认释放空间：\(snapshot.archivedFile.originalFilename)"

        Task {
            do {
                let store = try ManifestStore()
                _ = try await Task.detached(priority: .utility) {
                    try LocalReleaseService().finalizeSafely(snapshot: snapshot, store: store, authorization: .manual(confirmed: true, skipRestoreTest: true))
                }.value
                try refreshArchiveSnapshots(store: store)
                reloadActivity()
                releaseMessage = "已删除隔离副本；云端对象和 manifest 仍保留，可从云端恢复。"
            } catch {
                alertMessage = error.localizedDescription
                releaseMessage = "确认释放失败：\(error.localizedDescription)"
                if let store = try? ManifestStore() {
                    try? refreshArchiveSnapshots(store: store)
                }
            }
            isReleasing = false
        }
    }

    private func apply(_ progress: CloudUploadProgress) {
        uploadMessage = progress.message ?? "\(URL(fileURLWithPath: progress.filePath).lastPathComponent): \(progress.status.rawValue)"
        guard var current = result else { return }
        if let index = current.files.firstIndex(where: { $0.path == progress.filePath }) {
            current.files[index].status = progress.status
            result = current
        }
    }

    private func uploadableFiles(from files: [FileRecord]) -> [FileRecord] {
        files.filter {
            $0.sha256 != nil &&
                $0.status != .notArchivable &&
                $0.status != .tombstoned &&
                $0.status != .localReleased &&
                $0.status != .releaseEligible
        }
    }

    private func refreshArchiveSnapshots(store: ManifestStore) throws {
        if let session = try store.currentScanSession(), let root = selectedRoot,
           try store.workGet(String.self, scope: session + ".metadata", key: "root") == root.standardizedFileURL.path {
            loadAutomaticPage(); return
        }
        archivedSnapshots = [:]; cloudSnapshots = [:]
        for file in result?.files ?? [] {
            if let snapshot = try store.archivedSnapshot(path: file.path) {
                archivedSnapshots[file.path] = snapshot
                cloudSnapshots[file.path] = CloudArchiveSnapshot(object: snapshot.object, binding: snapshot.binding)
            }
        }
        if let current = result, let selectedRoot {
            result = Self.scanResultByAddingArchivedDisplayRecords(current, archived: archivedSnapshots, under: selectedRoot)
        }
        recentOperations = try store.recentOperations()
    }

    nonisolated private static func scanResultByAddingArchivedDisplayRecords(
        _ scanResult: ScanResult,
        archived: [String: ArchivedFileSnapshot],
        under root: URL
    ) -> ScanResult {
        var merged = scanResult
        var existingPaths = Set(merged.files.map(\.path))
        let rootPath = root.standardizedFileURL.path
        let archivedOnly = archived.values
            .filter { snapshot in
                let path = URL(fileURLWithPath: snapshot.archivedFile.filePath).standardizedFileURL.path
                return !existingPaths.contains(snapshot.archivedFile.filePath) &&
                    (path == rootPath || path.hasPrefix(rootPath + "/")) &&
                    (snapshot.binding.localState == .quarantined ||
                     snapshot.binding.localState == .tombstoned ||
                     snapshot.binding.localState == .localReleased)
            }
            .sorted { $0.archivedFile.filePath < $1.archivedFile.filePath }

        for snapshot in archivedOnly {
            merged.files.append(displayRecord(for: snapshot))
            existingPaths.insert(snapshot.archivedFile.filePath)
        }
        merged.files.sort { $0.relativePath < $1.relativePath }
        return merged
    }

    nonisolated private static func displayRecord(for snapshot: ArchivedFileSnapshot) -> FileRecord {
        let archived = snapshot.archivedFile
        let status: ArchiveStatus
        let reason: String
        switch snapshot.binding.localState {
        case .tombstoned:
            status = .tombstoned
            reason = "原件已归档，微信原路径为 tombstone 占位提示；可从详情恢复原件。"
        case .quarantined:
            status = .releaseEligible
            reason = "原件已进入 WeVault quarantine，微信原路径为空；可从详情回滚或从云端恢复。"
        case .localReleased:
            status = .localReleased
            reason = "本地隔离副本已确认释放；云端对象和 manifest 仍保留，可从详情恢复。"
        default:
            status = .verified
            reason = "已归档普通文件。"
        }
        return FileRecord(
            path: archived.filePath,
            relativePath: archived.relativePath,
            objectType: archived.objectType,
            accountHash: archived.accountHash,
            accountName: archived.accountName,
            filename: archived.originalFilename,
            fileExtension: URL(fileURLWithPath: archived.originalFilename).pathExtension.lowercased(),
            month: archived.month,
            sizeBytes: archived.sizeBytes,
            allocatedBytes: snapshot.binding.placeholderSize ?? 0,
            inode: 0,
            nlink: 0,
            mtime: archived.mtime,
            sha256: archived.sha256,
            status: status,
            candidateReason: reason
        )
    }

}

private extension OperationRecord {
    var eventTitle: String {
        switch event {
        case "SCAN_STARTED": "扫描开始"
        case "SCAN_FINISHED": "扫描完成"
        case "UPLOAD_FINISHED": "上传完成"
        case "VERIFY_FINISHED": "云端校验完成"
        case "RESTORE_FINISHED": "恢复完成"
        case "RELEASE_QUARANTINE_FINISHED", "IMAGE_HIGH_RELEASE_QUARANTINE_FINISHED", "VIDEO_RAW_RELEASE_QUARANTINE_FINISHED": "已进入 quarantine"
        case "RELEASE_DELETE_QUARANTINE_FINISHED": "已确认释放空间"
        default: event
        }
    }
}

enum RecordFilter: String, CaseIterable, Identifiable {
    case all
    case ordinary
    case image
    case video
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .ordinary: "普通文件"
        case .image: "图片高清层"
        case .video: "视频 Raw 层"
        case .duplicates: "重复"
        }
    }
}

extension ArchiveObjectType {
    var displayName: String {
        switch self {
        case .ordinaryFile: "普通文件"
        case .imageHighLayer: "图片高清层"
        case .videoRawLayer: "视频 Raw 层"
        }
    }
}

private extension FileRecord {
    var sortTypeTitle: String { objectType.displayName }
    var sortConversationTitle: String { conversationName ?? "未解析" }
    var sortMonthTitle: String { month ?? "" }
}

enum UserUploadStatus {
    case uploaded
    case uploading
    case failed
    case notUploaded

    init(file: FileRecord, cloudSnapshot: CloudArchiveSnapshot?) {
        if cloudSnapshot?.object.verifyStatus == .verified || file.status == .verified {
            self = .uploaded
        } else {
            switch file.status {
            case .uploadPending, .uploading, .uploaded:
                self = .uploading
            case .uploadFailed, .verifyFailed:
                self = .failed
            default:
                self = .notUploaded
            }
        }
    }

    var title: String {
        switch self {
        case .uploaded: "已上传"
        case .uploading: "上传中"
        case .failed: "上传失败"
        case .notUploaded: "未上传"
        }
    }

    var systemImage: String {
        switch self {
        case .uploaded: "checkmark.circle.fill"
        case .uploading: "arrow.up.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .notUploaded: "circle"
        }
    }

    var color: Color {
        switch self {
        case .uploaded: .green
        case .uploading: .blue
        case .failed: .red
        case .notUploaded: .secondary
        }
    }
}
