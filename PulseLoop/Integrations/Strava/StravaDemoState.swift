import Foundation

/// Test-tooling hook: the `-demoStravaConnected YES` launch arg fakes a connected Strava account so
/// UI smoke tests can exercise the settings screen and upload rows without a real OAuth flow.
/// Must run BEFORE the first `StravaAuthService.shared` access — the service derives its connection
/// state from the token store at init.
enum StravaDemoState {
    @MainActor
    static func apply() {
        #if DEBUG
        let tokens = StravaTokens(
            accessToken: "demo",
            refreshToken: "demo",
            expiresAt: .now + 365 * 24 * 3600,
            athleteId: 1,
            athleteName: "Demo Athlete"
        )
        try? StravaKeychainTokenStore().save(tokens)
        StravaPrefsStore.shared.prefs.masterEnabled = true
        StravaPrefsStore.shared.state.athleteName = "Demo Athlete"
        #endif
    }
}
