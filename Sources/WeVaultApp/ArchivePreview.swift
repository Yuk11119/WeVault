import AppKit
import Quartz
import SwiftUI
import WeVaultCore

/// Preview copies have their own lifetime and never update archive/restore state.
@MainActor
final class ArchivePreviewModel: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var message = ""
    private var generation = UUID()
    private var directory: URL?

    func clear() {
        generation = UUID()
        url = nil
        isLoading = false
        message = ""
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    nonisolated static func localCandidates(_ record: ArchivedFileSnapshot) -> [(URL, Bool)] {
        var paths: [(URL, Bool)] = []
        if [.localPresent, .restored].contains(record.binding.localState) {
            paths.append((URL(fileURLWithPath: record.archivedFile.filePath), true))
        }
        if let path = record.binding.quarantinePath { paths.append((URL(fileURLWithPath: path), true)) }
        if let path = record.archivedFile.displayOrPlaybackPath { paths.append((URL(fileURLWithPath: path), false)) }
        if let path = record.archivedFile.bubbleOrThumbPath { paths.append((URL(fileURLWithPath: path), false)) }
        return paths
    }

    func loadLocal(_ record: ArchivedFileSnapshot) async {
        clear()
        let token = generation
        isLoading = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WeVault-Preview-\(UUID().uuidString)", isDirectory: true)
        let worker = Task.detached(priority: .utility) { () -> (URL, Bool)? in
            for (source, original) in Self.localCandidates(record) {
                let name = original ? URL(fileURLWithPath: record.archivedFile.originalFilename).lastPathComponent : source.lastPathComponent
                guard FileManager.default.isReadableFile(atPath: source.path), URL(fileURLWithPath: name).pathExtension.lowercased() != "dat" else { continue }
                do {
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: source, to: target)
                    if original {
                        guard try ArchivePreviewValidation.matches(target, file: record.archivedFile) else {
                            try? FileManager.default.removeItem(at: target)
                            continue
                        }
                    }
                    return (target, original)
                } catch { continue }
            }
            return nil
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard token == generation, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        isLoading = false
        if let (target, original) = result {
            directory = folder; url = target
            message = original ? "本地原件" : "本地保留的预览版本"
        } else {
            try? FileManager.default.removeItem(at: folder)
            message = record.archivedFile.originalFilename.lowercased().hasSuffix(".dat")
                ? "微信加密图片暂不支持内容预览，可恢复后在微信查看。"
                : "本地没有可预览的副本。"
        }
    }

    func download(_ record: ArchivedFileSnapshot, account: ManagedAccount, cloud: SelfManagedCloud) async {
        guard !isLoading else { return }
        let token = generation
        isLoading = true
        message = "正在下载预览…"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WeVault-Preview-\(UUID().uuidString)", isDirectory: true)
        do {
            guard record.object.verifyStatus == .verified,
                  record.binding.cloudObjectID == record.object.cloudObjectID,
                  record.object.sha256 == record.archivedFile.sha256,
                  record.object.sizeBytes == record.archivedFile.sizeBytes else {
                throw WeVaultError.cloud("归档尚未通过校验")
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = URL(fileURLWithPath: record.archivedFile.originalFilename).lastPathComponent
            let target = folder.appendingPathComponent(filename)
            if record.object.storageProvider == "WeVault Managed Cloud" {
                let auth = try await account.withAuthorizedDevice()
                try await ManagedCloudContractPipeline.download(api: auth.api, accessToken: auth.accessToken,
                    deviceId: auth.deviceID, objectId: record.object.cloudObjectID, destinationURL: target)
            } else {
                let config = try cloud.storageConfig()
                guard config.provider == record.object.storageProvider, config.bucket == record.object.bucketOrContainer else {
                    throw WeVaultError.cloud("请连接归档时使用的云存储")
                }
                try await S3CompatibleObjectStorageClient(config: config).getObject(objectKey: record.object.objectKey, destinationURL: target)
            }
            let valid = try await Task.detached(priority: .utility) {
                try ArchivePreviewValidation.matches(target, file: record.archivedFile)
            }.value
            guard valid else { throw WeVaultError.cloud("预览文件校验失败，请重试") }
            guard token == generation, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            directory = folder; url = target; message = "云端原件预览"
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if token == generation { message = "预览失败：\(UserFacingFailure.describe(error).description)" }
        }
        if token == generation { isLoading = false }
    }
}

/// Owns Quick Look's terminal close state separately from SwiftUI's reusable host.
@MainActor
final class ArchivePreviewHostView: NSView {
    private(set) var preview: QLPreviewView?
    private var currentURL: URL?

    func display(_ url: URL) {
        if preview == nil {
            guard let view = QLPreviewView(frame: bounds, style: .normal) else { return }
            // The restore NSWindow is retained and reopened. Quick Look's default
            // closes itself permanently on window close, making the next update abort.
            view.shouldCloseWithWindow = false
            view.autostarts = false
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            preview = view
        }
        guard currentURL != url else { return }
        preview?.previewItem = url as NSURL
        currentURL = url
    }

    func closePreview() {
        // Detach before closing; subsequent updates must create a fresh QLPreviewView.
        let old = preview
        preview = nil
        currentURL = nil
        old?.removeFromSuperview()
        old?.close()
    }
}

struct ArchiveQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> ArchivePreviewHostView {
        let host = ArchivePreviewHostView()
        host.display(url)
        return host
    }
    func updateNSView(_ view: ArchivePreviewHostView, context: Context) { view.display(url) }
    static func dismantleNSView(_ view: ArchivePreviewHostView, coordinator: ()) { view.closePreview() }
}
