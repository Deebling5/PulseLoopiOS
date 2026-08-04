import XCTest
import SwiftData
@testable import PulseLoop

/// Route-projection math + share-card model formatting. Renderer/pixel tests come later.
@MainActor
final class ShareCardTests: XCTestCase {
    private let degPerMeter = 180.0 / (.pi * 6_371_000.0)

    // MARK: - Projection

    private func line(latitudes: [Double], lon: Double = 0) -> [ShareRouteCoordinate] {
        latitudes.map { ShareRouteCoordinate(latitude: $0, longitude: lon) }
    }

    func testTallTrackFillsHeightAndHonorsInset() {
        // Straight south→north line in a 100×200 canvas, inset 20: fills the vertical inset
        // rect exactly, stays centered horizontally (zero longitude span).
        let coords = line(latitudes: [0, 0.25, 0.5, 0.75, 1.0])
        let pts = ShareRouteProjector.normalized(points: coords, in: CGSize(width: 100, height: 200), inset: 20)
        XCTAssertFalse(pts.isEmpty)
        for point in pts { XCTAssertEqual(point.x, 50, accuracy: 0.001) }
        XCTAssertEqual(pts.map(\.y).min()!, 20, accuracy: 0.001)   // north endpoint at top inset
        XCTAssertEqual(pts.map(\.y).max()!, 180, accuracy: 0.001)  // south endpoint at bottom inset
    }

    func testYFlipPutsNorthAtTheTop() {
        let pts = ShareRouteProjector.normalized(
            points: line(latitudes: [0, 0.5, 1.0]), in: CGSize(width: 100, height: 100), inset: 10
        )
        XCTAssertLessThan(pts.last!.y, pts.first!.y)  // final (northernmost) fix renders highest
    }

    func testCosineLongitudeScalingAt60North() {
        // Equal-degree square at 60°N: cos ≈ 0.5 → drawn ~twice as tall as wide. 240 perimeter
        // points (> smoothing threshold) so Chaikin doesn't cut corners before we measure.
        var coords: [ShareRouteCoordinate] = []
        for i in 0..<60 { coords.append(ShareRouteCoordinate(latitude: 60 + Double(i) / 60, longitude: 10)) }
        for i in 0..<60 { coords.append(ShareRouteCoordinate(latitude: 61, longitude: 10 + Double(i) / 60)) }
        for i in 0..<60 { coords.append(ShareRouteCoordinate(latitude: 61 - Double(i) / 60, longitude: 11)) }
        for i in 0..<60 { coords.append(ShareRouteCoordinate(latitude: 60, longitude: 11 - Double(i) / 60)) }
        let pts = ShareRouteProjector.normalized(points: coords, in: CGSize(width: 300, height: 300), inset: 20)
        let width = pts.map(\.x).max()! - pts.map(\.x).min()!
        let height = pts.map(\.y).max()! - pts.map(\.y).min()!
        XCTAssertEqual(height, 260, accuracy: 0.5)        // tall axis fills the inset rect
        XCTAssertEqual(height / width, 2.0, accuracy: 0.05)
    }

    func testDegenerateInputsProjectEmpty() {
        let size = CGSize(width: 100, height: 100)
        XCTAssertTrue(ShareRouteProjector.normalized(points: [], in: size, inset: 10).isEmpty)
        XCTAssertTrue(ShareRouteProjector.normalized(
            points: [ShareRouteCoordinate(latitude: 37, longitude: -122)], in: size, inset: 10
        ).isEmpty)
        let stationary = Array(repeating: ShareRouteCoordinate(latitude: 37, longitude: -122), count: 5)
        XCTAssertTrue(ShareRouteProjector.normalized(points: stationary, in: size, inset: 10).isEmpty)
    }

    func testThinningCapsAt400KeepingExactEndpoints() {
        let coords = line(latitudes: (0..<1000).map { Double($0) / 1000 })
        let pts = ShareRouteProjector.normalized(points: coords, in: CGSize(width: 100, height: 200), inset: 20)
        XCTAssertLessThanOrEqual(pts.count, 400)
        XCTAssertGreaterThan(pts.count, 200)  // dense track → no Chaikin pass
        // The exact first (southernmost) and last (northernmost) fixes survive thinning.
        XCTAssertEqual(pts.first!.y, 180, accuracy: 0.01)
        XCTAssertEqual(pts.last!.y, 20, accuracy: 0.01)
    }

    func testChaikinSmoothingPreservesEndpoints() {
        let coords = [
            ShareRouteCoordinate(latitude: 0, longitude: 0),
            ShareRouteCoordinate(latitude: 0.5, longitude: 0.4),
            ShareRouteCoordinate(latitude: 0.2, longitude: 0.8),
            ShareRouteCoordinate(latitude: 0.7, longitude: 1.2),
            ShareRouteCoordinate(latitude: 1.0, longitude: 1.6)
        ]
        let pts = ShareRouteProjector.normalized(points: coords, in: CGSize(width: 200, height: 200), inset: 20)
        XCTAssertEqual(pts.count, 10)  // one pass: endpoints + 2 per segment
        // Endpoints are the untouched projections of the first/last coordinates, i.e. the
        // horizontal extremes of this west→east track.
        XCTAssertEqual(pts.first!.x, pts.map(\.x).min()!, accuracy: 0.0001)
        XCTAssertEqual(pts.last!.x, pts.map(\.x).max()!, accuracy: 0.0001)
        XCTAssertEqual(pts.first!.x, 20, accuracy: 0.01)
        XCTAssertEqual(pts.last!.x, 180, accuracy: 0.01)
    }

