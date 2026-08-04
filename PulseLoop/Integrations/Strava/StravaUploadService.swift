import Foundation
import OSLog
import SwiftData

// MARK: - Token provider contract

/// What the uploader needs from the auth layer. `StravaAuthService` conforms; tests inject a stub.
/// MainActor-isolated by the project default, matching both implementations.
protocol StravaTokenProviding: AnyObject {
    var isConnected: Bool { get }
    func validAccessToken() async throws -> String
}

// MARK: - Upload service

/// Uploads finished `ActivitySession`s to Strava as TCX files (falling back to a manual activity
/// when a session has no emittable trackpoints) and tracks per-session progress for the UI.
///
/// Two entry points:
/// - `upload(session:context:)` — user-initiated, per workout.
/// - `uploadNewFinished(context:)` — the automatic pass, watermarked on `updatedAt` with the same
///   contiguous-advance discipline as the HealthKit workout exporter: a failing session *stops*
///   the pass rather than being skipped, so it is retried next run.
@MainActor
@Observable
final class StravaUploadService {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = StravaUploadService()

    /// Sessions with an upload in flight (drives per-row spinners).
    var uploadingSessionIds: Set<UUID> = []
    /// Most recent upload failure per session, cleared on retry.
    var lastErrorBySession: [UUID: String] = [:]

    @ObservationIgnored private let client: StravaAPIClient
    @ObservationIgnored private let prefs: StravaPrefsStore
    @ObservationIgnored private var resolvedTokenProvider: StravaTokenProviding?
    @ObservationIgnored private var autoPassRunning = false

    /// Poll cadence for Strava's async upload processing. Internal so tests avoid real sleeps.
    @ObservationIgnored var pollNanoseconds: UInt64 = 2_000_000_000
    /// Delay before re-asserting sport_type when Strava's post-processing overwrote it.
    @ObservationIgnored var sportFixRetryNanoseconds: UInt64 = 3_000_000_000
    private static let log = Logger(subsystem: "xyz.sakshambhutani.pulseloop2", category: "StravaSync")
    @ObservationIgnored var maxPollAttempts = 15

    init(
        client: StravaAPIClient = StravaHTTPClient(),
        tokenProvider: StravaTokenProviding? = nil,
        prefs: StravaPrefsStore = .shared
    ) {
        self.client = client
        self.resolvedTokenProvider = tokenProvider
        self.prefs = prefs
    }

    /// Resolved lazily so `StravaUploadService.shared` and `StravaAuthService.shared` never
    /// initialize each other during their own `init` (init-order cycle).
    private var tokenProvider: StravaTokenProviding {
        if let resolvedTokenProvider { return resolvedTokenProvider }
        let provider = StravaAuthService.shared
        resolvedTokenProvider = provider
        return provider
    }

    // MARK: - Manual upload

    /// User-initiated upload of one session. No-ops silently when the session is already on
    /// Strava or an upload for it is already in flight; failures land in `lastErrorBySession`.
    func upload(session: ActivitySession, context: ModelContext) async {
        guard !uploadingSessionIds.contains(session.id), session.stravaActivityId == nil else { return }
        uploadingSessionIds.insert(session.id)
        lastErrorBySession[session.id] = nil
        defer { uploadingSessionIds.remove(session.id) }
        do {
            try await performUpload(session: session, context: context)
        } catch {
            lastErrorBySession[session.id] = Self.describe(error)
        }
    }

    // MARK: - Automatic pass

