import Foundation

/// P2A contract-only client for the managed WeVault service.  It deliberately
/// has no dependency on product settings or local-release APIs.
public struct WeVaultAPIFailure: Error, Equatable, Sendable, LocalizedError {
    public let code: String
    public let statusCode: Int
    public let message: String
    public init(code: String, statusCode: Int, message: String) { self.code = code; self.statusCode = statusCode; self.message = message }
    public var errorDescription: String? { "\(code): \(message)" }
}

public struct WeVaultSession: Codable, Equatable, Sendable { public let accessToken: String; public let refreshToken: String; public let expiresIn: Int }
public struct WeVaultDevice: Codable, Equatable, Sendable { public let deviceId: String }
public struct WeVaultTemporaryCredentials: Codable, Equatable, Sendable {
    public let provider: String; public let accessKeyId: String; public let accessKeySecret: String; public let securityToken: String
    public let expiration: String; public let endpoint: String; public let bucket: String; public let region: String; public let objectKey: String
    public init(provider: String = "aliyun-oss", accessKeyId: String, accessKeySecret: String, securityToken: String, expiration: String, endpoint: String, bucket: String, region: String, objectKey: String) {
        self.provider = provider; self.accessKeyId = accessKeyId; self.accessKeySecret = accessKeySecret; self.securityToken = securityToken
        self.expiration = expiration; self.endpoint = endpoint; self.bucket = bucket; self.region = region; self.objectKey = objectKey
    }
}
public struct WeVaultUploadAuthorization: Codable, Equatable, Sendable { public let authorizationId: String; public let credentials: WeVaultTemporaryCredentials }
public struct WeVaultDownloadAuthorization: Codable, Equatable, Sendable { public let authorizationId: String; public let credentials: WeVaultTemporaryCredentials }
public struct WeVaultObjectIndexEntry: Codable, Equatable, Sendable { public let objectId: String; public let sha256: String; public let sizeBytes: Int64; public let verifiedAt: Date }
public protocol WeVaultAPITransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, URLResponse) }
extension URLSession: WeVaultAPITransport { public func send(_ request: URLRequest) async throws -> (Data, URLResponse) { try await data(for: request) } }

