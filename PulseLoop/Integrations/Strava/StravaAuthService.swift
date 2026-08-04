import AuthenticationServices
import Foundation
import UIKit

// MARK: - Errors

/// Errors surfaced by the Strava OAuth flow. `cancelled` is thrown when the user dismisses the
/// web sheet — UIs should catch and ignore it silently rather than showing an alert.
nonisolated enum StravaAuthError: LocalizedError, Equatable {
    case cancelled
    case missingCredentials
    case notConnected
    case invalidCallback
    case stateMismatch
    case missingWriteScope
    case authorizationDenied(String)
    case sessionFailedToStart

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Strava sign-in was cancelled."
        case .missingCredentials:
            return "Strava client ID and secret are not configured."
        case .notConnected:
            return "Not connected to Strava. Connect your account in Settings first."
        case .invalidCallback:
            return "Strava returned an unexpected authorization response."
        case .stateMismatch:
            return "Strava authorization could not be verified. Please try connecting again."
        case .missingWriteScope:
            return "Strava did not grant upload permission. Reconnect and keep \"Upload your activities\" checked."
        case .authorizationDenied(let reason):
            return "Strava denied authorization: \(reason)"
        case .sessionFailedToStart:
            return "Could not open the Strava sign-in sheet."
        }
    }
}

// MARK: - Auth service

/// Owns the Strava OAuth lifecycle: connect (ASWebAuthenticationSession + code exchange),
/// disconnect (deauthorize + token wipe), and access-token vending with single-flight refresh.
/// Tokens live in the Keychain via `StravaTokenStoring`; athlete identity mirrors into
/// `StravaPrefsStore` for display in settings.
@MainActor
@Observable
final class StravaAuthService: StravaTokenProviding {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    enum ConnectionState: Equatable {
        case missingCredentials
        case disconnected
        case connecting
        case connected(athleteName: String)
    }

    static let shared = StravaAuthService()

    /// Registered as the app's Authorization Callback Domain (`localhost`) + custom scheme.
    static let redirectURI = "pulseloop://localhost/strava-auth"
    private static let callbackScheme = "pulseloop"
    /// Refresh when fewer than this many seconds of validity remain.
    private static let expiryLeeway: TimeInterval = 300
    private static let fallbackAthleteName = "Strava athlete"

    var state: ConnectionState

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    private let client: StravaAPIClient
    private let tokenStore: StravaTokenStoring
    private let credentials: StravaCredentials?
    private let prefs: StravaPrefsStore

    /// Single-flight refresh: concurrent `validAccessToken()` callers await this shared task.
    private var refreshTask: Task<StravaTokens, Error>?
    /// Strong refs so the auth sheet and its anchor provider survive until the callback fires.
    private var activeAuthSession: ASWebAuthenticationSession?
    private var activeContextProvider: StravaAuthPresentationContextProvider?

    init(
        client: StravaAPIClient = StravaHTTPClient(),
        tokenStore: StravaTokenStoring = StravaKeychainTokenStore(),
        credentials: StravaCredentials? = StravaSecrets.load(),
        prefs: StravaPrefsStore = .shared
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.credentials = credentials
        self.prefs = prefs
        if credentials == nil {
            state = .missingCredentials
        } else if let tokens = try? tokenStore.read() {
            state = .connected(athleteName: tokens.athleteName)
        } else {
            state = .disconnected
        }
    }

    // MARK: Connect