    // MARK: - Model

    /// Finished 30-min 5 km GPS run with a 20-point northbound track.
    private func makeRun(context: ModelContext) -> (ActivitySession, WorkoutSummaryData) {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let session = ActivitySession(
            type: "run", status: .finished, startedAt: start,
            endedAt: start.addingTimeInterval(1800), calories: 320, useGps: true
        )
        session.distanceMeters = 5000
        context.insert(session)
        for i in 0..<20 {
            context.insert(ActivityGpsPoint(
                sessionId: session.id,
                latitude: 37.0 + Double(i) * 10 * degPerMeter,
                longitude: -122.0,
                timestamp: start.addingTimeInterval(Double(i) * 10)
            ))
        }
        try? context.save()
        return (session, WorkoutSummaryData.build(session: session, context: context))
    }

    func testRunWithGpsGetsDistanceHeroAndRoute() throws {
        let context = try TestSupport.makeContext()
        let (session, data) = makeRun(context: context)
        let model = ShareCardModel.build(session: session, data: data, units: .metric, age: 30)
        XCTAssertEqual(model.activityLabel, "RUN")
        XCTAssertEqual(model.heroStat, ShareCardStat(label: "DISTANCE", value: "5.00", unit: "km"))
        XCTAssertTrue(model.hasRoute)
        XCTAssertEqual(model.routeCoordinates.count, 20)
        // 1800 s over 5 km → 6:00 /km.
        XCTAssertTrue(model.statRows[0].contains(ShareCardStat(label: "PACE", value: "6:00", unit: "/km")))
        XCTAssertTrue(model.statRows[0].contains(ShareCardStat(label: "DURATION", value: "30:00", unit: nil)))
    }

    func testGymGetsDurationHeroAndSingleRow() throws {
        let context = try TestSupport.makeContext()
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let session = ActivitySession(
            type: "gym", status: .finished, startedAt: start,
            endedAt: start.addingTimeInterval(1800), calories: 250, useGps: false
        )
        context.insert(session)
        try context.save()
        let data = WorkoutSummaryData.build(session: session, context: context)
        let model = ShareCardModel.build(session: session, data: data, units: .metric, age: nil)
        XCTAssertEqual(model.heroStat, ShareCardStat(label: "DURATION", value: "30:00", unit: nil))
        XCTAssertFalse(model.hasRoute)
        XCTAssertTrue(model.routeCoordinates.isEmpty)
        XCTAssertEqual(model.statRows.count, 1)
        XCTAssertEqual(model.statRows[0].map(\.label), ["CALORIES", "AVG HR", "MAX HR"])
    }

    func testImperialUnitsFlowToHeroAndPace() throws {
        let context = try TestSupport.makeContext()
        let (session, data) = makeRun(context: context)
        let model = ShareCardModel.build(session: session, data: data, units: .imperial, age: 30)
        XCTAssertEqual(model.heroStat.unit, "mi")
        XCTAssertEqual(model.heroStat.value, "3.11")
        XCTAssertTrue(model.statRows[0].contains { $0.label == "PACE" && $0.unit == "/mi" })
    }

    func testNoHeartRateMeansNoZonesOrCaption() throws {
        let context = try TestSupport.makeContext()
        let (session, data) = makeRun(context: context)
        let model = ShareCardModel.build(session: session, data: data, units: .metric, age: 30)
        XCTAssertTrue(model.zoneSegments.isEmpty)
        XCTAssertNil(model.hrCaption)
    }

    func testHeartRateProducesZonesAndCaption() throws {
        let context = try TestSupport.makeContext()
        let (session, _) = makeRun(context: context)
        session.avgHeartRate = 152
        session.maxHeartRate = 171
        // 30 in-window samples spanning easy→max zones for a 30-year-old (HRmax 190).
        for i in 0..<30 {
            context.insert(ActivitySample(
                sessionId: session.id, kind: MeasurementKind.heartRate.rawValue,
                value: [110.0, 150.0, 180.0][i % 3], unit: "bpm",
                timestamp: session.startedAt.addingTimeInterval(Double(i) * 30)
            ))
        }
        try context.save()
        let data = WorkoutSummaryData.build(session: session, context: context)
        let model = ShareCardModel.build(session: session, data: data, units: .metric, age: 30)
        XCTAssertFalse(model.zoneSegments.isEmpty)
        XCTAssertEqual(model.zoneSegments.reduce(0) { $0 + $1.fraction }, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.hrCaption, "AVG 152 · MAX 171 BPM")
    }
}
