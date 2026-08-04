import Foundation

/// How finished workouts reach Strava:
/// - `.manual` — the user taps "Upload to Strava" per workout (default; nothing leaves the device on its own).
/// - `.automatic` — every workout finished after `StravaSyncState.automaticSince` uploads on save.
enum StravaUploadMode: String, Codable {
    case manual
    case automatic
}

/// User-tunable Strava upload preferences, persisted as JSON in `UserDefaults`.
///
/// Privacy-first: `masterEnabled` defaults to **false** — nothing uploads to Strava until the user
/// explicitly connects their account. Mirrors the `AppleHealthPrefsStore` pattern — no SwiftData, no
/// migration — with tolerant decode so adding a future key never wipes an existing user's blob.
struct StravaPrefs: Codable, Equatable {
    /// Master opt-in. Default **false** — no Strava uploads happen while this is off.
    var masterEnabled = false
    /// Upload trigger. Default `.manual` so automatic uploads are a deliberate second opt-in.
    var uploadMode: StravaUploadMode = .manual

    static let `default` = StravaPrefs()

    init() {}

    /// Tolerant decode: any missing key falls back to its default, so a stored blob written by an older
    /// build (lacking a newer key) is never discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StravaPrefs.default
        masterEnabled = try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? d.masterEnabled
        uploadMode = try c.decodeIfPresent(StravaUploadMode.self, forKey: .uploadMode) ?? d.uploadMode
    }
}

/// Upload progress + connected-athlete identity, tracked entirely in the prefs store so no SwiftData
/// model or schema ever changes.
///
/// Watermarks:
/// - `uploadedThrough` — high-water mark on `ActivitySession.endedAt`; sessions ending at or before it
///   are considered already offered/uploaded.
/// - `automaticSince` — the instant automatic mode was enabled; only sessions finishing after it
///   auto-upload, so enabling automatic mode never bulk-uploads history.
struct StravaSyncState: Codable, Equatable {
    var uploadedThrough: Date?
    var automaticSince: Date?
    var lastUploadAt: Date?
    var lastUploadSummary: String?
    /// Display name of the connected athlete (shown in settings).
    var athleteName: String?
    /// Strava athlete id of the connected account.
    var athleteId: Int?

    static let `default` = StravaSyncState()

    init() {}

    /// Tolerant decode: missing keys fall back to defaults so a partial/older blob survives.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StravaSyncState.default
        uploadedThrough = try c.decodeIfPresent(Date.self, forKey: .uploadedThrough) ?? d.uploadedThrough
        automaticSince = try c.decodeIfPresent(Date.self, forKey: .automaticSince) ?? d.automaticSince
        lastUploadAt = try c.decodeIfPresent(Date.self, forKey: .lastUploadAt) ?? d.lastUploadAt
        lastUploadSummary = try c.decodeIfPresent(String.self, forKey: .lastUploadSummary) ?? d.lastUploadSummary
        athleteName = try c.decodeIfPresent(String.self, forKey: .athleteName) ?? d.athleteName
        athleteId = try c.decodeIfPresent(Int.self, forKey: .athleteId) ?? d.athleteId
    }
}

/// Observable, `UserDefaults`-backed store for Strava preferences and upload watermarks.
///
/// Follows the `AppleHealthPrefsStore` pattern. Uses **two independent storage keys** so that frequent
/// watermark writes (every upload) never rewrite the user's preference blob and vice-versa:
/// - `prefs` → `"pulseloop.strava.prefs.v1"`
/// - `state` → `"pulseloop.strava.state.v1"`
///
/// Each property persists on `didSet`. Reads happen at use-time so a settings change applies to the
/// next upload.
@MainActor
@Observable
final class StravaPrefsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = StravaPrefsStore()

    private static let prefsKey = "pulseloop.strava.prefs.v1"
    private static let stateKey = "pulseloop.strava.state.v1"
    private let defaults: UserDefaults

    /// User-facing upload preferences. Master toggle defaults **off** (privacy-first).
    var prefs: StravaPrefs {
        didSet { persist(prefs, forKey: Self.prefsKey) }
    }

    /// Upload watermarks, last-upload summary, and connected-athlete identity.
    var state: StravaSyncState {
        didSet { persist(state, forKey: Self.stateKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = Self.load(StravaPrefs.self, forKey: Self.prefsKey, from: defaults) ?? .default
        self.state = Self.load(StravaSyncState.self, forKey: Self.stateKey, from: defaults) ?? .default
    }

    /// Stamp both watermarks to `date` in one atomic write, so enabling automatic mode marks all
    /// pre-existing sessions as already handled and only future workouts auto-upload.
    func stampWatermarks(to date: Date) {
        var next = state
        next.uploadedThrough = date
        next.automaticSince = date
        state = next
    }

    /// Restore defaults and remove both persisted blobs (used on account disconnect).
    func resetAll() {
        prefs = .default
        state = .default
        defaults.removeObject(forKey: Self.prefsKey)
        defaults.removeObject(forKey: Self.stateKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
