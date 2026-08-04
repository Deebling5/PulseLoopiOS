import Foundation

// MARK: - Credentials

/// Strava API application credentials (from the user's Strava API settings page).
nonisolated struct StravaAppCredentials: Equatable, Sendable {
    var clientId: String
    var clientSecret: String

    var isComplete: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
}

// MARK: - DTOs

nonisolated struct StravaTokenResponse: Codable, Sendable {
    nonisolated struct Athlete: Codable, Sendable {
        var id: Int
        var firstname: String?
        var lastname: String?
    }

    var accessToken: String
    var refreshToken: String
    /// Epoch seconds when `accessToken` expires.
    var expiresAt: Int
    /// Present on the authorization-code exchange; absent on refresh.
    var athlete: Athlete?

    var expiresAtDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }

    var athleteDisplayName: String {
        let parts = [athlete?.firstname, athlete?.lastname].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case athlete
    }
}

nonisolated struct StravaUploadStatus: Codable, Sendable {
    var id: Int64
    var idStr: String?
    var externalId: String?
    var error: String?
    var status: String?
    var activityId: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case idStr = "id_str"
        case externalId = "external_id"
        case error
        case status
        case activityId = "activity_id"
    }
}

nonisolated struct StravaActivitySummary: Codable, Sendable {
    var id: Int64
}

// MARK: - Errors

nonisolated enum StravaError: LocalizedError, Equatable {
    case missingCredentials
    case authFailed(String)
    case http(status: Int, body: String)
    case rateLimited
    case duplicate(existingActivityId: String?)
    case uploadProcessingFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Strava client ID and secret are not configured."
        case .authFailed(let detail):
            return "Strava authorization failed: \(detail)"
        case .http(let status, let body):
            return "Strava request failed (HTTP \(status)): \(body.prefix(200))"
        case .rateLimited:
            return "Strava rate limit reached. Try again later."
        case .duplicate(let id):
            if let id { return "Already on Strava (activity \(id))." }
            return "Already on Strava."
        case .uploadProcessingFailed(let detail):
            return "Strava could not process the upload: \(detail)"
        case .invalidResponse:
            return "Unexpected response from Strava."
        }
    }
}

// MARK: - Client protocol