public final class WeVaultAPIClient: Sendable {
    private let baseURL: URL; private let transport: any WeVaultAPITransport
    public init(baseURL: URL, transport: any WeVaultAPITransport = URLSession.shared) { self.baseURL = baseURL; self.transport = transport }
    public func register(email: String, password: String, invitationCode: String) async throws { let _: VerificationRequired = try await request("/v1/auth/register", method: "POST", body: RegisterBody(email: email, password: password, invitationCode: invitationCode), token: nil) }
    public func verifyEmail(email: String, code: String) async throws { let _: VerificationResult = try await request("/v1/auth/verify-email", method: "POST", body: VerificationBody(email: email, code: code), token: nil) }
    public func resendVerification(email: String) async throws { let _: VerificationRequired = try await request("/v1/auth/resend-verification", method: "POST", body: EmailBody(email: email), token: nil) }
    public func login(email: String, password: String) async throws -> WeVaultSession { try await request("/v1/auth/login", method: "POST", body: LoginBody(email: email, password: password), token: nil) }
    public func refresh(refreshToken: String) async throws -> WeVaultSession { try await request("/v1/auth/refresh", method: "POST", body: RefreshBody(refreshToken: refreshToken), token: nil) }
    public func logout(accessToken: String) async throws { let _: LogoutResult = try await request("/v1/auth/logout", method: "POST", body: EmptyBody(), token: accessToken) }
    public func registerDevice(accessToken: String, clientDeviceId: String, displayName: String) async throws -> WeVaultDevice { try await request("/v1/devices", method: "POST", body: DeviceBody(clientDeviceId: clientDeviceId, displayName: displayName), token: accessToken) }
    public func uploadAuthorization(accessToken: String, deviceId: String, sha256: String, sizeBytes: Int64) async throws -> WeVaultUploadAuthorization { try await request("/v1/objects/upload-authorizations", method: "POST", body: UploadBody(deviceId: deviceId, sha256: sha256, sizeBytes: sizeBytes), token: accessToken) }
    public func completeUpload(accessToken: String, authorizationId: String) async throws -> WeVaultVerificationResult { try await request("/v1/objects/\(authorizationId)/complete", method: "POST", body: EmptyBody(), token: accessToken) }
    public func downloadAuthorization(accessToken: String, objectId: String, deviceId: String) async throws -> WeVaultDownloadAuthorization {
        try await request("/v1/objects/\(objectId)/download-authorizations", method: "POST", body: DownloadBody(deviceId: deviceId), token: accessToken)
    }
    public func fallback(accessToken: String, deviceId: String, sha256: String) async throws -> [WeVaultObjectIndexEntry] {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/objects"), resolvingAgainstBaseURL: false)!; components.queryItems = [URLQueryItem(name: "deviceId", value: deviceId), URLQueryItem(name: "sha256", value: sha256)]
        var request = URLRequest(url: components.url!); request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await sendWithRateLimitRetry(request); try validate(data, response); return try JSONDecoder.wevault.decode(ObjectList.self, from: data).objects
    }
    private func request<T: Decodable>(_ path: String, method: String, body: some Encodable, token: String?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }; request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await sendWithRateLimitRetry(request); try validate(data, response); return try JSONDecoder.wevault.decode(T.self, from: data)
    }
    private func sendWithRateLimitRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let maximumRetries = 4
        for attempt in 0...maximumRetries {
            let result = try await transport.send(request)
            guard let http = result.1 as? HTTPURLResponse, http.statusCode == 429, attempt < maximumRetries else { return result }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let resetAfter = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
            let fallbackDelay = pow(2.0, Double(attempt + 1))
            let delay = min(60, max(0.25, retryAfter ?? resetAfter ?? fallbackDelay)) + 0.25
            try await Task.sleep(for: .seconds(delay))
        }
        preconditionFailure("rate-limit retry loop must return")
    }
    private func validate(_ data: Data, _ response: URLResponse) throws { guard let http = response as? HTTPURLResponse else { throw WeVaultAPIFailure(code: "NETWORK", statusCode: 0, message: "Missing HTTP response") }; guard (200...299).contains(http.statusCode) else { let error = try? JSONDecoder.wevault.decode(APIErrorEnvelope.self, from: data); throw WeVaultAPIFailure(code: error?.error.code ?? "HTTP_\(http.statusCode)", statusCode: http.statusCode, message: error?.error.message ?? "Request failed") } }
}
private struct RegisterBody: Codable { let email: String; let password: String; let invitationCode: String }
private struct LoginBody: Codable { let email: String; let password: String }
private struct EmailBody: Codable { let email: String }
private struct VerificationBody: Codable { let email: String; let code: String }
private struct RefreshBody: Codable { let refreshToken: String }
private struct DeviceBody: Codable { let clientDeviceId: String; let displayName: String }
private struct UploadBody: Codable { let deviceId: String; let sha256: String; let sizeBytes: Int64 }
private struct DownloadBody: Codable { let deviceId: String }
private struct EmptyBody: Codable {}
private struct VerificationRequired: Codable { let status: String }
private struct VerificationResult: Codable { let status: String }
private struct LogoutResult: Codable { let status: String }
public struct WeVaultVerificationResult: Codable, Equatable, Sendable { public let status: String; public let objectId: String; public let sha256: String; public let sizeBytes: Int64; public let verifiedAt: Date }
private struct ObjectList: Codable { let objects: [WeVaultObjectIndexEntry] }
private struct APIErrorEnvelope: Codable { struct Detail: Codable { let code: String; let message: String }; let error: Detail }
private extension JSONDecoder {
    static let wevault: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }()
}

