import XCTest
@testable import PulseLoop

/// URLProtocol stub for StravaHTTPClient tests. Distinct from CoachTests'
/// StubURLProtocol because these tests also need the method and headers.
final class StravaStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var lastRequestURL: URL?
    nonisolated(unsafe) static var lastRequestMethod: String?
    nonisolated(unsafe) static var lastRequestHeaders: [String: String] = [:]
    nonisolated(unsafe) static var lastRequestBody: Data?

    static func reset() {
        responseBody = Data()
        statusCode = 200
        lastRequestURL = nil
        lastRequestMethod = nil
        lastRequestHeaders = [:]
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        Self.lastRequestURL = request.url
        Self.lastRequestMethod = request.httpMethod
        Self.lastRequestHeaders = request.allHTTPHeaderFields ?? [:]
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class StravaClientTests: XCTestCase {
    private var client: StravaHTTPClient!
    private let credentials = StravaAppCredentials(clientId: "12345", clientSecret: "secret-abc")

    override func setUp() {
        super.setUp()
        StravaStubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StravaStubURLProtocol.self]
        client = StravaHTTPClient(session: URLSession(configuration: config))
    }

    private var lastBodyString: String {
        StravaStubURLProtocol.lastRequestBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: OAuth

    func testExchangeCodePostsAuthorizationCodeGrantAndParsesResponse() async throws {
        StravaStubURLProtocol.responseBody = Data("""
        {"access_token":"at-1","refresh_token":"rt-1","expires_at":1735689600,
         "athlete":{"id":42,"firstname":"Ada","lastname":"Lovelace"}}
        """.utf8)

        let response = try await client.exchangeCode(code: "code-xyz", credentials: credentials)

        XCTAssertEqual(StravaStubURLProtocol.lastRequestURL?.absoluteString, "https://www.strava.com/oauth/token")
        XCTAssertEqual(StravaStubURLProtocol.lastRequestMethod, "POST")
        let body = lastBodyString
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=code-xyz"))
        XCTAssertTrue(body.contains("client_id=12345"))
        XCTAssertTrue(body.contains("client_secret=secret-abc"))

        XCTAssertEqual(response.accessToken, "at-1")
        XCTAssertEqual(response.refreshToken, "rt-1")
        XCTAssertEqual(response.expiresAtDate, Date(timeIntervalSince1970: 1_735_689_600))
        XCTAssertEqual(response.athlete?.id, 42)
        XCTAssertEqual(response.athleteDisplayName, "Ada Lovelace")
    }

    func testRefreshPostsRefreshTokenGrant() async throws {
        StravaStubURLProtocol.responseBody = Data(
            #"{"access_token":"at-2","refresh_token":"rt-2","expires_at":1700000000}"#.utf8
        )

        let response = try await client.refreshToken("rt-old", credentials: credentials)

        let body = lastBodyString
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-old"))
        XCTAssertNil(response.athlete)
        XCTAssertEqual(response.accessToken, "at-2")
    }

    func testExchangeWithoutCredentialsThrowsMissingCredentials() async {
        do {
            _ = try await client.exchangeCode(code: "c", credentials: StravaAppCredentials(clientId: "", clientSecret: ""))
            XCTFail("expected missingCredentials")
        } catch let error as StravaError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUnauthorizedRefreshThrowsAuthFailed() async {
        StravaStubURLProtocol.statusCode = 401
        StravaStubURLProtocol.responseBody = Data(#"{"message":"Bad Request"}"#.utf8)
        do {
            _ = try await client.refreshToken("rt-old", credentials: credentials)
            XCTFail("expected authFailed")
        } catch let error as StravaError {
            guard case .authFailed = error else { return XCTFail("expected authFailed, got \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Uploads

    func testStartUploadBuildsMultipartBody() async throws {
        StravaStubURLProtocol.responseBody = Data(#"{"id":9001,"status":"Your activity is still being processed."}"#.utf8)

        let tcxBytes = Data("<TrainingCenterDatabase/>".utf8)
        let status = try await client.startUpload(
            tcx: tcxBytes,
            fileName: "pl-ext-1.tcx",
            name: "Morning Run",
            description: "PulseLoop workout",
            trainer: true,
            externalId: "pl-ext-1",
            accessToken: "at-1"
        )

        XCTAssertEqual(status.id, 9001)
        XCTAssertEqual(StravaStubURLProtocol.lastRequestURL?.absoluteString, "https://www.strava.com/api/v3/uploads")
        XCTAssertEqual(StravaStubURLProtocol.lastRequestMethod, "POST")
        XCTAssertEqual(StravaStubURLProtocol.lastRequestHeaders["Authorization"], "Bearer at-1")

        let contentType = StravaStubURLProtocol.lastRequestHeaders["Content-Type"] ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = lastBodyString
        XCTAssertTrue(body.contains("name=\"data_type\""))
        XCTAssertTrue(body.contains("\r\n\r\ntcx\r\n"))
        XCTAssertTrue(body.contains("name=\"external_id\""))
        XCTAssertTrue(body.contains("pl-ext-1"))
        XCTAssertTrue(body.contains("name=\"trainer\""))
        XCTAssertTrue(body.contains("\r\n\r\n1\r\n"))
        XCTAssertTrue(body.contains("filename=\"pl-ext-1.tcx\""))
        XCTAssertTrue(body.contains("Content-Type: application/xml"))
        XCTAssertTrue(body.contains("<TrainingCenterDatabase/>"))
        XCTAssertTrue(body.contains("name=\"name\""))
        XCTAssertTrue(body.contains("Morning Run"))
    }

    func testRateLimitedThrowsRateLimited() async {
        StravaStubURLProtocol.statusCode = 429
        StravaStubURLProtocol.responseBody = Data(#"{"message":"Rate Limit Exceeded"}"#.utf8)
        do {
            _ = try await client.uploadStatus(id: 1, accessToken: "at-1")
            XCTFail("expected rateLimited")
        } catch let error as StravaError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUploadStatusDecodesActivityId() async throws {
        StravaStubURLProtocol.responseBody = Data("""
        {"id":9001,"id_str":"9001","external_id":"pl-ext-1.tcx","error":null,
         "status":"Your activity is ready.","activity_id":987654321}
        """.utf8)

        let status = try await client.uploadStatus(id: 9001, accessToken: "at-1")

        XCTAssertEqual(StravaStubURLProtocol.lastRequestURL?.absoluteString, "https://www.strava.com/api/v3/uploads/9001")
        XCTAssertEqual(StravaStubURLProtocol.lastRequestMethod, "GET")
        XCTAssertEqual(status.activityId, 987_654_321)
        XCTAssertNil(status.error)
    }

    // MARK: Duplicate parsing

    func testParseDuplicateExtractsActivityId() {
        XCTAssertEqual(
            StravaHTTPClient.parseDuplicate(from: "workout.tcx is a duplicate of activity 123456"),
            "123456"
        )
        XCTAssertEqual(
            StravaHTTPClient.parseDuplicate(from: "PL-1.tcx is a Duplicate of 998877."),
            "998877"
        )
    }

    func testParseDuplicateReturnsNilWithoutId() {
        XCTAssertNil(StravaHTTPClient.parseDuplicate(from: "this upload is a duplicate"))
        XCTAssertNil(StravaHTTPClient.parseDuplicate(from: "malformed file"))
    }

    // MARK: Activities

    func testCreateManualActivityPostsFormFields() async throws {
        StravaStubURLProtocol.responseBody = Data(#"{"id":555}"#.utf8)

        let summary = try await client.createManualActivity(
            name: "Strength",
            sportType: "WeightTraining",
            startDateLocalISO8601: "2026-07-26T07:00:00Z",
            elapsedSeconds: 1800,
            description: nil,
            distanceMeters: nil,
            trainer: false,
            accessToken: "at-1"
        )

        XCTAssertEqual(summary.id, 555)
        XCTAssertEqual(StravaStubURLProtocol.lastRequestURL?.absoluteString, "https://www.strava.com/api/v3/activities")
        let body = lastBodyString
        XCTAssertTrue(body.contains("sport_type=WeightTraining"))
        XCTAssertTrue(body.contains("elapsed_time=1800"))
        XCTAssertTrue(body.contains("start_date_local=2026-07-26T07%3A00%3A00Z"))
        XCTAssertFalse(body.contains("trainer="))
    }

    func testUpdateActivitySendsJSONSportType() async throws {
        StravaStubURLProtocol.responseBody = Data(#"{"id":555}"#.utf8)

        try await client.updateActivity(id: 555, sportType: "Run", accessToken: "at-1")

        XCTAssertEqual(StravaStubURLProtocol.lastRequestURL?.absoluteString, "https://www.strava.com/api/v3/activities/555")
        XCTAssertEqual(StravaStubURLProtocol.lastRequestMethod, "PUT")
        XCTAssertEqual(StravaStubURLProtocol.lastRequestHeaders["Content-Type"], "application/json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(StravaStubURLProtocol.lastRequestBody)) as? [String: String]
        )
        XCTAssertEqual(json, ["sport_type": "Run"])
    }
}