/// Async surface over the Strava v3 API so the sync service can be tested
/// against a stub. Nonisolated: called from off-main sync work.
nonisolated protocol StravaAPIClient: Sendable {
    func exchangeCode(code: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse
    func refreshToken(_ refreshToken: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse
    func deauthorize(accessToken: String) async throws
    func startUpload(
        tcx: Data,
        fileName: String,
        name: String,
        description: String?,
        trainer: Bool,
        externalId: String,
        accessToken: String
    ) async throws -> StravaUploadStatus
    func uploadStatus(id: Int64, accessToken: String) async throws -> StravaUploadStatus
    func createManualActivity(
        name: String,
        sportType: String,
        startDateLocalISO8601: String,
        elapsedSeconds: Int,
        description: String?,
        distanceMeters: Double?,
        trainer: Bool,
        accessToken: String
    ) async throws -> StravaActivitySummary
    /// Returns the sport_type Strava reports after the update, when parseable.
    @discardableResult
    func updateActivity(id: Int64, sportType: String, accessToken: String) async throws -> String?
}

// MARK: - HTTP client

nonisolated struct StravaHTTPClient: StravaAPIClient {
    var session: URLSession = .shared

    private static let oauthBase = URL(string: "https://www.strava.com/oauth")!
    private static let apiBase = URL(string: "https://www.strava.com/api/v3")!

    // MARK: OAuth

    func exchangeCode(code: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse {
        try await tokenRequest(credentials: credentials, extraFields: [
            ("code", code),
            ("grant_type", "authorization_code"),
        ])
    }

    func refreshToken(_ refreshToken: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse {
        try await tokenRequest(credentials: credentials, extraFields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    private func tokenRequest(
        credentials: StravaAppCredentials,
        extraFields: [(String, String)]
    ) async throws -> StravaTokenResponse {
        guard credentials.isComplete else { throw StravaError.missingCredentials }
        var request = URLRequest(url: Self.oauthBase.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields: [(String, String)] = [
            ("client_id", credentials.clientId),
            ("client_secret", credentials.clientSecret),
        ]
        fields.append(contentsOf: extraFields)
        request.httpBody = Data(Self.formEncode(fields).utf8)
        let data = try await send(request, unauthorizedIsAuthFailure: true)
        return try Self.decode(StravaTokenResponse.self, from: data)
    }

    func deauthorize(accessToken: String) async throws {
        var request = URLRequest(url: Self.oauthBase.appendingPathComponent("deauthorize"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    // MARK: Uploads

    func startUpload(
        tcx: Data,
        fileName: String,
        name: String,
        description: String?,
        trainer: Bool,
        externalId: String,
        accessToken: String
    ) async throws -> StravaUploadStatus {
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("uploads"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var fields: [(String, String)] = [
            ("data_type", "tcx"),
            ("name", name),
            ("external_id", externalId),
        ]
        if let description, !description.isEmpty { fields.append(("description", description)) }
        if trainer { fields.append(("trainer", "1")) }

        let boundary = "pulseloop-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: fields,
            fileFieldName: "file",
            fileName: fileName,
            fileContentType: "application/xml",
            fileData: tcx
        )
        let data = try await send(request)
        return try Self.decode(StravaUploadStatus.self, from: data)
    }

    func uploadStatus(id: Int64, accessToken: String) async throws -> StravaUploadStatus {
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("uploads/\(id)"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        return try Self.decode(StravaUploadStatus.self, from: data)
    }

    // MARK: Activities

    func createManualActivity(
        name: String,
        sportType: String,
        startDateLocalISO8601: String,
        elapsedSeconds: Int,
        description: String?,
        distanceMeters: Double?,
        trainer: Bool,
        accessToken: String
    ) async throws -> StravaActivitySummary {
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("activities"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields: [(String, String)] = [
            ("name", name),
            ("sport_type", sportType),
            ("start_date_local", startDateLocalISO8601),
            ("elapsed_time", String(elapsedSeconds)),
        ]
        if let description, !description.isEmpty { fields.append(("description", description)) }
        if let distanceMeters { fields.append(("distance", String(distanceMeters))) }
        if trainer { fields.append(("trainer", "1")) }
        request.httpBody = Data(Self.formEncode(fields).utf8)
        let data = try await send(request)
        return try Self.decode(StravaActivitySummary.self, from: data)
    }

    @discardableResult
    func updateActivity(id: Int64, sportType: String, accessToken: String) async throws -> String? {
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("activities/\(id)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sport_type": sportType])
        let data = try await send(request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["sport_type"] as? String
    }

    // MARK: Duplicate detection

    /// Extracts the existing activity id from a Strava upload duplicate error,
    /// e.g. "workout.tcx is a duplicate of activity 123456" or "duplicate of 123456".
    static func parseDuplicate(from error: String) -> String? {
        let pattern = #"duplicate of (?:activity )?(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)),
              let range = Range(match.range(at: 1), in: error) else { return nil }
        return String(error[range])
    }

    // MARK: Transport helpers

    private func send(_ request: URLRequest, unauthorizedIsAuthFailure: Bool = false) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StravaError.invalidResponse }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200...299:
            return data
        case 429:
            throw StravaError.rateLimited
        case 400, 401:
            // Strava returns 400 for a bad/expired code and 401 for bad credentials.
            if unauthorizedIsAuthFailure { throw StravaError.authFailed(body) }
            throw StravaError.http(status: http.statusCode, body: body)
        default:
            throw StravaError.http(status: http.statusCode, body: body)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw StravaError.invalidResponse
        }
    }

    private static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    private static func multipartBody(
        boundary: String,
        fields: [(String, String)],
        fileFieldName: String,
        fileName: String,
        fileContentType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(fileContentType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
