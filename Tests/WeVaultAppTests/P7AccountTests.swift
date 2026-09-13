import Foundation
import Testing
@testable import WeVaultApp
import WeVaultCore

@MainActor
struct P7AccountTests {
    @Test("logout and login preserve the device registration identity")
    func persistentDeviceIdentity() async throws {
        let transport = RefreshProbe()
        let account = ManagedAccount(api: WeVaultAPIClient(baseURL: URL(string: "https://fixture.invalid")!, transport: transport), memoryOnly: true)
        try await account.login(email: "fixture@example.test", password: "fixture")
        await account.logout()
        try await account.login(email: "fixture@example.test", password: "fixture")
        let ids = await transport.clientIDs
        #expect(ids.count == 2)
        #expect(ids[0] == ids[1])
    }

    @Test("isolated login is explained and rejected before any network request")
    func isolatedLogin() async throws {
        let transport = RefreshProbe()
        let account = ManagedAccount(api: WeVaultAPIClient(baseURL: URL(string: "https://fixture.invalid")!, transport: transport), memoryOnly: true, loginEnabled: false)
        #expect(account.loginUnavailableMessage?.contains("无需登录") == true)
        await #expect(throws: ManagedAccountLoginFailure.self) {
            try await account.login(email: "fixture@example.test", password: "fixture")
        }
        await #expect(throws: ManagedAccountLoginFailure.self) {
            try await account.register(email: "fixture@example.test", password: "fixture-password", invitationCode: "wv_fixture")
        }
        #expect(await transport.requestCount == 0)
        #expect(!account.isReady)
    }

    @Test("registration verification calls invite-gated endpoints without storing a session")
    func registrationFlow() async throws {
        let transport = RegistrationProbe()
        let account = ManagedAccount(api: WeVaultAPIClient(baseURL: URL(string: "https://fixture.invalid")!, transport: transport), memoryOnly: true)
        try await account.register(email: "fixture@example.test", password: "fixture-password", invitationCode: "wv_fixture")
        try await account.verifyEmail(email: "fixture@example.test", code: "123456")
        try await account.resendVerification(email: "fixture@example.test")
        #expect(!account.isReady)
        #expect(await transport.paths == ["/v1/auth/register", "/v1/auth/verify-email", "/v1/auth/resend-verification"])
    }

    @Test("concurrent callers share one rotating refresh token request")
    func refreshCoalescing() async throws {
        let transport = RefreshProbe()
        let account = ManagedAccount(api: WeVaultAPIClient(baseURL: URL(string: "https://fixture.invalid")!, transport: transport), memoryOnly: true)
        try await account.login(email: "fixture@example.test", password: "fixture")
        async let first = account.accessToken()
        async let second = account.accessToken()
        let tokens = try await [first, second]
        #expect(tokens == ["new-access", "new-access"])
        #expect(await transport.refreshCount == 1)
    }

    @Test("logging out prevents an in-flight refresh from restoring the old session")
    func logoutDuringRefresh() async throws {
        let transport = RefreshProbe()
        let account = ManagedAccount(api: WeVaultAPIClient(baseURL: URL(string: "https://fixture.invalid")!, transport: transport), memoryOnly: true)
        try await account.login(email: "fixture@example.test", password: "fixture")
        let pending = Task { try await account.accessToken() }
        while await transport.refreshCount == 0 { await Task.yield() }
        await account.logout()
        _ = try? await pending.value
        #expect(!account.isReady)
        await #expect(throws: WeVaultError.self) { try await account.accessToken() }
    }
}

private actor RefreshProbe: WeVaultAPITransport {
    private(set) var clientIDs: [String] = []
    private(set) var requestCount = 0
    private(set) var refreshCount = 0
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        if request.url?.path == "/v1/devices", let data = request.httpBody,
           let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = body["clientDeviceId"] as? String { clientIDs.append(id) }
        let body: String
        switch request.url!.lastPathComponent {
        case "login": body = #"{"accessToken":"old-access","refreshToken":"one-use","expiresIn":1}"#
        case "devices": body = #"{"deviceId":"device"}"#
        case "refresh":
            refreshCount += 1
            try await Task.sleep(for: .milliseconds(50))
            body = #"{"accessToken":"new-access","refreshToken":"new-refresh","expiresIn":900}"#
        default: body = #"{"status":"ok"}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor RegistrationProbe: WeVaultAPITransport {
    private(set) var paths: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url!.path)
        let body = request.url!.lastPathComponent == "verify-email" ? #"{"status":"VERIFIED"}"# : #"{"status":"VERIFICATION_REQUIRED"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