    /// Uploads every not-yet-uploaded finished session past the watermark. Returns false only
    /// when another pass is already in flight (so callers can reschedule); a completed pass —
    /// even one stopped early by a failure — returns true.
    func uploadNewFinished(context: ModelContext) async -> Bool {
        guard !autoPassRunning else { return false }
        guard prefs.prefs.masterEnabled,
              prefs.prefs.uploadMode == .automatic,
              tokenProvider.isConnected else { return true }
        autoPassRunning = true
        defer { autoPassRunning = false }

        // Ascending `updatedAt` against a single scalar watermark — the watermark may only
        // advance over a contiguous run of handled sessions (mirrors HealthSyncService+Workouts).
        for session in pendingSessions(context: context) {
            let automaticSince = prefs.state.automaticSince ?? .distantFuture
            if session.stravaActivityId != nil || (session.endedAt ?? .distantPast) < automaticSince {
                // Already uploaded, or finished before automatic mode was enabled — never
                // auto-uploaded, so the watermark can move past it.
                advanceWatermark(to: session.updatedAt)
                continue
            }
            guard !uploadingSessionIds.contains(session.id) else { break }   // manual upload racing; retry next pass
            uploadingSessionIds.insert(session.id)
            lastErrorBySession[session.id] = nil
            do {
                try await performUpload(session: session, context: context)
                uploadingSessionIds.remove(session.id)
                advanceWatermark(to: session.updatedAt)
            } catch {
                uploadingSessionIds.remove(session.id)
                lastErrorBySession[session.id] = Self.describe(error)
                // Stop without advancing (covers rate limiting too) so a later success can't
                // leapfrog the watermark past this session — it retries next pass.
                break
            }
        }
        return true
    }