    func connect() async throws {
        guard let credentials else {
            state = .missingCredentials
            throw StravaAuthError.missingCredentials
        }
        let previousState = state
        state = .connecting
        let expectedState = UUID().uuidString
        do {
            let authorizeURL = Self.authorizeURL(credentials: credentials, state: expectedState)
            let callbackURL = try await runAuthSession(url: authorizeURL)
            let code = try Self.authorizationCode(from: callbackURL, expectedState: expectedState)
            let response = try await client.exchangeCode(code: code, credentials: appCredentials(credentials))
            let athleteName = response.athleteDisplayName.isEmpty
                ? Self.fallbackAthleteName
                : response.athleteDisplayName
            let tokens = StravaTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresAt: response.expiresAtDate,
                athleteId: response.athlete?.id ?? 0,
                athleteName: athleteName
            )
            try tokenStore.save(tokens)
            var syncState = prefs.state
            syncState.athleteName = athleteName
            syncState.athleteId = response.athlete?.id
            prefs.state = syncState
            state = .connected(athleteName: athleteName)
        } catch {
            state = previousState
            throw error
        }
    }

    // MARK: Disconnect

    /// Best-effort deauthorize, then wipe tokens + athlete identity and turn off the master toggle.
    func disconnect() async {
        if let tokens = try? tokenStore.read() {
            try? await client.deauthorize(accessToken: tokens.accessToken)
        }
        refreshTask?.cancel()
        refreshTask = nil
        try? tokenStore.delete()
        var syncState = prefs.state
        syncState.athleteName = nil
        syncState.athleteId = nil
        prefs.state = syncState
        prefs.prefs.masterEnabled = false
        state = .disconnected
    }

    // MARK: Token vending

    func validAccessToken() async throws -> String {
        guard let tokens = try tokenStore.read() else {
            throw StravaAuthError.notConnected
        }
        if tokens.expiresAt > Date().addingTimeInterval(Self.expiryLeeway) {
            return tokens.accessToken
        }
        let task: Task<StravaTokens, Error>
        if let inFlight = refreshTask {
            task = inFlight
        } else {
            task = makeRefreshTask(current: tokens)
            refreshTask = task
        }
        return try await task.value.accessToken
    }

    /// Refreshes and persists rotated tokens **before** the task completes, so every awaiting
    /// caller observes the persisted state. Auth failures wipe tokens and disconnect.
    private func makeRefreshTask(current: StravaTokens) -> Task<StravaTokens, Error> {
        Task {
            defer { refreshTask = nil }
            do {
                guard let credentials else { throw StravaAuthError.missingCredentials }
                let response = try await client.refreshToken(
                    current.refreshToken,
                    credentials: appCredentials(credentials)
                )
                var rotated = current
                rotated.accessToken = response.accessToken
                rotated.refreshToken = response.refreshToken
                rotated.expiresAt = response.expiresAtDate
                if let athlete = response.athlete {
                    rotated.athleteId = athlete.id
                    if !response.athleteDisplayName.isEmpty {
                        rotated.athleteName = response.athleteDisplayName
                    }
                }
                try tokenStore.save(rotated)
                return rotated
            } catch {
                if Self.isAuthFailure(error) {
                    try? tokenStore.delete()
                    var syncState = prefs.state
                    syncState.athleteName = nil
                    syncState.athleteId = nil
                    prefs.state = syncState
                    state = .disconnected
                }
                throw error
            }
        }
    }

    private static func isAuthFailure(_ error: Error) -> Bool {
        switch error as? StravaError {
        case .authFailed: return true
        case .http(let status, _): return status == 401
        default: return false
        }
    }

    // MARK: URL building (internal for tests)

    static func authorizeURL(credentials: StravaCredentials, state: String) -> URL {
        var components = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "activity:write,read"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Strava echoes the granted scopes as a comma-separated list; users can uncheck
    /// "Upload your activities", so verify `activity:write` actually came back.
    static func grantedScopeIncludesWrite(_ scope: String?) -> Bool {
        guard let scope else { return false }
        return scope
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("activity:write")
    }

    /// Validates the OAuth callback (state echo, error param, granted scope) and extracts the code.
    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw StravaAuthError.invalidCallback
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error"), !error.isEmpty {
            throw StravaAuthError.authorizationDenied(error)
        }
        guard value("state") == expectedState else {
            throw StravaAuthError.stateMismatch
        }
        guard grantedScopeIncludesWrite(value("scope")) else {
            throw StravaAuthError.missingWriteScope
        }
        guard let code = value("code"), !code.isEmpty else {
            throw StravaAuthError.invalidCallback
        }
        return code
    }

    // MARK: Web auth session

    private func runAuthSession(url: URL) async throws -> URL {
        defer {
            activeAuthSession = nil
            activeContextProvider = nil
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(Self.callbackScheme)
            ) { callbackURL, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: StravaAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: StravaAuthError.invalidCallback)
                }
            }
            let provider = StravaAuthPresentationContextProvider()
            session.presentationContextProvider = provider
            activeAuthSession = session
            activeContextProvider = provider
            if !session.start() {
                continuation.resume(throwing: StravaAuthError.sessionFailedToStart)
            }
        }
    }

    private func appCredentials(_ credentials: StravaCredentials) -> StravaAppCredentials {
        StravaAppCredentials(clientId: credentials.clientID, clientSecret: credentials.clientSecret)
    }
}

// MARK: - Presentation anchor

/// Anchors the ASWebAuthenticationSession sheet to the app's key window.
private final class StravaAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}
