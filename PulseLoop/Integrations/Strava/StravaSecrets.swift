import Foundation

/// Loader for the developer-supplied Strava API credentials.
///
/// Strava requires every app to register its own API application, so the client id/secret are **not**
/// checked into the repo. To enable the Strava integration locally:
///
/// 1. Register an API app at https://www.strava.com/settings/api and set the
///    **Authorization Callback Domain** to `localhost`.
/// 2. Create `PulseLoop/Integrations/Strava/StravaSecrets.plist` (it is gitignored) containing two
///    string keys:
///    - `StravaClientID` — the numeric client id from the API settings page.
///    - `StravaClientSecret` — the client secret from the same page.
///
/// The plist lives inside the synchronized `PulseLoop/` group, so Xcode bundles it automatically.
/// When the file is missing (or either value is blank) `StravaSecrets.load()` returns `nil` and the
/// UI should present the integration as unconfigured rather than crash.

/// The pair of credentials Strava's OAuth token endpoints require.
struct StravaCredentials {
    let clientID: String
    let clientSecret: String
}

enum StravaSecrets {
    private static let plistName = "StravaSecrets"
    private static let clientIDKey = "StravaClientID"
    private static let clientSecretKey = "StravaClientSecret"

    /// Read credentials from `StravaSecrets.plist` in the given bundle.
    ///
    /// Returns `nil` when the plist is absent or either key is missing/blank — callers treat that as
    /// "integration not configured".
    static func load(bundle: Bundle = .main) -> StravaCredentials? {
        guard let url = bundle.url(forResource: plistName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }
        guard let clientID = nonBlankString(dict[clientIDKey]),
              let clientSecret = nonBlankString(dict[clientSecretKey]) else {
            return nil
        }
        return StravaCredentials(clientID: clientID, clientSecret: clientSecret)
    }

    private static func nonBlankString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
