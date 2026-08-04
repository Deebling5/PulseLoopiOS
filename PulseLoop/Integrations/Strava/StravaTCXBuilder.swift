import Foundation

/// One GPS fix handed to the TCX builder (a struct because SwiftLint's `large_tuple`
/// bars labeled tuples beyond two members).
struct StravaTrackFix {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    var altitude: Double?
}

/// Pure value-level TCX generator for Strava uploads. No SwiftData fetches — the caller passes
/// pre-fetched arrays so the builder stays deterministic and hermetically testable.
struct StravaTCXBuilder {
    /// Ring HR is sparse (spot reads), so a GPS trackpoint reuses the most recent HR sample
    /// at-or-before its timestamp — but only within this window; older samples are omitted.
    static let hrStalenessWindow: TimeInterval = 60

    // Pinned to UTC so output is identical regardless of the device timezone.
    // `.withInternetDateTime` gives second precision with a trailing Z.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Builds the TCX document, or nil when there are no emittable trackpoints.
    static func build(
        session: ActivitySession,
        hrSamples: [(timestamp: Date, bpm: Int)],
        gpsPoints: [StravaTrackFix],
        pauseIntervals: [DateInterval]
    ) -> String? {
        let sortedHR = hrSamples.sorted { $0.timestamp < $1.timestamp }
        let sortedGPS = gpsPoints.sorted { $0.timestamp < $1.timestamp }

        let trackpoints: [String]
        if sortedGPS.count >= 2 {
            trackpoints = gpsTrackpoints(gps: sortedGPS, hr: sortedHR, pauseIntervals: pauseIntervals)
        } else if !sortedHR.isEmpty {
            trackpoints = indoorTrackpoints(hr: sortedHR, pauseIntervals: pauseIntervals)
        } else {
            trackpoints = []
        }
        guard !trackpoints.isEmpty else { return nil }

        let startISO = isoFormatter.string(from: session.startedAt)
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\">")
        lines.append("  <Activities>")
        lines.append("    <Activity Sport=\"\(StravaSportMapping.tcxSport(for: session.type))\">")
        lines.append("      <Id>\(startISO)</Id>")
        lines.append("      <Lap StartTime=\"\(startISO)\">")
        lines.append(contentsOf: lapSummary(session: session))
        lines.append("        <Intensity>Active</Intensity>")
        lines.append("        <TriggerMethod>Manual</TriggerMethod>")
        lines.append("        <Track>")
        lines.append(contentsOf: trackpoints)
        lines.append("        </Track>")
        lines.append("      </Lap>")
        lines.append("    </Activity>")
        lines.append("  </Activities>")
        lines.append("</TrainingCenterDatabase>")
        return lines.joined(separator: "\n")
    }

    /// Pairs each "paused" event with the next "resumed"; an unpaired trailing "paused"
    /// closes at `endedAt`. Kind strings match `ActivityRecorderService.pause/resume`.
    static func pauseIntervals(events: [(kind: String, timestamp: Date)], endedAt: Date) -> [DateInterval] {
        var intervals: [DateInterval] = []
        var openPause: Date?
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch event.kind {
            case "paused":
                if openPause == nil { openPause = event.timestamp }
            case "resumed":
                if let start = openPause, event.timestamp > start {
                    intervals.append(DateInterval(start: start, end: event.timestamp))
                }
                openPause = nil
            default:
                break
            }
        }
        if let start = openPause, endedAt > start {
            intervals.append(DateInterval(start: start, end: endedAt))
        }
        return intervals
    }

    // MARK: - Lap summary

    private static func lapSummary(session: ActivitySession) -> [String] {
        let ended = session.endedAt ?? session.startedAt
        let totalSeconds = max(0, ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds)
        var lines: [String] = []
        lines.append("        <TotalTimeSeconds>\(String(format: "%.1f", totalSeconds))</TotalTimeSeconds>")
        lines.append("        <DistanceMeters>\(String(format: "%.1f", session.distanceMeters ?? 0))</DistanceMeters>")
        lines.append("        <Calories>\(Int(session.calories ?? 0))</Calories>")
        if let avg = session.avgHeartRate {
            lines.append("        <AverageHeartRateBpm><Value>\(Int(avg.rounded()))</Value></AverageHeartRateBpm>")
        }
        if let max = session.maxHeartRate {
            lines.append("        <MaximumHeartRateBpm><Value>\(Int(max.rounded()))</Value></MaximumHeartRateBpm>")
        }
        return lines
    }

    // MARK: - Trackpoints

    /// GPS mode: one trackpoint per GPS point; HR merged as a step function of the most
    /// recent sample at-or-before each point within the staleness window.
    private static func gpsTrackpoints(
        gps: [StravaTrackFix],
        hr: [(timestamp: Date, bpm: Int)],
        pauseIntervals: [DateInterval]
    ) -> [String] {
        var lines: [String] = []
        var hrIndex = 0
        for point in gps {
            // Advance the step function: latest HR sample at-or-before this point.
            while hrIndex < hr.count && hr[hrIndex].timestamp <= point.timestamp { hrIndex += 1 }
            let current = hrIndex > 0 ? hr[hrIndex - 1] : nil
            guard !isPaused(point.timestamp, in: pauseIntervals) else { continue }

            lines.append("          <Trackpoint>")
            lines.append("            <Time>\(isoFormatter.string(from: point.timestamp))</Time>")
            lines.append("            <Position>")
            lines.append("              <LatitudeDegrees>\(String(format: "%.6f", point.latitude))</LatitudeDegrees>")
            lines.append("              <LongitudeDegrees>\(String(format: "%.6f", point.longitude))</LongitudeDegrees>")
            lines.append("            </Position>")
            if let altitude = point.altitude {
                lines.append("            <AltitudeMeters>\(String(format: "%.1f", altitude))</AltitudeMeters>")
            }
            if let sample = current, point.timestamp.timeIntervalSince(sample.timestamp) <= hrStalenessWindow {
                lines.append("            <HeartRateBpm><Value>\(sample.bpm)</Value></HeartRateBpm>")
            }
            lines.append("          </Trackpoint>")
        }
        return lines
    }

    /// Indoor mode (fewer than 2 GPS fixes): one trackpoint per HR sample, no Position.
    private static func indoorTrackpoints(
        hr: [(timestamp: Date, bpm: Int)],
        pauseIntervals: [DateInterval]
    ) -> [String] {
        var lines: [String] = []
        for sample in hr where !isPaused(sample.timestamp, in: pauseIntervals) {
            lines.append("          <Trackpoint>")
            lines.append("            <Time>\(isoFormatter.string(from: sample.timestamp))</Time>")
            lines.append("            <HeartRateBpm><Value>\(sample.bpm)</Value></HeartRateBpm>")
            lines.append("          </Trackpoint>")
        }
        return lines
    }

    private static func isPaused(_ timestamp: Date, in intervals: [DateInterval]) -> Bool {
        intervals.contains { $0.contains(timestamp) }
    }
}
