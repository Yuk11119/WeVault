import Foundation
import Testing
@testable import WeVaultCore

private actor StubTransport: WeVaultAPITransport {
    let response: (Data, URLResponse)
    init(status: Int, body: String) {
        response = (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://api.example.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) { response }
}

private actor SequenceTransport: WeVaultAPITransport {
    private var responses: [(Int, String)]
    private(set) var paths: [String] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url!.path)
        let next = responses.removeFirst()
        return (Data(next.1.utf8), HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: nil)!)
    }
    func requestedPaths() -> [String] { paths }
}

private struct OfflineTransport: WeVaultAPITransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
}

private actor RecordingStorage: ObjectStorageClient {
    private(set) var uploaded: [(String, String, Int64)] = []
    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws { uploaded.append((objectKey, sha256, sizeBytes)) }
    func headObject(objectKey: String) async throws -> StoredObjectHead { StoredObjectHead(sizeBytes: 0) }
    func getObject(objectKey: String, destinationURL: URL) async throws {}
    func uploadCount() -> Int { uploaded.count }
}

private struct RecordingStorageFactory: ManagedWeVaultStorageClientFactory {
    let storage: RecordingStorage
    func makeClient(credentials: WeVaultTemporaryCredentials) -> any ObjectStorageClient { storage }
}

private struct RejectingStorageFactory: ManagedWeVaultStorageClientFactory {
    func makeClient(credentials: WeVaultTemporaryCredentials) -> any ObjectStorageClient { RejectingStorage() }
}

private struct RejectingStorage: ObjectStorageClient {
    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws { throw WeVaultAPIFailure(code: "OSS_SCOPE_DENIED", statusCode: 403, message: "STS scope rejected upload") }
    func headObject(objectKey: String) async throws -> StoredObjectHead { StoredObjectHead(sizeBytes: 0) }
    func getObject(objectKey: String, destinationURL: URL) async throws {}
}

private struct UploadAuthorizationEnvelope: Codable {
    let authorizationId: String
    let credentials: WeVaultTemporaryCredentials
}

