import CryptoKit
import Foundation

public struct StoredObjectHead: Equatable, Sendable {
    public let sizeBytes: Int64
    public let metadata: [String: String]

    public init(sizeBytes: Int64, metadata: [String: String] = [:]) {
        self.sizeBytes = sizeBytes
        self.metadata = metadata
    }
}

public protocol ObjectStorageClient: Sendable {
    func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws
    func headObject(objectKey: String) async throws -> StoredObjectHead
    func getObject(objectKey: String, destinationURL: URL) async throws
}

public final class S3CompatibleObjectStorageClient: ObjectStorageClient {
    private let config: S3CompatibleStorageConfig
    private let session: URLSession

    public init(config: S3CompatibleStorageConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func putObject(localURL: URL, objectKey: String, sha256: String, sizeBytes: Int64) async throws {
        var request = try signedRequest(method: "PUT", objectKey: objectKey, payloadHash: sha256, metadata: ["sha256": sha256])
        request.setValue(String(sizeBytes), forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.upload(for: request, fromFile: localURL)
        try validate(response: response, acceptedStatusCodes: 200...299)
    }

    public func headObject(objectKey: String) async throws -> StoredObjectHead {
        let request = try signedRequest(method: "HEAD", objectKey: objectKey, payloadHash: Self.emptyPayloadHash, metadata: [:])
        let (_, response) = try await session.data(for: request)
        try validate(response: response, acceptedStatusCodes: 200...299)
        guard let http = response as? HTTPURLResponse else {
            throw WeVaultError.cloud("Missing HTTP response for HEAD \(objectKey)")
        }
        let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? -1
        guard contentLength >= 0 else {
            throw WeVaultError.cloud("Missing Content-Length for HEAD \(objectKey)")
        }
        var metadata: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let header = key as? String else { continue }
            let normalized = header.lowercased()
            if normalized.hasPrefix("x-oss-meta-") {
                metadata[String(header.dropFirst("x-oss-meta-".count))] = String(describing: value)
            } else if normalized.hasPrefix("x-amz-meta-") {
                metadata[String(header.dropFirst("x-amz-meta-".count))] = String(describing: value)
            }
        }
        return StoredObjectHead(sizeBytes: contentLength, metadata: metadata)
    }

    public func getObject(objectKey: String, destinationURL: URL) async throws {
        let request = try signedRequest(method: "GET", objectKey: objectKey, payloadHash: Self.emptyPayloadHash, metadata: [:])
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response: response, acceptedStatusCodes: 200...299)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func signedRequest(method: String, objectKey: String, payloadHash: String, metadata: [String: String]) throws -> URLRequest {
        let endpoint = try normalizedEndpoint()
        let target = try targetURL(endpoint: endpoint, objectKey: objectKey)
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)
        let host = target.host ?? endpoint.host ?? ""
        guard !host.isEmpty else {
            throw WeVaultError.cloud("Object storage endpoint is missing a host")
        }

        var headers: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]
        // Alibaba Cloud's S3-compatible endpoint accepts the STS token through
        // this signed header.  It is intentionally supplied only by the
        // in-memory managed-cloud factory, never persisted in app settings.
        if let sessionToken = config.sessionToken, !sessionToken.isEmpty {
            headers["x-oss-security-token"] = sessionToken
        }
        let metadataPrefix = config.provider.localizedCaseInsensitiveContains("aliyun") ? "x-oss-meta-" : "x-amz-meta-"
        for (key, value) in metadata {
            headers["\(metadataPrefix)\(key.lowercased())"] = value
        }

        let canonicalHeaders = headers.keys.sorted().map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespacesAndNewlines))\n" }.joined()
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalRequest = [
            method,
            target.path.isEmpty ? "/" : target.path,
            target.query ?? "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let signingKey = Self.signingKey(secret: config.secretAccessKey, dateStamp: dateStamp, region: config.region)
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))
        let authorization = "AWS4-HMAC-SHA256 Credential=\(config.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: target)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (key, value) in headers where key != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func normalizedEndpoint() throws -> URL {
        guard !config.endpoint.isEmpty, let endpoint = URL(string: config.endpoint), endpoint.scheme != nil else {
            throw WeVaultError.cloud("Endpoint must include scheme, for example https://<account>.r2.cloudflarestorage.com")
        }
        guard !config.bucket.isEmpty else {
            throw WeVaultError.cloud("Bucket is required")
        }
        guard !config.accessKeyID.isEmpty, !config.secretAccessKey.isEmpty else {
            throw WeVaultError.cloud("Access key and secret key are required")
        }
        return endpoint
    }

    private func targetURL(endpoint: URL, objectKey: String) throws -> URL {
        let encodedKey = Self.encodedPath(objectKey)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw WeVaultError.cloud("Invalid endpoint \(config.endpoint)")
        }
        if config.pathStyle {
            components.percentEncodedPath = "/\(Self.encodedPath(config.bucket))/\(encodedKey)"
        } else {
            components.host = "\(config.bucket).\(components.host ?? "")"
            components.percentEncodedPath = "/\(encodedKey)"
        }
        guard let url = components.url else {
            throw WeVaultError.cloud("Invalid object URL for key \(objectKey)")
        }
        return url
    }

    private func validate(response: URLResponse, acceptedStatusCodes: ClosedRange<Int>) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WeVaultError.cloud("Missing HTTP response")
        }
        guard acceptedStatusCodes.contains(http.statusCode) else {
            throw WeVaultError.cloud("Object storage request failed with HTTP \(http.statusCode)")
        }
    }

    private static func encodedPath(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: .s3PathAllowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    private static func signingKey(secret: String, dateStamp: String, region: String) -> SymmetricKey {
        let dateKey = hmacData(key: SymmetricKey(data: Data("AWS4\(secret)".utf8)), data: Data(dateStamp.utf8))
        let dateRegionKey = hmacData(key: SymmetricKey(data: dateKey), data: Data(region.utf8))
        let dateRegionServiceKey = hmacData(key: SymmetricKey(data: dateRegionKey), data: Data("s3".utf8))
        return SymmetricKey(data: hmacData(key: SymmetricKey(data: dateRegionServiceKey), data: Data("aws4_request".utf8)))
    }

    private static func hmacData(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hmacHex(key: SymmetricKey, data: Data) -> String {
        hmacData(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let emptyPayloadHash = sha256Hex(Data())

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

private extension CharacterSet {
    static let s3PathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#[]@!$&'()*+,;=:")
        return set
    }()
}
