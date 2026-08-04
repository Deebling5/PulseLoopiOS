import XCTest
@testable import PulseLoop

/// Coverage for `StravaAuthService`: state derivation on init, token vending with the 300s expiry
/// leeway, single-flight refresh, auth-failure teardown, authorize-URL construction, and the
/// granted-scope check. The ASWebAuthenticationSession UI flow itself is not testable headless.
@MainActor
final class StravaAuthServiceTests: XCTestCase {

    // MARK: - Fakes

    private final class MemoryTokenStore: StravaTokenStoring, @unchecked Sendable {
        var tokens: StravaTokens?
        func read() throws -> StravaTokens? { tokens }
        func save(_ tokens: StravaTokens) throws { self.tokens = tokens }
        func delete() throws { tokens = nil }
    }

    private final class FakeClient: StravaAPIClient, @unchecked Sendable {
        var refreshCallCount = 0
        var refreshResult: Result<StravaTokenResponse, Error> = .failure(StravaError.invalidResponse)
        var refreshDelayNanoseconds: UInt64 = 0

        func refreshToken(_ refreshToken: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse {
            refreshCallCount += 1
            if refreshDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
            }
            return try refreshResult.get()
        }

        func exchangeCode(code: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse {
            throw StravaError.invalidResponse
        }
        func deauthorize(accessToken: String) async throws {}
        func startUpload(
            tcx: Data, fileName: String, name: String, description: String?,
            trainer: Bool, externalId: String, accessToken: String
        ) async throws -> StravaUploadStatus {
            throw StravaError.invalidResponse
        }
        func uploadStatus(id: Int64, accessToken: String) async throws -> StravaUploadStatus {
            throw StravaError.invalidResponse
        }
        func createManualActivity(
            name: String, sportType: String, startDateLocalISO8601: String, elapsedSeconds: Int,
            description: String?, distanceMeters: Double?, trainer: Bool, accessToken: String
        ) async throws -> StravaActivitySummary {
            throw StravaError.invalidResponse
        }
        func updateActivity(id: Int64, sportType: String, accessToken: String) async throws -> String? { sportType }
    }

    // MARK: - Helpers

    private let credentials = StravaCredentials(clientID: "12345", clientSecret: "s3cret")

    private func makeService(
        client: FakeClient = FakeClient(),
        store: MemoryTokenStore = MemoryTokenStore(),
        credentials: StravaCredentials?
    ) -> StravaAuthService {
        StravaAuthService(
            client: client,
            tokenStore: store,
            credentials: credentials,
            prefs: StravaPrefsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    private func makeTokens(expiresIn: TimeInterval) -> StravaTokens {
        StravaTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(expiresIn),
            athleteId: 42,
            athleteName: "Jane Doe"
        )
    }

    private func rotatedResponse(expiresIn: TimeInterval = 6 * 3600) -> StravaTokenResponse {
        StravaTokenResponse(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970),
            athlete: nil
        )
    }

    // MARK: - Init state derivation

    func testInitWithNilCredentialsIsMissingCredentials() {
        let service = makeService(credentials: nil)
        XCTAssertEqual(service.state, .missingCredentials)
        XCTAssertFalse(service.isConnected)
    }

    func testInitWithStoredTokensIsConnectedWithAthleteName() {
        let store = MemoryTokenStore()
        store.tokens = makeTokens(expiresIn: 3600)
        let service = makeService(store: store, credentials: credentials)
        XCTAssertEqual(service.state, .connected(athleteName: "Jane Doe"))
        XCTAssertTrue(service.isConnected)
    }

