import SwiftUI
import AppKit
import WeVaultCore

@MainActor
final class RestoreCenterModel: ObservableObject {
    @Published var records: [ArchivedFileSnapshot] = []
    @Published var selected: ArchivedFileSnapshot?
    @Published var error: String?
    @Published var lookup = ""
    @Published var search = ""
    @Published var offset = 0
    @Published var hasNext = false
    private var selectedID: String?
    private let storeFactory: () throws -> ManifestStore

    init(storeFactory: @escaping () throws -> ManifestStore = { try ManifestStore() }) {
        self.storeFactory = storeFactory
    }

    func load(bindingID: String? = nil) {
        if let bindingID { selectedID = bindingID; lookup = bindingID }
        error = nil
        do {
            let store = try storeFactory()
            let page = try store.archivedFilePage(limit: 51, offset: offset, search: search)
            records = Array(page.prefix(50)); hasNext = page.count > 50
            if let selectedID {
                selected = try store.archivedFileSnapshot(bindingID: selectedID)
                if selected == nil { error = "未找到此归档记录。请确认使用归档时的 Mac 和本地索引；云端对象索引无法重建原路径。" }
            }
        } catch {
            selected = nil; records = []; hasNext = false
            self.error = "无法读取归档索引：\(UserFacingFailure.describe(error).description)"
        }
    }

    func rejectLink(_ message: String) {
        selectedID = nil; selected = nil; error = message
    }

    func find() {
        do {
            let link = try RestoreLink(lookupText: lookup)
            load(bindingID: link.bindingID)
        } catch { rejectLink(UserFacingFailure.describe(error).description) }
    }
}

