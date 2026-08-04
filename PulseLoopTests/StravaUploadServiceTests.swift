import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

// MARK: - Fakes

/// Recording fake for `StravaAPIClient`. Nonisolated to match the protocol's isolation; tests
/// drive it single-threaded, so unsynchronized state is fine.
nonisolated private final class StravaClientSpy: StravaAPIClient, @unchecked Sendable {
    struct StartUploadCall {
        let fileName: String
        let name: String
        let description: String?
        let trainer: Bool
        let externalId: String
        let accessToken: String
    }

    struct CreateManualCall {
        let name: String
        let sportType: String
        let elapsedSeconds: Int
        let trainer: Bool
        let accessToken: String
    }

    var startUploadCalls: [StartUploadCall] = []
    var createManualCalls: [CreateManualCall] = []
    var updateActivityCalls: [(id: Int64, sportType: String)] = []
    var statusCallCount = 0

    /// Consumed FIFO, one per `startUpload`; falls back to `defaultStartStatus` when empty.
    var startUploadResults: [Result<StravaUploadStatus, Error>] = []
    var defaultStartStatus = StravaUploadStatus(
        id: 1, idStr: "1", externalId: nil, error: nil, status: "ready", activityId: 42
    )
    var statusResults: [StravaUploadStatus] = []
    var manualActivityId: Int64 = 777

    /// When true, `startUpload` suspends until `resumeHungStart()` (hung-pass test).
    var hangOnStartUpload = false
    var pendingStart: CheckedContinuation<Void, Never>?

    func resumeHungStart() {
        pendingStart?.resume()
        pendingStart = nil
    }

    func exchangeCode(code: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse {
        throw StravaError.invalidResponse
    }

    func refreshToken(_ refreshToken: String, credentials: StravaAppCredentials) async throws -> StravaTokenResponse {
        throw StravaError.invalidResponse
    }

    func deauthorize(accessToken: String) async throws {}

    func startUpload(
        tcx: Data,
        fileName: String,
        name: String,
        description: String?,
        trainer: Bool,
        externalId: String,
        accessToken: String
    ) async throws -> StravaUploadStatus {
        startUploadCalls.append(StartUploadCall(
            fileName: fileName, name: name, description: description,
            trainer: trainer, externalId: externalId, accessToken: accessToken
        ))
        if hangOnStartUpload {
            await withCheckedContinuation { pendingStart = $0 }
        }
        if !startUploadResults.isEmpty { return try startUploadResults.removeFirst().get() }
        return defaultStartStatus
    }

    func uploadStatus(id: Int64, accessToken: String) async throws -> StravaUploadStatus {
        statusCallCount += 1
        if !statusResults.isEmpty { return statusResults.removeFirst() }
        return defaultStartStatus
    }

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
        createManualCalls.append(CreateManualCall(
            name: name, sportType: sportType, elapsedSeconds: elapsedSeconds,
            trainer: trainer, accessToken: accessToken
        ))
        return StravaActivitySummary(id: manualActivityId)
    }

    /// Consumed FIFO, one per `updateActivity`; empty = echo the requested sport back (applied).
    var updateActivityResults: [String?] = []

    func updateActivity(id: Int64, sportType: String, accessToken: String) async throws -> String? {
        updateActivityCalls.append((id: id, sportType: sportType))
        if !updateActivityResults.isEmpty { return updateActivityResults.removeFirst() }
        return sportType
    }
}

@MainActor
private final class TokenProviderStub: StravaTokenProviding {
    var isConnected = true
    var tokensVended = 0

    func validAccessToken() async throws -> String {
        tokensVended += 1
        return "tok"
    }
}

// MARK: - Tests