    func testInitWithCredentialsButNoTokensIsDisconnected() {
        let service = makeService(credentials: credentials)
        XCTAssertEqual(service.state, .disconnected)
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - validAccessToken

    func testFreshTokenReturnedWithoutRefresh() async throws {
        let client = FakeClient()
        let store = MemoryTokenStore()
        store.tokens = makeTokens(expiresIn: 3600)
        let service = makeService(client: client, store: store, credentials: credentials)

        let token = try await service.validAccessToken()
        XCTAssertEqual(token, "old-access")
        XCTAssertEqual(client.refreshCallCount, 0)
    }

    func testExpiringTokenRefreshesAndPersistsRotatedTokens() async throws {
        let client = FakeClient()
        client.refreshResult = .success(rotatedResponse())
        let store = MemoryTokenStore()
        store.tokens = makeTokens(expiresIn: 60)   // inside the 300s leeway
        let service = makeService(client: client, store: store, credentials: credentials)

        let token = try await service.validAccessToken()
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(client.refreshCallCount, 1)
        // Both rotated tokens must be persisted before validAccessToken returns.
        XCTAssertEqual(store.tokens?.accessToken, "new-access")
        XCTAssertEqual(store.tokens?.refreshToken, "new-refresh")
        // Rotation must not clobber the athlete identity when refresh omits the athlete.
        XCTAssertEqual(store.tokens?.athleteId, 42)
        XCTAssertEqual(store.tokens?.athleteName, "Jane Doe")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let client = FakeClient()
        client.refreshResult = .success(rotatedResponse())
        client.refreshDelayNanoseconds = 50_000_000   // keep the refresh in flight while both callers arrive
        let store = MemoryTokenStore()
        store.tokens = makeTokens(expiresIn: 60)
        let service = makeService(client: client, store: store, credentials: credentials)

        async let first = service.validAccessToken()
        async let second = service.validAccessToken()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a, "new-access")
        XCTAssertEqual(b, "new-access")
        XCTAssertEqual(client.refreshCallCount, 1, "single-flight: concurrent callers must share one refresh")
    }

    func testAuthFailedRefreshClearsStoreAndDisconnects() async {
        let client = FakeClient()
        client.refreshResult = .failure(StravaError.authFailed("invalid grant"))
        let store = MemoryTokenStore()
        store.tokens = makeTokens(expiresIn: 60)
        let service = makeService(client: client, store: store, credentials: credentials)
        XCTAssertTrue(service.isConnected)

        do {
            _ = try await service.validAccessToken()
            XCTFail("expected authFailed to propagate")
        } catch {
            XCTAssertEqual(error as? StravaError, .authFailed("invalid grant"))
        }
        XCTAssertNil(store.tokens, "auth failure must wipe stored tokens")
        XCTAssertEqual(service.state, .disconnected)
    }

    func testNoStoredTokensThrowsNotConnected() async {
        let service = makeService(credentials: credentials)
        do {
            _ = try await service.validAccessToken()
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? StravaAuthError, .notConnected)
        }
    }

    // MARK: - Authorize URL

    func testAuthorizeURLQueryParameters() throws {
        let url = StravaAuthService.authorizeURL(credentials: credentials, state: "abc-123")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.strava.com")
        XCTAssertEqual(components.path, "/oauth/mobile/authorize")

        var query = [String: String]()
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        XCTAssertEqual(query["client_id"], "12345")
        XCTAssertEqual(query["redirect_uri"], "pulseloop://localhost/strava-auth")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["approval_prompt"], "auto")
        XCTAssertEqual(query["scope"], "activity:write,read")
        XCTAssertEqual(query["state"], "abc-123")
    }

    // MARK: - Scope check

    func testGrantedScopeIncludesWrite() {
        XCTAssertTrue(StravaAuthService.grantedScopeIncludesWrite("read,activity:write"))
        XCTAssertTrue(StravaAuthService.grantedScopeIncludesWrite("activity:write"))
        XCTAssertTrue(StravaAuthService.grantedScopeIncludesWrite(" read , activity:write "))
        XCTAssertFalse(StravaAuthService.grantedScopeIncludesWrite("read"))
        XCTAssertFalse(StravaAuthService.grantedScopeIncludesWrite("read,activity:read_all"))
        XCTAssertFalse(StravaAuthService.grantedScopeIncludesWrite(""))
        XCTAssertFalse(StravaAuthService.grantedScopeIncludesWrite(nil))
    }

    // MARK: - Callback parsing

    func testAuthorizationCodeParsesValidCallback() throws {
        let url = URL(string: "pulseloop://localhost/strava-auth?state=s1&code=c0de&scope=read,activity:write")!
        XCTAssertEqual(try StravaAuthService.authorizationCode(from: url, expectedState: "s1"), "c0de")
    }

    func testAuthorizationCodeRejectsStateMismatch() {
        let url = URL(string: "pulseloop://localhost/strava-auth?state=evil&code=c0de&scope=activity:write")!
        XCTAssertThrowsError(try StravaAuthService.authorizationCode(from: url, expectedState: "s1")) {
            XCTAssertEqual($0 as? StravaAuthError, .stateMismatch)
        }
    }

    func testAuthorizationCodeRejectsMissingWriteScope() {
        let url = URL(string: "pulseloop://localhost/strava-auth?state=s1&code=c0de&scope=read")!
        XCTAssertThrowsError(try StravaAuthService.authorizationCode(from: url, expectedState: "s1")) {
            XCTAssertEqual($0 as? StravaAuthError, .missingWriteScope)
        }
    }
}
