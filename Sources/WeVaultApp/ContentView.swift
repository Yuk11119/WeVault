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
            DetailView(file: selectedFile, families: viewModel.result?.families ?? [])
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

                if let result = viewModel.result {
                    SummaryGrid(summary: result.summary)
                    Text("Manifest: \(viewModel.manifestURL.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Text("本 demo 不上传、不释放、不移动微信文件，不修改微信数据库。")
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
                }
                .frame(minWidth: 914)
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

    let manifestURL = ManifestStore.defaultDatabaseURL()

    init() {
        selectedRoot = WeChatDirectory.defaultXWeChatFilesURL()
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
                    return result
                }.value
                result = scanResult
            } catch {
                alertMessage = error.localizedDescription
            }
            isScanning = false
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

private extension ArchiveObjectType {
    var displayName: String {
        switch self {
        case .ordinaryFile: "普通文件"
        case .imageHighLayer: "图片高清层"
        case .videoRawLayer: "视频 Raw 层"
        }
    }
}
