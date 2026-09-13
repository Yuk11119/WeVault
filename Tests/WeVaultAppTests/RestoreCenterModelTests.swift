import Foundation
import Testing
import WeVaultCore
@testable import WeVaultApp

@Suite("Restore window state")
@MainActor
struct RestoreCenterModelTests {
    @Test("filename search spans archive pages and keeps selection")
    func filenameSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ManifestStore(databaseURL: directory.appendingPathComponent("archive.sqlite"), keyProvider: InMemoryManifestKeyProvider())
        for i in 0..<105 {
            let name = i < 52 ? "报告-Report-\(i).pdf" : "Other-\(i).txt"
            let file = ArchivedFile(filePath: "/fixture/\(name)", objectType: .ordinaryFile, originalFilename: name, relativePath: name, accountHash: "fixture", accountName: "fixture", month: nil, sizeBytes: 1, sha256: "sha", mtime: Date(), familyID: nil, displayOrPlaybackPath: nil, bubbleOrThumbPath: nil, archivedAt: Date(timeIntervalSince1970: Double(i)), updatedAt: Date())
            let object = CloudObject(cloudObjectID: "object", sha256: "sha", sizeBytes: 1, storageProvider: "fixture", bucketOrContainer: "fixture", objectKey: "fixture", uploadedAt: Date(), verifiedAt: Date(), verifyStatus: .verified, refCount: 1)
            try store.saveCloudObject(object, binding: ArchiveBinding(bindingID: "binding-\(i)", filePath: file.filePath, cloudObjectID: "object", archiveState: .verified, localState: .localReleased), archivedFile: file)
        }
        let model = RestoreCenterModel { store }
        model.load(bindingID: "binding-0")
        model.search = "  report  "
        model.load()
        #expect(model.records.count == 50)
        #expect(model.hasNext)
        #expect(model.records.allSatisfy { $0.archivedFile.originalFilename.contains("报告") })
        model.offset = 50; model.load()
        #expect(model.records.count == 2)
        #expect(!model.hasNext)
        #expect(model.selected?.binding.bindingID == "binding-0")
        model.search = "no match"; model.offset = 0; model.load()
        #expect(model.records.isEmpty)
        model.search = ""; model.load()
        #expect(model.records.count == 50)
    }

    @Test("selection survives reload and repeated links without a scan root")
    func selectionSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeVaultWindow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ManifestStore(databaseURL: directory.appendingPathComponent("archive.sqlite"), keyProvider: InMemoryManifestKeyProvider())
        let id = "binding-" + String(repeating: "a", count: 64)
        let sha = String(repeating: "b", count: 64)
        let file = ArchivedFile(filePath: "/missing/saved.pdf", objectType: .ordinaryFile, originalFilename: "saved.pdf", relativePath: "saved.pdf", accountHash: "synthetic", accountName: "synthetic", month: "2026-09", sizeBytes: 1, sha256: sha, mtime: Date(), familyID: nil, displayOrPlaybackPath: nil, bubbleOrThumbPath: nil, archivedAt: Date(), updatedAt: Date())
        let object = CloudObject(cloudObjectID: "object", sha256: sha, sizeBytes: 1, storageProvider: "synthetic", bucketOrContainer: "synthetic", objectKey: "synthetic", uploadedAt: Date(), verifiedAt: Date(), verifyStatus: .verified, refCount: 1)
        let binding = ArchiveBinding(bindingID: id, filePath: file.filePath, cloudObjectID: object.cloudObjectID, archiveState: .verified, localState: .localReleased)
        try store.saveCloudObject(object, binding: binding, archivedFile: file)
        let model = RestoreCenterModel { store }
        model.load(bindingID: id)
        #expect(model.selected?.binding.bindingID == id)
        let account = ManagedAccount(api: WeVaultAPIClient(baseURL: URL(string: "https://example.invalid")!, transport: RestoreLoginTransport()), memoryOnly: true)
        do {
            try await account.login(email: "fixture@example.invalid", password: "synthetic", displayName: "Fixture")
            Issue.record("First login should fail")
        } catch {
            #expect(!account.isReady)
        }
        model.load()
        #expect(model.selected?.binding.bindingID == id)
        try await account.login(email: "fixture@example.invalid", password: "synthetic", displayName: "Fixture")
        #expect(account.isReady)
        #expect(try await account.withAuthorizedDevice().deviceID == "fixture-device")
        model.load()
        #expect(model.selected?.binding.bindingID == id)
        model.load()
        #expect(model.selected?.binding.bindingID == id)
        model.lookup = "wevault://restore/\(id)?OR=PowerPoint"
        model.find()
        #expect(model.selected?.binding.bindingID == id)
        #expect(model.error == nil)
        for text in ["binding-\n" + String(repeating: "a", count: 64), "wevault://restore/binding%02" + String(repeating: "a", count: 64), try RestoreLink(bindingID: id).browserURL.absoluteString] {
            model.lookup = text
            model.find()
            #expect(model.selected?.binding.bindingID == id)
            #expect(model.error == nil)
        }
        model.lookup = "wevault://restore/\(id)?path=other"
        model.find()
        #expect(model.selected == nil)
        #expect(model.error != nil)
        model.load()
        #expect(model.selected == nil)
        model.load(bindingID: id)
        model.load(bindingID: "binding-" + String(repeating: "c", count: 32))
        #expect(model.selected == nil)
        #expect(model.error != nil)
    }

    @Test("temporary configuration validates before replacing the previous configuration")
    func temporaryConfiguration() throws {
        let cloud = SelfManagedCloud(memoryOnly: true)
        let config = SelfManagedTemporaryConfig(endpoint: "https://example.invalid", bucket: "fixture", region: "fixture", accessKeyID: "synthetic", secretAccessKey: "synthetic", securityToken: "synthetic", expiration: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))
        try cloud.save(config)
        var expired = config
        expired.expiration = "2000-01-01T00:00:00Z"
        #expect(throws: (any Error).self) { try cloud.save(expired) }
        #expect(cloud.configuration == config)
        #expect(SelfManagedCloud(memoryOnly: true).configuration == nil)
    }

    @Test("key and integrity failures show explicit errors rather than successful empty lists")
    func failures() {
        for failure in [ManifestFailure.keychainUnavailable, .keyMissing, .sqliteCorrupt, .missingNeedsCloudIndexFallback] {
            let model = RestoreCenterModel { throw WeVaultError.manifest(failure) }
            model.load()
            #expect(model.error != nil)
            #expect(model.records.isEmpty)
            #expect(model.selected == nil)
            #expect(!model.hasNext)
        }
    }
}

private actor RestoreLoginTransport: WeVaultAPITransport {
    private var attempts = 0
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let status: Int
        let body: String
        switch request.url!.path {
        case "/v1/auth/login":
            attempts += 1
            status = attempts == 1 ? 401 : 200
            body = attempts == 1 ? #"{"error":{"code":"INVALID_CREDENTIALS","message":"Fixture rejection"}}"# : #"{"accessToken":"synthetic","refreshToken":"synthetic","expiresIn":3600}"#
        case "/v1/devices":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
            status = 200
            body = #"{"deviceId":"fixture-device"}"#
        default:
            throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
