import Foundation
import XCTest
@testable import PulseLoop

@MainActor
final class StravaTCXBuilderTests: XCTestCase {
    // Fixed epoch so expected ISO strings are literal: 2023-11-14T22:13:20Z.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    /// Session persisted in a fresh in-memory store, ended `duration` seconds after t0.
    private func makeSession(type: String = "run", duration: TimeInterval = 600, pauseSeconds: Double = 0) throws -> ActivitySession {
        let context = try TestSupport.makeContext()
        let session = ActivitySession(type: type, status: .finished, startedAt: t0)
        session.endedAt = date(duration)
        session.totalPauseSeconds = pauseSeconds
        context.insert(session)
        try context.save()
        return session
    }

    /// The inner text of each <Trackpoint>…</Trackpoint> block, in document order.
    private func trackpointBlocks(_ tcx: String) -> [String] {
        tcx.components(separatedBy: "<Trackpoint>").dropFirst().map {
            $0.components(separatedBy: "</Trackpoint>").first ?? ""
        }
    }

    // MARK: - HR merge (GPS mode)

    func testGpsMergePicksLatestSampleAtOrBeforeTimestamp() throws {
        let session = try makeSession()
        let hr = [(timestamp: date(0), bpm: 100), (timestamp: date(25), bpm: 110)]
        let gps = [
            StravaTrackFix(timestamp: date(10), latitude: 12.0, longitude: 77.0, altitude: Double?.none),
            StravaTrackFix(timestamp: date(25), latitude: 12.0001, longitude: 77.0001, altitude: Double?.none),
            StravaTrackFix(timestamp: date(40), latitude: 12.0002, longitude: 77.0002, altitude: Double?.none)
        ]
        let tcx = try XCTUnwrap(StravaTCXBuilder.build(session: session, hrSamples: hr, gpsPoints: gps, pauseIntervals: []))
        let points = trackpointBlocks(tcx)
        XCTAssertEqual(points.count, 3)
        XCTAssertTrue(points[0].contains("<HeartRateBpm><Value>100</Value></HeartRateBpm>"))
        // A sample exactly at the point's timestamp counts as at-or-before.
        XCTAssertTrue(points[1].contains("<HeartRateBpm><Value>110</Value></HeartRateBpm>"))
        XCTAssertTrue(points[2].contains("<HeartRateBpm><Value>110</Value></HeartRateBpm>"))
    }

    func testGpsMergeOmitsHROlderThanStalenessWindow() throws {
        let session = try makeSession()
        let hr = [(timestamp: date(0), bpm: 95)]
        let gps = [
            StravaTrackFix(timestamp: date(60), latitude: 12.0, longitude: 77.0, altitude: Double?.none),  // exactly 60 s: still fresh
            StravaTrackFix(timestamp: date(61), latitude: 12.0001, longitude: 77.0001, altitude: Double?.none) // 61 s: stale
        ]
        let tcx = try XCTUnwrap(StravaTCXBuilder.build(session: session, hrSamples: hr, gpsPoints: gps, pauseIntervals: []))
        let points = trackpointBlocks(tcx)
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(points[0].contains("<HeartRateBpm><Value>95</Value></HeartRateBpm>"))
        XCTAssertFalse(points[1].contains("HeartRateBpm"))
    }

    func testGpsMergeIgnoresFutureSamples() throws {
        let session = try makeSession()
        let hr = [(timestamp: date(30), bpm: 120)]
        let gps = [
            StravaTrackFix(timestamp: date(10), latitude: 12.0, longitude: 77.0, altitude: Double?.none),
            StravaTrackFix(timestamp: date(35), latitude: 12.0001, longitude: 77.0001, altitude: Double?.none)
        ]
        let tcx = try XCTUnwrap(StravaTCXBuilder.build(session: session, hrSamples: hr, gpsPoints: gps, pauseIntervals: []))
        let points = trackpointBlocks(tcx)
        XCTAssertFalse(points[0].contains("HeartRateBpm"), "sample after the point must not be used")
        XCTAssertTrue(points[1].contains("<HeartRateBpm><Value>120</Value></HeartRateBpm>"))
    }

