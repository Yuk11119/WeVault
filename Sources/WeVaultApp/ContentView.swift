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
    @State private var showsActivity = false

    @State private var detail: FileDetailContext?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 240)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            recordList
                .frame(minWidth: 440, idealWidth: 680)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selection) { _, id in
            guard let id, let file = viewModel.displayFiles.first(where: { $0.id == id }) else { return }
            detail = FileDetailContext(file: file, families: viewModel.result?.families ?? [],
                cloud: viewModel.cloudSnapshots[id], archive: viewModel.archivedSnapshots[id])
        }
        .onReceive(viewModel.$result) { result in
            detail?.refresh(files: result?.files ?? [], families: result?.families ?? [])
        }
        .onReceive(viewModel.$archivedSnapshots) { snapshots in
            if let id = detail?.file.id, let snapshot = snapshots[id] { detail?.archive = snapshot }
        }
        .onReceive(viewModel.$cloudSnapshots) { snapshots in
            if let id = detail?.file.id, let snapshot = snapshots[id] { detail?.cloud = snapshot }
        }
        .alert("WeVault", isPresented: .constant(viewModel.alertMessage != nil), actions: {
            Button("OK") {
                viewModel.alertMessage = nil
            }
        }, message: {
            Text(viewModel.alertMessage ?? "")
        })
    }

    private var detailPanel: some View {
        Group {
            if let detail {
                DetailView(file: detail.file, families: detail.families,
                    cloudSnapshot: detail.cloud, archivedSnapshot: detail.archive,
                    isRestoring: viewModel.isRestoring, isReleasing: viewModel.isReleasing,
                    onClose: { self.detail = nil; selection = nil },
                    onOpenRestoreCenter: {
                        if let archive = detail.archive { AppState.shared.openRestoreCenter(bindingID: archive.binding.bindingID) }
                    },
                    onQuarantineLocal: { createPlaceholder in
                        if let archive = detail.archive { viewModel.quarantineLocal(snapshot: archive, createTombstone: createPlaceholder) }
                    },
                    onRollbackLocal: {
                        if let archive = detail.archive { viewModel.rollbackLocal(snapshot: archive) }
                    },
                    onFinalizeLocalRelease: {
                        if let archive = detail.archive { viewModel.finalizeLocalRelease(snapshot: archive) }
                    })
                    .id(detail.file.id)
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.14), radius: 12, x: -3, y: 3)
                    .padding(12)
                    .padding(.top, 30)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("WeVault").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                Label("文件归档", systemImage: "archivebox.fill")
                    .font(.headline).foregroundStyle(.tint)
                Button { AppState.shared.openRestoreCenter() } label: {
                    Label("恢复文件", systemImage: "arrow.down.doc")
                }.buttonStyle(.plain)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label(settings.cloudMode == .selfManaged ? "手动上传模式" : (settings.automaticTasksEnabled ? "自动整理已开启" : "自动整理已暂停"),
                      systemImage: settings.automaticTasksEnabled ? "clock" : "pause.circle")
                if isAutomationRunning {
                    ProgressView("正在整理…")
                } else if settings.cloudMode == .weVault, settings.automaticExecutionPermitted, let snapshot = automationSnapshot, !snapshot.task.isPaused {
                    Text("下次：\(snapshot.task.nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if automationSnapshot?.latestRun?.needsNetworkRetry == true {
                    Text("等待联网后重试").font(.caption).foregroundStyle(.orange)
                } else if automationSnapshot?.latestRun?.status == .failed {
                    Text("上次整理未完成").font(.caption).foregroundStyle(.orange)
                }
            }.font(.callout)
            Spacer()
            Button(action: openSettings) { Label("设置", systemImage: "gearshape") }
                .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isBusy: Bool {
        isAutomationRunning || viewModel.isScanning || viewModel.isUploading || viewModel.isRestoring || viewModel.isReleasing
    }

    private var canUpload: Bool {
        viewModel.selectedRoot != nil && (settings.cloudMode == .weVault ? managedAccount.isReady : (try? selfManagedCloud.storageConfig()) != nil)
    }

    private var primaryAction: ArchivePrimaryAction {
        ArchivePrimaryAction.resolve(settings: settings, hasRoot: viewModel.selectedRoot != nil,
            accountReady: managedAccount.isReady, storageReady: (try? selfManagedCloud.storageConfig()) != nil)
    }

    private func uploadFiles() {
        viewModel.uploadHashedCandidates(managedAccount: managedAccount, selfManagedCloud: selfManagedCloud, mode: settings.cloudMode)
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .organize: runAutomationNow()
        case .upload: uploadFiles()
        default: openSettings()
        }
    }

    private var workflowHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件归档").font(.title2.bold())
                    Text("按规则整理文件，需要时恢复")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if isAutomationRunning || viewModel.isScanning || viewModel.isUploading {
                    ProgressView().controlSize(.small)
                    if isAutomationRunning {
                        Text("正在整理…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("停止", action: viewModel.cancelManualTask)
                    }
                } else {
                    Button(primaryAction.title, action: performPrimaryAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isRestoring || viewModel.isReleasing)
                        .help(primaryAction.hint)
                }
                Menu {
                    Button("仅扫描", action: viewModel.scan)
                        .disabled(viewModel.selectedRoot == nil || isBusy)
                    if primaryAction != .upload {
                        Button("仅上传", action: uploadFiles)
                            .disabled(!canUpload || isBusy)
                    }
                    Divider()
                    Button("整理设置…", action: openSettings)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("更多操作").help("更多操作")
            }
            if let root = viewModel.selectedRoot {
                Text(root.lastPathComponent + " · 大于等于 \(settings.largeFileThresholdMB) MB")
                    .font(.caption).foregroundStyle(.secondary).help(root.path)
            }
            if !viewModel.uploadMessage.isEmpty { Text(viewModel.uploadMessage).font(.callout).textSelection(.enabled) }
            if !viewModel.releaseMessage.isEmpty { Text(viewModel.releaseMessage).font(.callout).textSelection(.enabled) }
            Button { showsActivity.toggle() } label: {
                Label("最近活动", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsActivity, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("最近活动").font(.headline)
                        Spacer()
                        Button { showsActivity = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭最近活动")
                    }
                    ScrollView {
                        activitySection
                        if let run = automationSnapshot?.latestRun {
                            Text(automationRunDescription(run)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(16).frame(width: 320, height: 280)
            }
        }.padding()
    }

    private var recordList: some View {
        VStack(spacing: 0) {
            workflowHeader
            Divider()
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
                    .width(min: 70, ideal: 85)

                    TableColumn("文件名", value: \.filename) { file in
                        Text(file.filename)
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 260)

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

                    TableColumn("本地状态") { file in
                        Text(viewModel.archivedSnapshots[file.path]?.localStatusTitle ?? "在本地")
                    }
                    .width(min: 80, ideal: 100)
            }
            .overlay {
                if viewModel.filteredFiles.isEmpty && !viewModel.isScanning {
                    ContentUnavailableView(viewModel.result == nil && !viewModel.isAutomaticPage ? "从这里开始整理微信文件" : "没有符合条件的文件",
                        systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .overlay(alignment: .trailing) { detailPanel }
            if viewModel.isAutomaticPage {
                HStack {
                    Button("上一页") { viewModel.loadAutomaticPage(previous: true) }.disabled(viewModel.automaticPageNumber <= 1 || viewModel.isLoadingPage)
                    Text("第 \(viewModel.automaticPageNumber) / \(viewModel.automaticTotalPages) 页")
                    Button("下一页") { viewModel.loadAutomaticPage(next: true) }.disabled(!viewModel.hasNextAutomaticPage || viewModel.isLoadingPage)
                }.padding(10)
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.recentOperations.isEmpty {
                Text("暂无活动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("连续文件操作会合并显示")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(RecentActivityItem.items(from: viewModel.recentOperations).prefix(5)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(item.isFailure ? .red : .primary)
                        Text(item.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func automationRunDescription(_ run: AutomationTaskRun) -> String {
        switch run.status {
        case .waitingForCloud:
            return "\(run.failureReason ?? "等待云端条件")"
        case .completed:
            return "整理完成"
        case .failed:
            return "失败（\(run.completedUnits)/\(run.totalUnits) 已完成）：\(run.failureReason ?? "可重试错误")"
        case .running:
            return "\(run.stage.displayName)：\(run.completedUnits)/\(run.totalUnits)"
        case .scheduled: return "等待下次整理"
        case .paused: return "自动整理已暂停"
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
        didSet { if isAutomaticPage || isLoadingPage { loadAutomaticPage(reset: true) } }
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
        didSet { if isAutomaticPage || isLoadingPage { loadAutomaticPage(reset: true) } }
    }

    @Published var isAutomaticPage = false
    @Published var hasNextAutomaticPage = false
    @Published var automaticPageNumber = 1
    private var loadedScanSession: String?
    private let archiveStoreFactory: @Sendable () throws -> ManifestStore
    @Published private(set) var automaticFilteredCount = 0
    var automaticTotalPages: Int { max(1, (automaticFilteredCount + 49) / 50) }
    private var automaticCursors: [FileRecord?] = [nil]

    private var pageTask: Task<Void, Never>?
    private var pageGeneration = 0
    @Published private(set) var isLoadingPage = false

    func waitForPage() async { await pageTask?.value }

    func loadAutomaticPage(reset: Bool = false, next: Bool = false, previous: Bool = false) {
        guard let root = selectedRoot else { return }
        pageGeneration += 1
        let generation = pageGeneration
        pageTask?.cancel()
        let pageNumber = reset ? 1 : max(1, automaticPageNumber + (next && hasNextAutomaticPage ? 1 : 0) - (previous ? 1 : 0))
        let boundary = reset ? nil : automaticCursors.indices.contains(pageNumber - 1) ? automaticCursors[pageNumber - 1] : nil
        let oldSession = loadedScanSession
        let sort = sortOrder, selectedFilter = filter
        let factory = archiveStoreFactory
        let threshold = Int64(largeFileThresholdMB * 1024 * 1024)
        isLoadingPage = true
        pageTask = Task {
            defer { if generation == pageGeneration { isLoadingPage = false } }
            do {
                let worker = Task.detached(priority: .utility) {
                    try ScanPageReader.load(store: factory().reopen(), root: root, previousSession: oldSession,
                        boundary: boundary, filter: selectedFilter, sort: sort, threshold: threshold)
                }
                let page = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == pageGeneration, selectedRoot == root, let page else { return }
                if reset || page.session != loadedScanSession { automaticCursors = [nil]; automaticPageNumber = 1 }
                else { automaticPageNumber = pageNumber }
                loadedScanSession = page.session
                hasNextAutomaticPage = page.hasNext
                if let last = page.lastBoundary, automaticCursors.count == automaticPageNumber { automaticCursors.append(last) }
                automaticFilteredCount = page.count
                archivedSnapshots = page.archived
                cloudSnapshots = page.cloud
                isAutomaticPage = true
                result = page.result
            } catch is CancellationError { }
              catch { if generation == pageGeneration { alertMessage = UserFacingFailure.describe(error).description } }
        }
    }

    let manifestURL = ManifestStore.defaultDatabaseURL()

    init(archiveStoreFactory: @escaping @Sendable () throws -> ManifestStore = { try ManifestStore() }) {
        self.archiveStoreFactory = archiveStoreFactory
        selectedRoot = nil
    }

    func apply(_ settings: ProductSettings) {
        pageGeneration += 1
        pageTask?.cancel()
        isLoadingPage = false
        if Int(largeFileThresholdMB) != settings.largeFileThresholdMB { cancelManualTask() }
        if selectedRoot?.path != settings.scanRootPath { cancelManualTask(); result = nil; isAutomaticPage = false }
        largeFileThresholdMB = Double(settings.largeFileThresholdMB)
        selectedRoot = settings.scanRootPath.map { URL(fileURLWithPath: $0) }
        restorePersistedArchiveView()
    }

    var activitySummary: String {
        if isScanning { return "正在扫描文件" }
        if let latest = RecentActivityItem.items(from: recentOperations).first {
            return latest.isFailure ? "最近操作出现异常：\(latest.title)" : "最近操作：\(latest.title)"
        }
        return "尚无任务记录"
    }

    private var activityTask: Task<Void, Never>?
    func reloadActivity() {
        activityTask?.cancel()
        let factory = archiveStoreFactory
        activityTask = Task {
            let worker = Task.detached(priority: .utility) { try factory().reopen().recentOperations() }
            do {
                let operations = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                if !Task.isCancelled { recentOperations = operations }
            } catch is CancellationError { }
              catch { if !Task.isCancelled { alertMessage = UserFacingFailure.describe(error).description } }
        }
    }

    /// Restores verified manifest bindings immediately after launch, so a completed
    /// background task remains visible without forcing another filesystem scan.
    private func restorePersistedArchiveView() {
        guard selectedRoot != nil else {
            result = nil; cloudSnapshots = [:]; archivedSnapshots = [:]
            return
        }
        loadAutomaticPage(reset: true)
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
        if isAutomaticPage { return "上传前会分批刷新整个扫描范围；处理达到阈值的普通文件、重复文件及媒体候选，不限于当前页。" }
        guard let files = result?.files else {
            return "扫描后可上传已有 SHA 的可归档对象；上传前会按当前阈值刷新扫描，普通大文件和重复文件会计算 SHA，重复对象云端只保存一份。"
        }
        let uploadable = uploadableFiles(from: files)
        guard !uploadable.isEmpty else {
            return "当前没有可上传对象。普通文件需达到当前大文件阈值或进入重复识别；高清图片和视频 Raw 候选会计算 SHA。"
        }
        let ordinary = uploadable.filter { $0.objectType == .ordinaryFile }.count
        let image = uploadable.filter { $0.objectType == .imageHighLayer }.count
        let video = uploadable.filter { $0.objectType == .videoRawLayer }.count
        let uniqueObjects = Dictionary(grouping: uploadable, by: { $0.sha256 ?? $0.path }).values.compactMap(\.first)
        let uniqueBytes = uniqueObjects.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "将上传本次扫描中已有 SHA 且可归档的对象：普通文件 \(ordinary) 项、高清图片 \(image) 项、原画视频 \(video) 项；按 SHA 去重后云端对象 \(uniqueObjects.count) 个，约 \(humanBytes(uniqueBytes))。上传前会按当前阈值刷新扫描；不会上传无 SHA、不可归档项，也不会移动或删除本地文件。"
    }

    private var manualTask: Task<Void, Never>?

    func cancelManualTask() { manualTask?.cancel() }

    func scan() {
        guard let root = selectedRoot, !isScanning, !isUploading else { return }
        do { try OperationCoordinator.shared.acquire(OperationCoordinator.pipelineKey()) }
        catch { alertMessage = UserFacingFailure.describe(error).description; return }
        isScanning = true
        alertMessage = nil
        let threshold = Int64(largeFileThresholdMB * 1024 * 1024)
        manualTask = Task {
            defer { isScanning = false; manualTask = nil; OperationCoordinator.shared.release(OperationCoordinator.pipelineKey()) }
            do {
                let worker = Task.detached(priority: .utility) {
                    let store = try ManifestStore()
                    return try await ManualArchivePipeline.scan(root: root, threshold: threshold, store: store)
                }
                _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                if selectedRoot == root { loadAutomaticPage(reset: true) }
                reloadActivity()
            } catch { alertMessage = UserFacingFailure.describe(error).description }
        }
    }

    func uploadHashedCandidates(managedAccount: ManagedAccount, selfManagedCloud: SelfManagedCloud, mode: ProductSettings.CloudMode) {
        guard let root = selectedRoot, !isScanning, !isUploading else { return }
        do { try OperationCoordinator.shared.acquire(OperationCoordinator.pipelineKey()) }
        catch { alertMessage = UserFacingFailure.describe(error).description; return }
        isUploading = true
        alertMessage = nil
        uploadMessage = "正在检查文件并归档…"
        let threshold = Int64(largeFileThresholdMB * 1024 * 1024)
        manualTask = Task {
            defer { isUploading = false; manualTask = nil; OperationCoordinator.shared.release(OperationCoordinator.pipelineKey()) }
            do {
                let config = mode == .selfManaged ? try selfManagedCloud.storageConfig() : nil
                let initialAuthorization = mode == .weVault ? try await managedAccount.withAuthorizedDevice() : nil
                let worker = Task.detached(priority: .utility) {
                    let store = try ManifestStore()
                    let session = try await ManualArchivePipeline.scan(root: root, threshold: threshold, store: store)
                    return try await ManualArchivePipeline.upload(session: session, root: root, threshold: threshold, store: store,
                        progress: { summary in
                            await MainActor.run { self.uploadMessage = "已处理 \(summary.attempted) 项：校验成功 \(summary.verified)，失败 \(summary.failed)" }
                        }) { files, families, connection in
                            if let initialAuthorization {
                                let authorization = try await managedAccount.withAuthorizedDevice()
                                guard authorization.deviceID == initialAuthorization.deviceID else { throw CancellationError() }
                                _ = try await ManagedCloudArchiveService().uploadBatch(files: files, families: families, api: authorization.api, accessToken: authorization.accessToken, deviceID: authorization.deviceID, store: connection)
                            } else if let config {
                                _ = try await CloudUploadService().upload(files: files, families: families, config: config, store: connection, includeAllSnapshots: false)
                            }
                        }
                }
                let summary = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                uploadMessage = "归档完成 \(summary.verified) 项，未完成 \(summary.failed) 项。"
            } catch {
                alertMessage = UserFacingFailure.describe(error).description
                uploadMessage = UserFacingFailure.describe(error).description
            }
            if selectedRoot == root { loadAutomaticPage(reset: true) }
            reloadActivity()
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
                restoreMessage = "恢复失败：\(UserFacingFailure.describe(error).description)"
                if let store = try? ManifestStore() {
                    try? refreshArchiveSnapshots(store: store)
                }
            }
            isRestoring = false
        }
    }

    private func checkCloudBeforeRelease(_ snapshot: ArchivedFileSnapshot, store: ManifestStore) async throws {
        if snapshot.object.storageProvider == "WeVault Managed Cloud" {
            let authorization = try await AppState.shared.managedAccount.withAuthorizedDevice()
            guard try await ManagedCloudArchiveService().isAuthorizedArchive(snapshot, api: authorization.api, accessToken: authorization.accessToken, deviceID: authorization.deviceID, store: store) else {
                throw WeVaultAPIFailure(code: "ARCHIVE_UNAVAILABLE", statusCode: 404, message: "Archive unavailable")
            }
        } else {
            let config = try AppState.shared.selfManagedCloud.storageConfig()
            guard config.provider == snapshot.object.storageProvider, config.bucket == snapshot.object.bucketOrContainer else {
                throw WeVaultError.cloud("自配云端与归档不匹配")
            }
            let head = try await S3CompatibleObjectStorageClient(config: config).headObject(objectKey: snapshot.object.objectKey)
            guard head.sizeBytes == snapshot.object.sizeBytes, head.metadata["sha256"] == snapshot.object.sha256 else { throw WeVaultError.cloud("释放前云端校验失败") }
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
                try await checkCloudBeforeRelease(snapshot, store: store)
                let releaseService = LocalReleaseService()
                let result: LocalReleaseResult
                result = try await Task.detached(priority: .utility) {
                    try releaseService.isolate(snapshot: snapshot, store: store, authorization: .manual(confirmed: true, skipRestoreTest: true), createTombstone: createTombstone)
                }.value
                try refreshArchiveSnapshots(store: store)
                reloadActivity()
                if snapshot.archivedFile.objectType == .imageHighLayer {
                    releaseMessage = "高清原件已暂存，普通图片仍可查看。"
                } else if snapshot.archivedFile.objectType == .videoRawLayer {
                    releaseMessage = "原画视频已暂存，普通版本仍可播放。"
                } else if result.placeholderURL != nil {
                    releaseMessage = "原件已暂存，原位置保留了恢复提示。"
                } else if createTombstone {
                    releaseMessage = "原件已暂存，该类型不支持恢复提示，原位置为空。"
                } else {
                    releaseMessage = "原件已暂存，原位置为空。"
                }
            } catch {
                alertMessage = UserFacingFailure.describe(error).description
                releaseMessage = "隔离失败：\(UserFacingFailure.describe(error).description)"
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
                alertMessage = UserFacingFailure.describe(error).description
                releaseMessage = "回滚失败：\(UserFacingFailure.describe(error).description)"
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
                try await checkCloudBeforeRelease(snapshot, store: store)
                _ = try await Task.detached(priority: .utility) {
                    try LocalReleaseService().finalizeSafely(snapshot: snapshot, store: store, authorization: .manual(confirmed: true, skipRestoreTest: true))
                }.value
                try refreshArchiveSnapshots(store: store)
                reloadActivity()
                releaseMessage = "空间已释放，需要时可从云端恢复。"
            } catch {
                alertMessage = UserFacingFailure.describe(error).description
                releaseMessage = "确认释放失败：\(UserFacingFailure.describe(error).description)"
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

    nonisolated static func displayRecord(for snapshot: ArchivedFileSnapshot) -> FileRecord { snapshot.displayFileRecord }

}


private struct RecentActivityItem: Identifiable, Hashable {
    let id: Int64
    let event: String
    let title: String
    let subtitle: String
    let isFailure: Bool

    static func items(from operations: [OperationRecord], calendar: Calendar = .current) -> [RecentActivityItem] {
        var result: [RecentActivityItem] = []
        var index = operations.startIndex
        while index < operations.endIndex {
            let first = operations[index]
            var count = 1
            var next = operations.index(after: index)
            if first.isFileLevelActivity {
                let minute = calendar.dateInterval(of: .minute, for: first.createdAt)
                while next < operations.endIndex {
                    let candidate = operations[next]
                    guard candidate.event == first.event,
                          candidate.isFailure == first.isFailure,
                          let minute,
                          minute.contains(candidate.createdAt) else { break }
                    count += 1
                    next = operations.index(after: next)
                }
            }
            result.append(RecentActivityItem(operation: first, count: count))
            index = next
        }
        return result
    }

    private init(operation: OperationRecord, count: Int) {
        id = operation.id
        event = operation.event
        isFailure = operation.isFailure
        if count > 1, operation.isFileLevelActivity {
            title = "\(count) 个文件\(operation.eventTitle)"
            subtitle = "同一分钟内的连续文件操作 · " + operation.createdAt.formatted(date: .abbreviated, time: .shortened)
        } else {
            title = operation.isFileLevelActivity ? "1 个文件\(operation.eventTitle)" : operation.eventTitle
            subtitle = operation.isFileLevelActivity ? "单个文件操作 · " + operation.createdAt.formatted(date: .abbreviated, time: .shortened) : operation.createdAt.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

extension OperationRecord {
    var isFileLevelActivity: Bool {
        switch event {
        case "RELEASE_QUARANTINE_FINISHED", "IMAGE_HIGH_RELEASE_QUARANTINE_FINISHED", "VIDEO_RAW_RELEASE_QUARANTINE_FINISHED", "AUTOMATION_ISOLATED", "RELEASE_DELETE_QUARANTINE_FINISHED", "AUTOMATION_FINALIZED", "RESTORE_FINISHED":
            return true
        default:
            return event.contains("UPLOAD") || event.contains("VERIFY") || event.contains("RESTORE") || event.contains("RELEASE")
        }
    }

    var eventTitle: String {
        switch event {
        case "SCAN_STARTED": return "扫描开始"
        case "SCAN_FINISHED": return "扫描完成"
        case "MANAGED_UPLOAD_VERIFIED", "UPLOAD_FINISHED": return "上传完成"
        case "VERIFY_FINISHED": return "云端校验完成"
        case "RESTORE_FINISHED": return "恢复完成"
        case "RELEASE_QUARANTINE_FINISHED", "IMAGE_HIGH_RELEASE_QUARANTINE_FINISHED", "VIDEO_RAW_RELEASE_QUARANTINE_FINISHED": return "已移入暂存区"
        case "RELEASE_DELETE_QUARANTINE_FINISHED": return "已确认释放空间"
        case "AUTOMATION_ISOLATED": return "已移入暂存区"
        case "AUTOMATION_FINALIZED": return "已释放空间"
        default:
            if event.contains("FAILED") { return "操作未完成，请重试" }
            if event.contains("CANCELLED") { return "操作已停止" }
            if event.contains("ROLLBACK") { return "还原本地文件" }
            if event.contains("RESTORE") { return "恢复文件" }
            if event.contains("UPLOAD") { return "归档文件" }
            if event.contains("VERIFY") { return "检查云端文件" }
            if event.contains("RELEASE") { return "整理本地文件" }
            return "整理记录已更新"
        }
    }
}

enum RecordFilter: String, CaseIterable, Identifiable, Sendable {
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
        case .image: "高清图片"
        case .video: "原画视频"
        case .duplicates: "重复"
        }
    }
}

extension ArchiveObjectType {
    var displayName: String {
        switch self {
        case .ordinaryFile: "普通文件"
        case .imageHighLayer: "高清图片"
        case .videoRawLayer: "原画视频"
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

/// The inspector owns its content independently of the visible table page/selection.
struct FileDetailContext {
    var file: FileRecord
    var families: [FamilyRecord]
    var cloud: CloudArchiveSnapshot?
    var archive: ArchivedFileSnapshot?

    mutating func refresh(files: [FileRecord], families: [FamilyRecord]) {
        guard let updated = files.first(where: { $0.id == file.id }) else { return }
        file = updated
        self.families = families
    }
}
