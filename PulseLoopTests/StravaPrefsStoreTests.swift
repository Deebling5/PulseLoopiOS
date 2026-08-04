import XCTest
@testable import PulseLoop

/// Coverage for `StravaPrefsStore`: privacy-first defaults, round-trip persistence through an
/// isolated `UserDefaults` suite, tolerant decode of partial blobs, watermark stamping, and full
/// reset. Hermetic — no network, no Strava API objects.
@MainActor
final class StravaPrefsStoreTests: XCTestCase {

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    // MARK: - Defaults

    func testDefaultsAreOffAndManual() {
        let store = StravaPrefsStore(defaults: makeSuite())
        XCTAssertFalse(store.prefs.masterEnabled, "privacy-first: no uploads until the user opts in")
        XCTAssertEqual(store.prefs.uploadMode, .manual, "automatic uploads are a second opt-in")
        XCTAssertNil(store.state.uploadedThrough)
        XCTAssertNil(store.state.automaticSince)
        XCTAssertNil(store.state.lastUploadAt)
        XCTAssertNil(store.state.lastUploadSummary)
        XCTAssertNil(store.state.athleteName)
        XCTAssertNil(store.state.athleteId)
    }

    // MARK: - Persistence round-trip

    func testPrefsAndStateRoundTripThroughDefaults() {
        let suite = makeSuite()
        // Whole-second date so JSON Double encoding round-trips exactly.
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let store = StravaPrefsStore(defaults: suite)
        store.prefs.masterEnabled = true
        store.prefs.uploadMode = .automatic
        var state = store.state
        state.lastUploadAt = now
        state.lastUploadSummary = "Uploaded 1 run"
        state.athleteName = "Test Athlete"
        state.athleteId = 12345
        store.state = state

        // A fresh store over the same suite must see the persisted values.
        let reloaded = StravaPrefsStore(defaults: suite)
        XCTAssertTrue(reloaded.prefs.masterEnabled)
        XCTAssertEqual(reloaded.prefs.uploadMode, .automatic)
        XCTAssertEqual(reloaded.state.lastUploadAt, now)
        XCTAssertEqual(reloaded.state.lastUploadSummary, "Uploaded 1 run")
        XCTAssertEqual(reloaded.state.athleteName, "Test Athlete")
        XCTAssertEqual(reloaded.state.athleteId, 12345)
    }

    // MARK: - Tolerant decode

    func testTolerantDecodeOfPartialPrefsBlob() {
        let suite = makeSuite()
        // Blob written by a hypothetical older build lacking `uploadMode`.
        let partial = """
        {"masterEnabled": true}
        """
        suite.set(Data(partial.utf8), forKey: "pulseloop.strava.prefs.v1")

        let store = StravaPrefsStore(defaults: suite)
        XCTAssertTrue(store.prefs.masterEnabled, "present key decodes")
        XCTAssertEqual(store.prefs.uploadMode, .manual, "missing key falls back to default")
    }

    func testTolerantDecodeOfPartialStateBlob() {
        let suite = makeSuite()
        let partial = """
        {"athleteId": 777}
        """
        suite.set(Data(partial.utf8), forKey: "pulseloop.strava.state.v1")

        let store = StravaPrefsStore(defaults: suite)
        XCTAssertEqual(store.state.athleteId, 777)
        XCTAssertNil(store.state.uploadedThrough, "missing keys fall back to defaults, no throw")
        XCTAssertNil(store.state.automaticSince)
        XCTAssertNil(store.state.athleteName)
    }

    // MARK: - Watermarks

    func testStampWatermarksSetsBothDates() {
        let store = StravaPrefsStore(defaults: makeSuite())
        let now = Date()
        store.stampWatermarks(to: now)
        XCTAssertEqual(store.state.uploadedThrough, now)
        XCTAssertEqual(store.state.automaticSince, now)
    }

    // MARK: - Reset

    func testResetAllRestoresDefaultsAndRemovesKeys() {
        let suite = makeSuite()
        let store = StravaPrefsStore(defaults: suite)
        store.prefs.masterEnabled = true
        store.prefs.uploadMode = .automatic
        store.stampWatermarks(to: Date())

        store.resetAll()

        XCTAssertEqual(store.prefs, .default)
        XCTAssertEqual(store.state, .default)
        XCTAssertNil(suite.data(forKey: "pulseloop.strava.prefs.v1"), "prefs blob removed")
        XCTAssertNil(suite.data(forKey: "pulseloop.strava.state.v1"), "state blob removed")

        // A fresh store over the wiped suite comes up with pristine defaults.
        let reloaded = StravaPrefsStore(defaults: suite)
        XCTAssertFalse(reloaded.prefs.masterEnabled)
        XCTAssertEqual(reloaded.prefs.uploadMode, .manual)
    }
}