    // MARK: - Indoor mode

    func testIndoorEmitsTimeAndHROnlyWithNoPosition() throws {
        let session = try makeSession(type: "gym")
        let hr = [(timestamp: date(0), bpm: 90), (timestamp: date(120), bpm: 105)]
        // A single GPS fix is below the >=2 threshold, so this must still be indoor mode.
        let gps = [StravaTrackFix(timestamp: date(5), latitude: 12.0, longitude: 77.0, altitude: Double?.none)]
        let tcx = try XCTUnwrap(StravaTCXBuilder.build(session: session, hrSamples: hr, gpsPoints: gps, pauseIntervals: []))
        XCTAssertFalse(tcx.contains("<Position>"))
        XCTAssertFalse(tcx.contains("LatitudeDegrees"))
        let points = trackpointBlocks(tcx)
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(points[0].contains("<Time>2023-11-14T22:13:20Z</Time>"))
        XCTAssertTrue(points[0].contains("<HeartRateBpm><Value>90</Value></HeartRateBpm>"))
        XCTAssertTrue(points[1].contains("<HeartRateBpm><Value>105</Value></HeartRateBpm>"))
    }

    // MARK: - Pauses

    func testPauseIntervalDropsInteriorTrackpoints() throws {
        let session = try makeSession()
        let gps = [
            StravaTrackFix(timestamp: date(0), latitude: 12.0, longitude: 77.0, altitude: Double?.none),
            StravaTrackFix(timestamp: date(150), latitude: 12.0001, longitude: 77.0001, altitude: Double?.none), // inside pause
            StravaTrackFix(timestamp: date(300), latitude: 12.0002, longitude: 77.0002, altitude: Double?.none)
        ]
        let pause = [DateInterval(start: date(100), end: date(200))]
        let tcx = try XCTUnwrap(StravaTCXBuilder.build(session: session, hrSamples: [], gpsPoints: gps, pauseIntervals: pause))
        let points = trackpointBlocks(tcx)
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(points[0].contains("<Time>2023-11-14T22:13:20Z</Time>"))
        XCTAssertTrue(points[1].contains("<Time>2023-11-14T22:18:20Z</Time>"))
    }

    func testTotalTimeSecondsSubtractsPauseSeconds() throws {
        let session = try makeSession(duration: 600, pauseSeconds: 90)
        let gps = [
            StravaTrackFix(timestamp: date(0), latitude: 12.0, longitude: 77.0, altitude: Double?.none),
            StravaTrackFix(timestamp: date(600), latitude: 12.0001, longitude: 77.0001, altitude: Double?.none)
        ]
        let tcx = try XCTUnwrap(StravaTCXBuilder.build(session: session, hrSamples: [], gpsPoints: gps, pauseIntervals: []))
        XCTAssertTrue(tcx.contains("<TotalTimeSeconds>510.0</TotalTimeSeconds>"))
    }