@MainActor
final class StravaUploadServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    /// Prefs store on an isolated, wiped defaults suite.
    private func makePrefs() -> StravaPrefsStore {
        let suite = "strava-upload-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return StravaPrefsStore(defaults: defaults)
    }

    private func makeService(
        client: StravaClientSpy,
        provider: TokenProviderStub,
        prefs: StravaPrefsStore
    ) -> StravaUploadService {
        let service = StravaUploadService(client: client, tokenProvider: provider, prefs: prefs)
        service.pollNanoseconds = 1   // no real sleeps in tests
        return service
    }

    private func enableAutomatic(_ prefs: StravaPrefsStore, since: Date) {
        var p = prefs.prefs
        p.masterEnabled = true
        p.uploadMode = .automatic
        prefs.prefs = p
        var s = prefs.state
        s.automaticSince = since
        prefs.state = s
    }

    @discardableResult
    private func makeSession(
        context: ModelContext,
        type: String = "run",
        duration: TimeInterval = 600,
        updatedAt: Date? = nil,
        useGps: Bool = false
    ) throws -> ActivitySession {
        let session = ActivitySession(type: type, status: .finished, startedAt: t0, useGps: useGps)
        session.endedAt = date(duration)
        if let updatedAt { session.updatedAt = updatedAt }
        context.insert(session)
        try context.save()
        return session
    }

    private func insertHR(_ session: ActivitySession, offsets: [TimeInterval], context: ModelContext) throws {
        for offset in offsets {
            context.insert(ActivitySample(
                sessionId: session.id, kind: MeasurementKind.heartRate.rawValue,
                value: 120, unit: "bpm", timestamp: date(offset)
            ))
        }
        try context.save()
    }

    // MARK: Manual upload

    func testWalkUploadPersistsIdAndFixesSportType() async throws {
        let context = try TestSupport.makeContext()
        let session = try makeSession(context: context, type: "walk")
        try insertHR(session, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        let service = makeService(client: client, provider: provider, prefs: prefs)

        await service.upload(session: session, context: context)

        XCTAssertEqual(session.stravaActivityId, "42")
        XCTAssertEqual(client.startUploadCalls.count, 1)
        let call = try XCTUnwrap(client.startUploadCalls.first)
        XCTAssertEqual(call.fileName, "\(session.id.uuidString).tcx")
        XCTAssertEqual(call.externalId, session.id.uuidString)
        XCTAssertTrue(call.name.hasSuffix(" Walk"))   // time-of-day prefix depends on local tz
        XCTAssertTrue(call.trainer)                   // useGps false → trainer
        XCTAssertEqual(call.accessToken, "tok")
        // TCX Sport for a walk is "Other" → follow-up sport_type fix required.
        XCTAssertEqual(client.updateActivityCalls.count, 1)
        XCTAssertEqual(client.updateActivityCalls.first?.id, 42)
        XCTAssertEqual(client.updateActivityCalls.first?.sportType, "Walk")
        XCTAssertNotNil(prefs.state.lastUploadAt)
        XCTAssertEqual(prefs.state.lastUploadSummary, call.name)
        XCTAssertNil(service.lastErrorBySession[session.id])
        XCTAssertTrue(service.uploadingSessionIds.isEmpty)
    }

    func testSportTypeFixRetriesWhenStravaOverwritesIt() async throws {
        let context = try TestSupport.makeContext()
        let session = try makeSession(context: context, type: "squash")
        try insertHR(session, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        let service = makeService(client: client, provider: provider, prefs: prefs)
        service.sportFixRetryNanoseconds = 1
        // Strava's post-upload processing can overwrite the first update (it reports the
        // derived type back); the delayed second attempt sticks.
        client.updateActivityResults = ["Run", "Squash"]

        await service.upload(session: session, context: context)

        XCTAssertEqual(client.updateActivityCalls.count, 2)
        XCTAssertEqual(client.updateActivityCalls.last?.sportType, "Squash")
        XCTAssertEqual(session.stravaActivityId, "42")
    }

    func testRunUploadSkipsSportTypeFix() async throws {
        let context = try TestSupport.makeContext()
        let session = try makeSession(context: context, type: "run")
        try insertHR(session, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        let service = makeService(client: client, provider: provider, prefs: prefs)

        await service.upload(session: session, context: context)

        XCTAssertEqual(session.stravaActivityId, "42")
        XCTAssertTrue(client.updateActivityCalls.isEmpty)   // TCX Sport "Running" is already right
    }

    func testDuplicateErrorResolvesToParsedActivityId() async throws {
        let context = try TestSupport.makeContext()
        let session = try makeSession(context: context, type: "run")
        try insertHR(session, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        client.startUploadResults = [.success(StravaUploadStatus(
            id: 9, idStr: "9", externalId: nil,
            error: "workout.tcx is a duplicate of activity 987654", status: "error", activityId: nil
        ))]
        let service = makeService(client: client, provider: provider, prefs: prefs)

        await service.upload(session: session, context: context)

        XCTAssertEqual(session.stravaActivityId, "987654")
        XCTAssertNil(service.lastErrorBySession[session.id])   // duplicate == already uploaded, not a failure
        XCTAssertEqual(client.statusCallCount, 0)              // terminal on the initial response
    }

    func testAlreadyUploadedSessionMakesNoClientCalls() async throws {
        let context = try TestSupport.makeContext()
        let session = try makeSession(context: context, type: "run")
        session.stravaActivityId = "111"
        try context.save()
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        let service = makeService(client: client, provider: provider, prefs: prefs)

        await service.upload(session: session, context: context)

        XCTAssertEqual(session.stravaActivityId, "111")
        XCTAssertTrue(client.startUploadCalls.isEmpty)
        XCTAssertTrue(client.createManualCalls.isEmpty)
        XCTAssertEqual(provider.tokensVended, 0)
    }

    func testEmptySessionFallsBackToManualActivity() async throws {
        let context = try TestSupport.makeContext()
        let session = try makeSession(context: context, type: "gym")   // no HR, no GPS → no TCX
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        let service = makeService(client: client, provider: provider, prefs: prefs)

        await service.upload(session: session, context: context)

        XCTAssertTrue(client.startUploadCalls.isEmpty)
        XCTAssertEqual(client.createManualCalls.count, 1)
        let call = try XCTUnwrap(client.createManualCalls.first)
        XCTAssertEqual(call.sportType, "WeightTraining")
        XCTAssertEqual(call.elapsedSeconds, 600)
        XCTAssertEqual(session.stravaActivityId, "777")
        // Manual create carries the exact sport_type — no follow-up fix.
        XCTAssertTrue(client.updateActivityCalls.isEmpty)
    }

    // MARK: Automatic pass

    func testAutoPassSkipsSessionsFinishedBeforeAutomaticSince() async throws {
        let context = try TestSupport.makeContext()
        // Ended at t0+600, but automatic mode enabled later — must never bulk-upload history.
        let session = try makeSession(context: context, updatedAt: date(2_000))
        try insertHR(session, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        enableAutomatic(prefs, since: date(1_000))
        let service = makeService(client: client, provider: provider, prefs: prefs)

        let finished = await service.uploadNewFinished(context: context)

        XCTAssertTrue(finished)
        XCTAssertTrue(client.startUploadCalls.isEmpty)
        XCTAssertTrue(client.createManualCalls.isEmpty)
        XCTAssertNil(session.stravaActivityId)
        // Skipped-but-handled: watermark still advances over it.
        XCTAssertEqual(prefs.state.uploadedThrough, session.updatedAt)
    }

    func testAutoPassStopsAtFirstFailureWithoutAdvancingWatermark() async throws {
        let context = try TestSupport.makeContext()
        let failing = try makeSession(context: context, updatedAt: date(1_100))
        try insertHR(failing, offsets: [10, 20], context: context)
        let later = try makeSession(context: context, updatedAt: date(1_200))
        try insertHR(later, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        client.startUploadResults = [.failure(StravaError.http(status: 500, body: "boom"))]
        enableAutomatic(prefs, since: date(-1_000))
        let service = makeService(client: client, provider: provider, prefs: prefs)

        let finished = await service.uploadNewFinished(context: context)

        XCTAssertTrue(finished)
        // Only the failing session was attempted; the later one must not leapfrog it.
        XCTAssertEqual(client.startUploadCalls.count, 1)
        XCTAssertNil(failing.stravaActivityId)
        XCTAssertNil(later.stravaActivityId)
        XCTAssertNil(prefs.state.uploadedThrough)
        XCTAssertNotNil(service.lastErrorBySession[failing.id])

        // Next pass retries the failed session first (watermark stayed put).
        _ = await service.uploadNewFinished(context: context)
        XCTAssertEqual(failing.stravaActivityId, "42")
        XCTAssertEqual(later.stravaActivityId, "42")
        XCTAssertEqual(prefs.state.uploadedThrough, later.updatedAt)
    }

    func testRateLimitedStopsPassImmediately() async throws {
        let context = try TestSupport.makeContext()
        let first = try makeSession(context: context, updatedAt: date(1_100))
        try insertHR(first, offsets: [10, 20], context: context)
        let second = try makeSession(context: context, updatedAt: date(1_200))
        try insertHR(second, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        client.startUploadResults = [.failure(StravaError.rateLimited)]
        enableAutomatic(prefs, since: date(-1_000))
        let service = makeService(client: client, provider: provider, prefs: prefs)

        let finished = await service.uploadNewFinished(context: context)

        XCTAssertTrue(finished)
        XCTAssertEqual(client.startUploadCalls.count, 1)   // second session never attempted
        XCTAssertNil(first.stravaActivityId)
        XCTAssertNil(second.stravaActivityId)
        XCTAssertNil(prefs.state.uploadedThrough)
    }

    func testUploadNewFinishedReturnsFalseWhilePassInFlight() async throws {
        let context = try TestSupport.makeContext()
        let session = try makeSession(context: context, updatedAt: date(1_100))
        try insertHR(session, offsets: [10, 20], context: context)
        let (client, provider, prefs) = (StravaClientSpy(), TokenProviderStub(), makePrefs())
        client.hangOnStartUpload = true
        enableAutomatic(prefs, since: date(-1_000))
        let service = makeService(client: client, provider: provider, prefs: prefs)

        let firstPass = Task { await service.uploadNewFinished(context: context) }
        // Everything is MainActor — yielding lets the pass run until it suspends in startUpload.
        var spins = 0
        while client.pendingStart == nil {
            await Task.yield()
            spins += 1
            if spins > 10_000 { return XCTFail("pass never reached startUpload") }
        }

        let overlapping = await service.uploadNewFinished(context: context)
        XCTAssertFalse(overlapping)

        client.resumeHungStart()
        let firstResult = await firstPass.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(session.stravaActivityId, "42")

        // With the pass finished, a fresh call runs normally again.
        let afterwards = await service.uploadNewFinished(context: context)
        XCTAssertTrue(afterwards)
    }
}