struct RestoreCenterView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: RestoreCenterModel
    @ObservedObject var operations: ScanViewModel
    @StateObject private var preview = ArchivePreviewModel()
    @State private var previewTask: Task<Void, Never>?
    @State private var selectedBindingID: String?
    @State private var showSettings = false
    @State private var confirmOriginal = false
    @State private var pendingOriginal: ArchivedFileSnapshot?

    private var busy: Bool { operations.isRestoring || operations.isReleasing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("恢复中心").font(.title.bold())
                Spacer()
                Button("设置") { showSettings = true }
                Button("刷新") { model.load() }.disabled(busy)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文件名", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .task(id: model.search) {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                model.offset = 0
                model.load()
            }
            DisclosureGroup("使用恢复链接") {
                HStack {
                    TextField("粘贴恢复链接或归档编号", text: $model.lookup).onSubmit { model.find() }
                    Button("查找") { model.find() }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                VStack {
                    List(model.records, id: \.binding.bindingID, selection: $selectedBindingID) { record in
                            VStack(alignment: .leading) {
                                Text(record.archivedFile.originalFilename).lineLimit(1)
                                Text("\(record.archivedFile.objectType.displayName) · \(humanBytes(record.archivedFile.sizeBytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .tag(record.binding.bindingID)
                    }
                    if model.records.isEmpty && model.error == nil {
                        Text(model.search.isEmpty ? "暂无归档文件" : "没有找到匹配的文件")
                            .foregroundStyle(.secondary).padding()
                    }
                    HStack {
                        Button("上一页") { model.offset = max(0, model.offset - 50); model.load() }.disabled(model.offset == 0)
                        Text("第 \(model.offset / 50 + 1) 页")
                        Button("下一页") { model.offset += 50; model.load() }.disabled(!model.hasNext)
                    }
                }.frame(minWidth: 250, idealWidth: 310, maxWidth: 360)
                ScrollView {
                    if let record = model.selected {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(record.archivedFile.originalFilename).font(.title2.bold()).textSelection(.enabled)
                            Text("\(record.archivedFile.objectType.displayName) · \(humanBytes(record.archivedFile.sizeBytes))")
                            Text("归档状态：\(archiveLabel(record.binding.archiveState))\n微信原路径状态：\(localLabel(record.binding.localState))")
                            previewSection(record)

                            Button(record.archivedFile.objectType == .ordinaryFile ? "恢复到下载目录" : "恢复到微信原路径") {
                                if record.archivedFile.objectType == .ordinaryFile { restore(record, to: .defaultDownloads) }
                                else { requestOriginal(record) }
                            }.buttonStyle(.borderedProminent).disabled(busy || record.object.verifyStatus != .verified)
                            HStack {
                                if record.archivedFile.objectType != .ordinaryFile {
                                    Button("恢复到下载目录") { restore(record, to: .defaultDownloads) }
                                } else {
                                    Button("恢复到微信原位置") { requestOriginal(record) }
                                }
                                Button("选择目录恢复") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseFiles = false; panel.canChooseDirectories = true
                                    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
                                    panel.directoryURL = CloudRestoreService.defaultRestoreDirectory()
                                    if panel.runModal() == .OK, let url = panel.url { restore(record, to: .directory(url)) }
                                }
                            }.disabled(busy || record.object.verifyStatus != .verified)
                            DisclosureGroup("文件详情") {
                                Text(record.archivedFile.filePath).font(.caption).textSelection(.enabled)
                                Text("SHA-256：\(record.archivedFile.sha256)\n\(record.binding.bindingID)").textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    } else {
                        ContentUnavailableView("选择归档记录", systemImage: "archivebox", description: Text("选择文件，预览内容后恢复。"))
                    }
                }.frame(minWidth: 400)
            }
            if operations.isRestoring { ProgressView("正在恢复并校验…") }
            if !operations.restoreMessage.isEmpty { Text(operations.restoreMessage).textSelection(.enabled).font(.callout) }
        }.padding(20).frame(minWidth: 780, minHeight: 520)
        .onChange(of: selectedBindingID) { _, id in
            if let id, id != model.selected?.binding.bindingID { model.load(bindingID: id) }
        }
        .task(id: model.selected?.binding.bindingID) {
            selectedBindingID = model.selected?.binding.bindingID
            previewTask?.cancel()
            confirmOriginal = false; pendingOriginal = nil
            if let record = model.selected { await preview.loadLocal(record) }
            else { preview.clear() }
        }
        .onDisappear { previewTask?.cancel(); preview.clear() }
        .onChange(of: operations.isRestoring) { _, running in if !running { model.load() } }
        .sheet(isPresented: $showSettings, onDismiss: { model.load() }) {
            SettingsSheet(settings: appState.settings, managedAccount: appState.managedAccount, selfManagedCloud: appState.selfManagedCloud, onSave: appState.save)
        }
        .alert("恢复到微信原路径", isPresented: $confirmOriginal) {
            Button("取消", role: .cancel) { pendingOriginal = nil }
            Button("确认恢复") { if let record = pendingOriginal { restore(record, to: .originalPath) }; pendingOriginal = nil }
        } message: {
            Text("将恢复：\(pendingOriginal?.archivedFile.originalFilename ?? "")\n微信运行时写回可能影响当前文件访问，建议暂时停止相关操作。仅允许写入空路径或替换绑定与 SHA 匹配的 WeVault 占位文件，其他文件不会被覆盖。")
        }
    }

    @ViewBuilder
    private func previewSection(_ record: ArchivedFileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = preview.url {
                ArchiveQuickLook(url: url).frame(height: 280)
            } else if preview.isLoading {
                ProgressView("正在准备预览…").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Image(systemName: "doc.richtext").font(.system(size: 40)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
            Text(preview.message).font(.caption).foregroundStyle(.secondary)
            if preview.url == nil && !record.archivedFile.originalFilename.lowercased().hasSuffix(".dat") {
                Button("下载预览 · \(humanBytes(record.archivedFile.sizeBytes))") {
                    previewTask = Task { await preview.download(record, account: appState.managedAccount, cloud: appState.selfManagedCloud) }
                }.disabled(preview.isLoading || busy || record.object.verifyStatus != .verified)
            }
        }
    }

    private func archiveLabel(_ state: ArchiveBindingState) -> String {
        switch state {
        case .verified: return "云端已校验"
        case .restored: return "已完成恢复校验"
        case .localReleased: return "原件已归档"
        case .restorePending: return operations.isRestoring ? "恢复中" : "上次恢复中断，可重试"
        case .restoreFailed: return "上次恢复失败，可重试"
        default: return "尚未完成校验"
        }
    }

    private func localLabel(_ state: LocalArchiveState) -> String {
        switch state {
        case .localPresent: return "本地原件保留"
        case .tombstoned: return "原路径为占位提示"
        case .quarantined: return "原件在暂存区"
        case .localReleased: return "本地原件已释放"
        case .restored: return "已恢复原件"
        case .restoreFailed, .releaseFailed: return "需要重新检查本地状态"
        }
    }

    private func requestOriginal(_ record: ArchivedFileSnapshot) { pendingOriginal = record; confirmOriginal = true }
    private func restore(_ record: ArchivedFileSnapshot, to destination: RestoreDestination) {
        operations.restore(snapshot: record, destination: destination, managedAccount: appState.managedAccount, selfManagedCloud: appState.selfManagedCloud)
    }
}