    func testPauseIntervalsPairsEventsAndClosesTrailingPauseAtEnd() {
        let events: [(kind: String, timestamp: Date)] = [
            (kind: "paused", timestamp: date(100)),
            (kind: "resumed", timestamp: date(200)),
            (kind: "gps_stopped", timestamp: date(250)), // unrelated kinds ignored
            (kind: "paused", timestamp: date(400))       // unpaired trailing pause
        ]
        let intervals = StravaTCXBuilder.pauseIntervals(events: events, endedAt: date(600))
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0], DateInterval(start: date(100), end: date(200)))
        XCTAssertEqual(intervals[1], DateInterval(start: date(400), end: date(600)))
    }

    // MARK: - Timestamps

    func testTimestampsAreUTCSecondPrecisionWithTrailingZ() throws {
        let session = try makeSession()
        let gps = [
            StravaTrackFix(timestamp: date(0), latitude: 12.0, longitude: 77.0, altitude: 850.5 as Double?),
            StravaTrackFix(timestamp: date(30), latitude: 12.0001, longitude: 77.0001, altitude: Double?.none)
        ]
        let tcx = try XCTUnwrap(StravaTCXBuilder.build(session: session, hrSamples: [], gpsPoints: gps, pauseIntervals: []))
        // Exact UTC literals — independent of the device timezone (t0 is 22:13:20Z; a
        // timezone-leaky formatter would shift the hour and break these).
        XCTAssertTrue(tcx.contains("<Id>2023-11-14T22:13:20Z</Id>"))
        XCTAssertTrue(tcx.contains("<Lap StartTime=\"2023-11-14T22:13:20Z\">"))
        XCTAssertTrue(tcx.contains("<Time>2023-11-14T22:13:50Z</Time>"))
        XCTAssertTrue(tcx.contains("<AltitudeMeters>850.5</AltitudeMeters>"))
        XCTAssertFalse(tcx.contains("+00:00"), "must use trailing Z, not a numeric offset")
    }

    // MARK: - Empty input

    func testReturnsNilWhenNoData() throws {
        let session = try makeSession()
        XCTAssertNil(StravaTCXBuilder.build(session: session, hrSamples: [], gpsPoints: [], pauseIntervals: []))
        // One GPS fix and no HR is also unemittable (below the 2-point GPS threshold).
        let lonePoint = [StravaTrackFix(timestamp: date(0), latitude: 12.0, longitude: 77.0, altitude: Double?.none)]
        XCTAssertNil(StravaTCXBuilder.build(session: session, hrSamples: [], gpsPoints: lonePoint, pauseIntervals: []))
    }

    // MARK: - Sport mapping

    private struct MappingRow {
        let type: String
        let tcx: String
        let sportType: String
        let needsFix: Bool
    }

    func testSportMappingTables() {
        let expected: [MappingRow] = [
            MappingRow(type: "walk", tcx: "Other", sportType: "Walk", needsFix: true),
            MappingRow(type: "run", tcx: "Running", sportType: "Run", needsFix: false),
            MappingRow(type: "cycle", tcx: "Biking", sportType: "Ride", needsFix: false),
            MappingRow(type: "gym", tcx: "Other", sportType: "WeightTraining", needsFix: true),
            MappingRow(type: "squash", tcx: "Other", sportType: "Squash", needsFix: true),
            MappingRow(type: "sport", tcx: "Other", sportType: "Workout", needsFix: true),
            MappingRow(type: "yoga", tcx: "Other", sportType: "Yoga", needsFix: true),
            MappingRow(type: "dance", tcx: "Other", sportType: "Workout", needsFix: true),
            MappingRow(type: "hike", tcx: "Other", sportType: "Hike", needsFix: true),
            MappingRow(type: "other", tcx: "Other", sportType: "Workout", needsFix: true),
            // Legacy aliases resolve through ActivityMeta before mapping.
            MappingRow(type: "outdoor_run", tcx: "Running", sportType: "Run", needsFix: false),
            MappingRow(type: "ride", tcx: "Biking", sportType: "Ride", needsFix: false),
            MappingRow(type: "cycling", tcx: "Biking", sportType: "Ride", needsFix: false),
            MappingRow(type: "strength", tcx: "Other", sportType: "WeightTraining", needsFix: true),
            MappingRow(type: "mystery_type", tcx: "Other", sportType: "Workout", needsFix: true)
        ]
        for row in expected {
            XCTAssertEqual(StravaSportMapping.tcxSport(for: row.type), row.tcx, "tcxSport(\(row.type))")
            XCTAssertEqual(StravaSportMapping.sportType(for: row.type), row.sportType, "sportType(\(row.type))")
            XCTAssertEqual(StravaSportMapping.needsSportTypeFix(for: row.type), row.needsFix, "needsSportTypeFix(\(row.type))")
        }
    }
}