private func jsonString(_ value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

@Suite("managed cloud P2A contract") struct ManagedWeVaultCloudTests {
    @Test("API failures are stable and cannot enter a release path")
    func apiFailureIsReportedWithoutLocalMutation() async throws {
        let client = WeVaultAPIClient(baseURL: URL(string: "https://api.example.test")!, transport: StubTransport(status: 403, body: #"{"error":{"code":"AUTH_SCOPE_DENIED","message":"denied"}}"#))
        do {
            _ = try await client.uploadAuthorization(accessToken: "test", deviceId: UUID().uuidString, sha256: String(repeating: "a", count: 64), sizeBytes: 1)
            Issue.record("expected a scope failure")
        } catch let error as WeVaultAPIFailure {
            #expect(error.code == "AUTH_SCOPE_DENIED")
            #expect(error.statusCode == 403)
        }
    }

    @Test("fallback hit blocks a new upload before credentials are requested")
    func fallbackHitDoesNotMutateTheLocalFile() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("unchanged".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let body = #"{"objects":[{"objectId":"obj","sha256":""# + String(repeating: "a", count: 64) + #"","sizeBytes":9,"verifiedAt":"2026-08-29T00:00:00Z"}]}"#
        let client = WeVaultAPIClient(baseURL: URL(string: "https://api.example.test")!, transport: StubTransport(status: 200, body: body))
        let result = try await ManagedCloudContractPipeline.upload(api: client, accessToken: "test", deviceId: UUID().uuidString, fileURL: temporary)
        guard case .fallbackFound = result else { Issue.record("expected fallback outcome"); return }
        #expect(try String(contentsOf: temporary) == "unchanged")
    }

    @Test("managed upload uses one STS client then completes without manifest or release mutation")
    func managedUploadUsesTemporaryCredentialsAndCompletes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("managed-object".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let sha = try sha256File(file)
        let authID = UUID().uuidString
        let deviceID = UUID().uuidString
        let credentials = WeVaultTemporaryCredentials(accessKeyId: "short-id", accessKeySecret: "short-secret", securityToken: "short-token", expiration: "2030-01-01T00:00:00Z", endpoint: "https://oss.example.test", bucket: "private-bucket", region: "cn-hangzhou", objectKey: "users/u/devices/d/objects/sha256/\(sha.prefix(2))/\(sha.dropFirst(2).prefix(2))/\(sha)")
        let transport = SequenceTransport([
            (200, #"{"objects":[]}"#),
            (200, try jsonString(UploadAuthorizationEnvelope(authorizationId: authID, credentials: credentials))),
            (200, #"{"status":"VERIFIED"}"#)
        ])
        let storage = RecordingStorage()
        let result = try await ManagedCloudContractPipeline.upload(
            api: WeVaultAPIClient(baseURL: URL(string: "https://api.example.test")!, transport: transport),
            accessToken: "access", deviceId: deviceID, fileURL: file,
            storageFactory: RecordingStorageFactory(storage: storage)
        )
        guard case let .verified(authorization) = result else { Issue.record("expected verified outcome"); return }
        #expect(authorization.authorizationId == authID)
        #expect(await storage.uploadCount() == 1)
        #expect(await transport.requestedPaths() == ["/v1/objects", "/v1/objects/upload-authorizations", "/v1/objects/\(authID)/complete"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file) == "managed-object")
    }

    @Test("expired STS never uploads or changes the local file")
    func expiredSTSPreservesLocalFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep-me".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let sha = try sha256File(file)
        let authID = UUID().uuidString
        let expired = WeVaultTemporaryCredentials(accessKeyId: "a", accessKeySecret: "b", securityToken: "c", expiration: "2020-01-01T00:00:00Z", endpoint: "https://oss.example.test", bucket: "private-bucket", region: "cn-hangzhou", objectKey: "users/u/devices/d/objects/sha256/\(sha.prefix(2))/\(sha.dropFirst(2).prefix(2))/\(sha)")
        let transport = SequenceTransport([(200, #"{"objects":[]}"#), (200, try jsonString(UploadAuthorizationEnvelope(authorizationId: authID, credentials: expired)))])
        let storage = RecordingStorage()
        do {
            _ = try await ManagedCloudContractPipeline.upload(api: WeVaultAPIClient(baseURL: URL(string: "https://api.example.test")!, transport: transport), accessToken: "access", deviceId: UUID().uuidString, fileURL: file, storageFactory: RecordingStorageFactory(storage: storage))
            Issue.record("expected expired STS failure")
        } catch let error as WeVaultAPIFailure { #expect(error.code == "STS_EXPIRED") }
        #expect(await storage.uploadCount() == 0)
        #expect(try String(contentsOf: file) == "keep-me")
    }

    @Test("STS scope and server complete failures preserve the local source")
    func managedFailuresNeverRemoveTheLocalSource() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("never-release".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let sha = try sha256File(file)
        let authorization = WeVaultTemporaryCredentials(accessKeyId: "a", accessKeySecret: "b", securityToken: "c", expiration: "2030-01-01T00:00:00Z", endpoint: "https://oss.example.test", bucket: "private-bucket", region: "cn-hangzhou", objectKey: "users/u/devices/d/objects/sha256/\(sha.prefix(2))/\(sha.dropFirst(2).prefix(2))/\(sha)")
        let scopeTransport = SequenceTransport([(200, #"{"objects":[]}"#), (200, try jsonString(UploadAuthorizationEnvelope(authorizationId: UUID().uuidString, credentials: authorization)))])
        do {
            _ = try await ManagedCloudContractPipeline.upload(api: WeVaultAPIClient(baseURL: URL(string: "https://api.example.test")!, transport: scopeTransport), accessToken: "access", deviceId: UUID().uuidString, fileURL: file, storageFactory: RejectingStorageFactory())
            Issue.record("expected STS scope failure")
        } catch let error as WeVaultAPIFailure { #expect(error.code == "OSS_SCOPE_DENIED") }
        #expect(try String(contentsOf: file) == "never-release")

        let completeTransport = SequenceTransport([
            (200, #"{"objects":[]}"#),
            (200, try jsonString(UploadAuthorizationEnvelope(authorizationId: UUID().uuidString, credentials: authorization))),
            (502, #"{"error":{"code":"CLOUD_VERIFY_FAILED","message":"metadata mismatch"}}"#)
        ])
        do {
            _ = try await ManagedCloudContractPipeline.upload(api: WeVaultAPIClient(baseURL: URL(string: "https://api.example.test")!, transport: completeTransport), accessToken: "access", deviceId: UUID().uuidString, fileURL: file, storageFactory: RecordingStorageFactory(storage: RecordingStorage()))
            Issue.record("expected server complete failure")
        } catch let error as WeVaultAPIFailure { #expect(error.code == "CLOUD_VERIFY_FAILED") }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file) == "never-release")
    }

    @Test("network failure before fallback preserves the local source")
    func networkFailurePreservesLocalFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("offline-source".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await CloudUploadService().uploadManagedContract(
                api: WeVaultAPIClient(baseURL: URL(string: "https://api.example.test")!, transport: OfflineTransport()),
                accessToken: "access", deviceId: UUID().uuidString, fileURL: file
            )
            Issue.record("expected offline error")
        } catch is URLError {}
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file) == "offline-source")
    }
}
