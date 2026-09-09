import Foundation
import Testing
@testable import WeVaultCore

struct P7UpdateTransportTests {
    @Test("update checker accepts a bounded valid feed without contacting a real endpoint")
    func validFeed() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let release = try await BetaUpdateChecker.check(feed: URL(string: "https://updates.fixture.test/valid")!, session: session)
        #expect(release.build == 8 && release.version == "0.8.0")
    }

    @Test("update checker rejects HTTP errors, oversized feeds and malformed JSON", arguments: ["unavailable", "oversized", "malformed", "unsafe"])
    func badFeeds(path: String) async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        await #expect(throws: (any Error).self) {
            _ = try await BetaUpdateChecker.check(feed: URL(string: "https://updates.fixture.test/" + path)!, session: session)
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class UpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "updates.fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let data: Data
        switch path {
        case "oversized": data = Data(repeating: 65, count: 65_537)
        case "malformed": data = Data("{invalid".utf8)
        case "unsafe": data = Data(#"{"version":"0.8.0","build":8,"minimumSystemVersion":"14.0","downloadURL":"file:///private/file","releaseNotes":"test"}"#.utf8)
        default: data = Data(#"{"version":"0.8.0","build":8,"minimumSystemVersion":"14.0","downloadURL":"https://downloads.fixture.test/","releaseNotes":"test"}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "unavailable" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count), "Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
