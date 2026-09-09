import Foundation
import Testing
@testable import WeVaultCore

@Suite("P7 cloud failure recovery")
struct P7CloudTests {
    @Test("cached ownership cannot bypass fresh remote verification before release", arguments: [false, true])
    func remoteCheck(mismatch: Bool) async throws {
        let f = try BetaFixture(); defer { f.remove() }
        try f.write("file.txt", "payload")
        let file = try #require(try WeChatScanner().scan(root: f.root, options: ScanOptions(largeFileThresholdBytes: 1)).files.first)
        try f.save(file, store: f.store)
        let snapshot = try #require(try f.store.archivedSnapshot(path: file.path))
        try f.store.workPut(scope: "managed-binding-owner", key: snapshot.binding.bindingID, value: "device")
        let transport = BetaCloudTransport(snapshot: snapshot)
        let storage = BetaHeadStorage(size: file.sizeBytes, sha: mismatch ? "wrong" : file.sha256!)
        let service = ManagedCloudArchiveService()
        let api = WeVaultAPIClient(baseURL: URL(string: "https://fixture.invalid")!, transport: transport)
        if mismatch {
            await #expect(throws: WeVaultError.self) {
                _ = try await service.isAuthorizedArchive(snapshot, api: api, accessToken: "fixture", deviceID: "device", store: f.store, storageFactory: BetaHeadFactory(storage: storage))
            }
        } else {
            #expect(try await service.isAuthorizedArchive(snapshot, api: api, accessToken: "fixture", deviceID: "device", store: f.store, storageFactory: BetaHeadFactory(storage: storage)))
        }
        #expect(await transport.count == 2)
        #expect(await storage.count == 1)
        #expect(try sha256File(URL(fileURLWithPath: file.path)) == file.sha256)
        #expect(try f.store.archivedSnapshot(path: file.path)?.binding.localState == .localPresent)
    }

    @Test("cloud outage at release authorization keeps quarantine intact")
    func unavailableBeforeFinalization() async throws {
        let f = try BetaFixture(); defer { f.remove() }
        try f.write("file.txt", String(repeating: "x", count: 1_048_576))
        let file = try #require(try WeChatScanner().scan(root: f.root, options: ScanOptions(largeFileThresholdBytes: 1)).files.first)
        try f.save(file, store: f.store, provider: "WeVault Managed Cloud")
        let snapshot = try #require(try f.store.archivedSnapshot(path: file.path))
        let release = LocalReleaseService(quarantineRoot: f.base.appendingPathComponent("quarantine"))
        _ = try release.isolate(snapshot: snapshot, store: f.store, authorization: .manual(confirmed: true, skipRestoreTest: true))
        let current = try #require(try f.store.archivedSnapshot(path: file.path))
        let path = try #require(current.binding.quarantinePath)
        let future = Date().addingTimeInterval(30 * 86_400)
        await #expect(throws: URLError.self) {
            _ = try await AutomaticArchivePipeline(store: f.store, releaseService: release, now: { future }).run(root: f.root, settings: ProductSettings(largeFileThresholdMB: 1), authorizeArchive: { _, _ in throw URLError(.notConnectedToInternet) }) { _, _, _ in
                ManagedCloudUploadReport(snapshots: [:], attemptedCount: 0, verifiedCount: 0, failures: [])
            }
        }
        #expect(try sha256File(URL(fileURLWithPath: path)) == file.sha256)
    }
}

private actor BetaCloudTransport: WeVaultAPITransport {
    let snapshot: ArchivedFileSnapshot
    private(set) var count = 0
    init(snapshot: ArchivedFileSnapshot) { self.snapshot = snapshot }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        let data: Data
        if request.httpMethod == "POST" {
            let credentials = WeVaultTemporaryCredentials(accessKeyId: "fixture", accessKeySecret: "fixture", securityToken: "fixture", expiration: "2099-01-01T00:00:00Z", endpoint: "https://fixture.invalid", bucket: "fixture", region: "fixture", objectKey: "fixture")
            data = try JSONEncoder().encode(Envelope(authorizationId: "fixture", credentials: credentials))
        } else {
            data = try JSONSerialization.data(withJSONObject: ["objects": [["objectId": snapshot.object.cloudObjectID, "sha256": snapshot.archivedFile.sha256, "sizeBytes": snapshot.archivedFile.sizeBytes, "verifiedAt": "2026-01-01T00:00:00Z"]]])
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    private struct Envelope: Encodable { let authorizationId: String; let credentials: WeVaultTemporaryCredentials }
}

private struct BetaHeadFactory: ManagedWeVaultStorageClientFactory {
    let storage: BetaHeadStorage
    func makeClient(credentials: WeVaultTemporaryCredentials) -> any ObjectStorageClient { storage }
}

private actor BetaHeadStorage: ObjectStorageClient {
    let size: Int64, sha: String
    private(set) var count = 0
    init(size: Int64, sha: String) { self.size = size; self.sha = sha }
    func headObject(objectKey: String) async throws -> StoredObjectHead { count += 1; return StoredObjectHead(sizeBytes: size, metadata: ["sha256": sha]) }
    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws { Issue.record("release check must not upload") }
    func getObject(objectKey: String, destinationURL: URL) async throws { Issue.record("release check must not download file contents") }
}
