import AppKit
import SwiftUI
import WeVaultCore

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()
    @State private var selection: FileRecord.ID?

    var selectedFile: FileRecord? {
        guard let selection else { return nil }
        return viewModel.result?.files.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 360)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            recordList
                .frame(minWidth: 440, idealWidth: 680)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            DetailView(file: selectedFile, families: viewModel.result?.families ?? [], cloudSnapshot: selectedFile.flatMap { viewModel.cloudSnapshots[$0.path] })
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
                    Text("微信云端归档候选扫描")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("扫描目录")
                        .font(.headline)
                    Text(viewModel.selectedRoot?.path ?? "请选择 xwechat_files 或 wxid_* 账号目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack {
                        Button("选择目录", action: chooseDirectory)
                        Button("开始扫描", action: viewModel.scan)
                            .disabled(viewModel.selectedRoot == nil || viewModel.isScanning)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("大文件阈值")
                        .font(.headline)
                    HStack {
                        Slider(value: $viewModel.largeFileThresholdMB, in: 1...500, step: 1)
                        Text("\(Int(viewModel.largeFileThresholdMB)) MB")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                if viewModel.isScanning {
                    ProgressView("只读扫描中...")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("云端上传")
                        .font(.headline)
                    Text(viewModel.uploadScopeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("上传本次扫描的可归档对象", action: viewModel.uploadHashedCandidates)
                        .disabled(!viewModel.canUpload)
                    if viewModel.isUploading {
                        ProgressView("上传并校验中...")
                    }
                    if !viewModel.uploadMessage.isEmpty {
                        Text(viewModel.uploadMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

                Text("本 demo 会上传并校验云端副本；不释放、不移动、不删除微信文件，不修改微信数据库。")
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
                Text("\(viewModel.filteredFiles.count) 项")
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView(.horizontal) {
                Table(viewModel.filteredFiles, selection: $selection) {
                    TableColumn("类型") { file in
                        Text(file.objectType.displayName)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("文件名") { file in
                        Text(file.filename)
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("会话/来源") { file in
                        Text(file.conversationName ?? "未解析")
                            .foregroundStyle(file.conversationName == nil ? .secondary : .primary)
                    }
                    .width(min: 110, ideal: 150)

                    TableColumn("月份") { file in
                        Text(file.month ?? "-")
                            .monospacedDigit()
                    }
                    .width(70)

                    TableColumn("大小") { file in
                        Text(humanBytes(file.sizeBytes))
                            .monospacedDigit()
                    }
                    .width(90)

                    TableColumn("Allocated") { file in
                        Text(humanBytes(file.allocatedBytes))
                            .monospacedDigit()
                    }
                    .width(100)

                    TableColumn("SHA") { file in
                        Text(file.sha256 == nil ? "未计算" : "已计算")
                            .foregroundStyle(file.sha256 == nil ? .secondary : .primary)
                    }
                    .width(72)

                    TableColumn("重复") { file in
                        Text(file.duplicateGroupID ?? "-")
                            .monospaced()
                    }
                    .width(72)

                    TableColumn("状态") { file in
                        Text(file.status.rawValue)
                    }
                    .width(130)

                    TableColumn("云端") { file in
                        Text(viewModel.cloudStatus(for: file))
                    }
                    .width(92)
                }
                .frame(minWidth: 1006)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if let defaultURL = WeChatDirectory.defaultXWeChatFilesURL(), FileManager.default.fileExists(atPath: defaultURL.path) {
            panel.directoryURL = defaultURL
        }
        if panel.runModal() == .OK {
            viewModel.selectedRoot = panel.url
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
    @Published var filter: RecordFilter = .all
    @Published var storageConfig = LocalStorageConfig.load()
    @Published var cloudSnapshots: [String: CloudArchiveSnapshot] = [:]
    @Published var isUploading = false
    @Published var uploadMessage = ""

    let manifestURL = ManifestStore.defaultDatabaseURL()

    init() {
        selectedRoot = nil
    }

    var filteredFiles: [FileRecord] {
        guard let files = result?.files else { return [] }
        switch filter {
        case .all:
            return files
        case .ordinary:
            return files.filter { $0.objectType == .ordinaryFile }
        case .image:
            return files.filter { $0.objectType == .imageHighLayer }
        case .video:
            return files.filter { $0.objectType == .videoRawLayer }
        case .duplicates:
            return files.filter { $0.duplicateGroupID != nil }
        }
    }

    var canUpload: Bool {
        result != nil &&
            !isScanning &&
            !isUploading &&
            !storageConfig.endpoint.isEmpty &&
            !storageConfig.bucket.isEmpty &&
            !storageConfig.accessKeyID.isEmpty &&
            !storageConfig.secretAccessKey.isEmpty
    }

    var uploadScopeSummary: String {
        guard let files = result?.files else {
            return "扫描后可上传已有 SHA 的可归档对象；普通重复文件云端只保存一份。"
        }
        let uploadable = uploadableFiles(from: files)
        guard !uploadable.isEmpty else {
            return "当前没有可上传对象。普通文件只有重复 size 组会在 Phase 1 计算 SHA；图片高清层和视频 Raw 候选会计算 SHA。"
        }
        let ordinary = uploadable.filter { $0.objectType == .ordinaryFile }.count
        let image = uploadable.filter { $0.objectType == .imageHighLayer }.count
        let video = uploadable.filter { $0.objectType == .videoRawLayer }.count
        let uniqueObjects = Dictionary(grouping: uploadable, by: { $0.sha256 ?? $0.path }).values.compactMap(\.first)
        let uniqueBytes = uniqueObjects.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "将上传本次扫描中已有 SHA 且可归档的对象：普通文件 \(ordinary) 项、图片高清层 \(image) 项、视频 Raw 层 \(video) 项；按 SHA 去重后云端对象 \(uniqueObjects.count) 个，约 \(humanBytes(uniqueBytes))。不会上传无 SHA、不可归档项，也不会移动或删除本地文件。"
    }

    func scan() {
        guard let selectedRoot else { return }
        isScanning = true
        alertMessage = nil
        let threshold = Int64(largeFileThresholdMB * 1024 * 1024)

        Task {
            do {
                let scanResult = try await Task.detached(priority: .userInitiated) {
                    let scanner = WeChatScanner()
                    let result = try scanner.scan(root: selectedRoot, options: ScanOptions(largeFileThresholdBytes: threshold))
                    let store = try ManifestStore()
                    try store.save(scanResult: result)
                    let snapshots = try store.cloudArchiveSnapshots()
                    return (result, snapshots)
                }.value
                result = scanResult.0
                cloudSnapshots = scanResult.1
            } catch {
                alertMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    func uploadHashedCandidates() {
        guard let files = result?.files else { return }
        isUploading = true
        alertMessage = nil
        uploadMessage = "准备上传：\(uploadableFiles(from: files).count) 项绑定"
        let config = storageConfig

        Task {
            do {
                let service = CloudUploadService()
                let snapshots = try await service.upload(files: files, families: result?.families ?? [], config: config, store: ManifestStore()) { [weak self] progress in
                    await MainActor.run {
                        self?.apply(progress)
                    }
                }
                cloudSnapshots = snapshots
                uploadMessage = "上传完成：已校验 \(snapshots.values.filter { $0.object.verifyStatus == .verified }.count) 项绑定"
            } catch {
                alertMessage = error.localizedDescription
            }
            isUploading = false
        }
    }

    func cloudStatus(for file: FileRecord) -> String {
        if let snapshot = cloudSnapshots[file.path] {
            return snapshot.object.verifyStatus.rawValue
        }
        if file.sha256 == nil {
            return "无 SHA"
        }
        if file.status == .notArchivable {
            return "不可归档"
        }
        return "未上传"
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
        files.filter { $0.sha256 != nil && $0.status != .notArchivable }
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

private extension ArchiveObjectType {
    var displayName: String {
        switch self {
        case .ordinaryFile: "普通文件"
        case .imageHighLayer: "图片高清层"
        case .videoRawLayer: "视频 Raw 层"
        }
    }
}