/// Creates a storage client from one server-issued credential.  The credential
/// object is passed directly to the client and is never written to a manifest,
/// preferences store, or operation log.
public protocol ManagedWeVaultStorageClientFactory: Sendable {
    func makeClient(credentials: WeVaultTemporaryCredentials) -> any ObjectStorageClient
}

public struct STSObjectStorageClientFactory: ManagedWeVaultStorageClientFactory {
    public init() {}
    public func makeClient(credentials: WeVaultTemporaryCredentials) -> any ObjectStorageClient {
        S3CompatibleObjectStorageClient(config: S3CompatibleStorageConfig(
            provider: credentials.provider == "tencent-cos" ? "Tencent COS (STS)" : "Aliyun OSS (STS)", endpoint: credentials.endpoint,
            bucket: credentials.bucket, region: credentials.region,
            accessKeyID: credentials.accessKeyId, secretAccessKey: credentials.accessKeySecret,
            sessionToken: credentials.securityToken
        ))
    }
}

public enum ManagedCloudUploadOutcome: Equatable, Sendable {
    case fallbackFound([WeVaultObjectIndexEntry])
    case verified(WeVaultUploadAuthorization, WeVaultVerificationResult)
}

/// P2A managed-cloud upload adapter. It is deliberately separate from the
/// existing UI/automatic task path and never creates manifest bindings or calls
/// LocalReleaseService. Therefore every failure leaves the local file present.
public enum ManagedCloudContractPipeline {
    public static func upload(
        api: WeVaultAPIClient,
        accessToken: String,
        deviceId: String,
        fileURL: URL,
        storageFactory: any ManagedWeVaultStorageClientFactory = STSObjectStorageClientFactory()
    ) async throws -> ManagedCloudUploadOutcome {
        let size = try fileStat(fileURL.path).size; let sha = try sha256File(fileURL)
        let fallback = try await api.fallback(accessToken: accessToken, deviceId: deviceId, sha256: sha)
        if !fallback.isEmpty { return .fallbackFound(fallback) }
        let authorization = try await api.uploadAuthorization(accessToken: accessToken, deviceId: deviceId, sha256: sha, sizeBytes: size)
        try assertUsable(credentials: authorization.credentials)
        let storage = storageFactory.makeClient(credentials: authorization.credentials)
        try await storage.putObject(localURL: fileURL, objectKey: authorization.credentials.objectKey, sha256: sha, sizeBytes: size)
        let verification = try await api.completeUpload(accessToken: accessToken, authorizationId: authorization.authorizationId)
        guard verification.status == "VERIFIED" else {
            throw WeVaultAPIFailure(code: "OBJECT_NOT_VERIFIED", statusCode: 502, message: "Server did not verify uploaded object")
        }
        return .verified(authorization, verification)
    }

    public static func download(
        api: WeVaultAPIClient,
        accessToken: String,
        deviceId: String,
        objectId: String,
        destinationURL: URL,
        storageFactory: any ManagedWeVaultStorageClientFactory = STSObjectStorageClientFactory()
    ) async throws {
        let authorization = try await api.downloadAuthorization(accessToken: accessToken, objectId: objectId, deviceId: deviceId)
        try assertUsable(credentials: authorization.credentials)
        try await storageFactory.makeClient(credentials: authorization.credentials).getObject(
            objectKey: authorization.credentials.objectKey, destinationURL: destinationURL
        )
    }

    static func assertUsable(credentials: WeVaultTemporaryCredentials) throws {
        guard !credentials.accessKeyId.isEmpty, !credentials.accessKeySecret.isEmpty,
              !credentials.securityToken.isEmpty, !credentials.objectKey.isEmpty,
              let expiresAt = ISO8601DateFormatter().date(from: credentials.expiration), expiresAt > Date() else {
            throw WeVaultAPIFailure(code: "STS_EXPIRED", statusCode: 401, message: "Temporary object-storage credentials are invalid or expired")
        }
    }
}