    private func pendingSessions(context: ModelContext) -> [ActivitySession] {
        let watermark = prefs.state.uploadedThrough ?? .distantPast
        let finishedRaw = ActivitySessionStatus.finished.rawValue
        let descriptor = FetchDescriptor<ActivitySession>(
            predicate: #Predicate { $0.statusRaw == finishedRaw && $0.endedAt != nil && $0.updatedAt > watermark },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func advanceWatermark(to date: Date) {
        var next = prefs.state
        next.uploadedThrough = date
        prefs.state = next
    }

    // MARK: - Single-session core

    private func performUpload(session: ActivitySession, context: ModelContext) async throws {
        let token = try await tokenProvider.validAccessToken()
        let name = Self.activityName(for: session)
        if let tcx = assembleTCX(session: session, context: context) {
            let initial = try await client.startUpload(
                tcx: Data(tcx.utf8),
                fileName: "\(session.id.uuidString).tcx",
                name: name,
                description: session.notes,
                trainer: !session.useGps,
                externalId: session.id.uuidString,
                accessToken: token
            )
            let activityId = try await pollUpload(initial: initial, accessToken: token)
            await fixSportTypeIfNeeded(session: session, activityId: activityId, accessToken: token)
            finalizeSuccess(session: session, activityId: activityId, name: name, context: context)
        } else {
            // No emittable trackpoints (no accepted GPS route, no HR) — create a bare manual
            // activity so the workout still lands on Strava. Carries the exact sport_type, so
            // no follow-up update is needed.
            let ended = session.endedAt ?? session.startedAt
            let elapsed = max(0, Int(ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
            let summary = try await client.createManualActivity(
                name: name,
                sportType: StravaSportMapping.sportType(for: session.type),
                startDateLocalISO8601: Self.localISO8601(session.startedAt),
                elapsedSeconds: elapsed,
                description: session.notes,
                distanceMeters: session.distanceMeters,
                trainer: !session.useGps,
                accessToken: token
            )
            finalizeSuccess(session: session, activityId: String(summary.id), name: name, context: context)
        }
    }

    /// Reads the session's persisted rows and builds the TCX document; nil when the session
    /// has nothing emittable (the manual-activity fallback then applies).
    private func assembleTCX(session: ActivitySession, context: ModelContext) -> String? {
        guard let endedAt = session.endedAt else { return nil }
        let gps = ActivityRepository.gpsPoints(sessionId: session.id, context: context)
            .filter(\.accepted)
            .sorted { $0.timestamp < $1.timestamp }
            .map { StravaTrackFix(timestamp: $0.timestamp, latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude) }
        let hrKind = MeasurementKind.heartRate.rawValue
        let hr = ActivityRepository.samples(sessionId: session.id, context: context)
            .filter { $0.kind == hrKind && $0.value > 0 }
            .sorted { $0.timestamp < $1.timestamp }
            .map { (timestamp: $0.timestamp, bpm: Int($0.value.rounded())) }
        let events = ActivityRepository.events(sessionId: session.id, context: context)
            .map { (kind: $0.kind, timestamp: $0.timestamp) }
        let pauses = StravaTCXBuilder.pauseIntervals(events: events, endedAt: endedAt)
        return StravaTCXBuilder.build(session: session, hrSamples: hr, gpsPoints: gps, pauseIntervals: pauses)
    }

    /// Polls Strava's async upload processing until it yields an activity id (or a duplicate),
    /// checking the initial response first so an already-terminal status never sleeps.
    private func pollUpload(initial: StravaUploadStatus, accessToken: String) async throws -> String {
        var status = initial
        var attempts = 0
        while true {
            if let terminal = try Self.terminalResult(status) { return terminal }
            attempts += 1
            guard attempts <= maxPollAttempts else {
                throw StravaError.uploadProcessingFailed("Timed out waiting for Strava to process the upload.")
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
            status = try await client.uploadStatus(id: status.id, accessToken: accessToken)
        }
    }

    /// nil = still processing. A duplicate error resolves to the existing activity's id when
    /// Strava's message contains one ("duplicate" otherwise) — the workout *is* on Strava, so
    /// it is treated as uploaded rather than surfaced as a failure.
    private static func terminalResult(_ status: StravaUploadStatus) throws -> String? {
        if let error = status.error, !error.isEmpty {
            if error.localizedCaseInsensitiveContains("duplicate") {
                return StravaHTTPClient.parseDuplicate(from: error) ?? "duplicate"
            }
            throw StravaError.uploadProcessingFailed(error)
        }
        if let activityId = status.activityId { return String(activityId) }
        return nil
    }

    /// TCX can only carry Running/Biking/Other, so most sports need a follow-up sport_type
    /// update. Strava re-derives the type from the file shortly after processing, which can
    /// overwrite an immediate update — so verify what Strava reports back and retry once after
    /// a delay. Best-effort — the upload already succeeded, so a final failure is only logged.
    private func fixSportTypeIfNeeded(session: ActivitySession, activityId: String, accessToken: String) async {
        guard StravaSportMapping.needsSportTypeFix(for: session.type),
              let numericId = Int64(activityId) else { return }   // "duplicate" placeholder has no numeric id
        let desired = StravaSportMapping.sportType(for: session.type)
        for attempt in 1...2 {
            if attempt > 1 { try? await Task.sleep(nanoseconds: sportFixRetryNanoseconds) }
            do {
                let applied = try await client.updateActivity(id: numericId, sportType: desired, accessToken: accessToken)
                if applied == desired || applied == nil {
                    // nil = response unparseable; assume the 2xx meant it stuck.
                    return
                }
                Self.log.notice("sport_type fix attempt \(attempt): Strava reports \(applied ?? "?", privacy: .public), wanted \(desired, privacy: .public)")
            } catch {
                Self.log.error("sport_type update failed (attempt \(attempt)): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func finalizeSuccess(session: ActivitySession, activityId: String, name: String, context: ModelContext) {
        session.stravaActivityId = activityId
        var next = prefs.state
        next.lastUploadAt = Date()
        next.lastUploadSummary = name
        prefs.state = next
        try? context.save()
    }

    // MARK: - Naming & formatting

    /// Strava-style time-of-day name, e.g. "Morning Run" — deliberately unbranded.
    static func activityName(for session: ActivitySession) -> String {
        let hour = Calendar.current.component(.hour, from: session.startedAt)
        let period: String
        switch hour {
        case 4..<11: period = "Morning"
        case 11..<14: period = "Lunch"
        case 14..<18: period = "Afternoon"
        case 18..<22: period = "Evening"
        default: period = "Night"
        }
        return "\(period) \(ActivityMeta.label(session.type))"
    }

    /// Local wall-clock time with the device's UTC offset, as Strava's `start_date_local` expects.
    private static func localISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func describe(_ error: Error) -> String {
        (error as? StravaError)?.errorDescription ?? error.localizedDescription
    }
}
