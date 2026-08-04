import SwiftUI

// MARK: - Route projection

/// Projects GPS coordinates into view space for the share-card route: equirectangular with
/// longitude corrected by cos(mid-latitude), aspect-fit centered inside the inset rect, north
/// up (y flipped). Pure math — no MapKit — so long tracks stay cheap and it's unit-testable.
enum ShareRouteProjector {
    /// Cap after stride-thinning; keeps the Path and smoothing cheap for multi-hour workouts.
    private static let maxPoints = 400
    /// Chaikin smoothing only below this count — dense tracks are already visually smooth.
    private static let smoothingThreshold = 200

    static func normalized(points: [ShareRouteCoordinate], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return [] }
        let thinned = thin(points)
        guard let minLat = thinned.map(\.latitude).min(), let maxLat = thinned.map(\.latitude).max(),
              let minLon = thinned.map(\.longitude).min(), let maxLon = thinned.map(\.longitude).max()
        else { return [] }
        let latSpan = maxLat - minLat
        // Metres-per-degree of longitude shrinks with latitude; correct at the track's middle.
        let lonScale = cos((minLat + maxLat) / 2 * .pi / 180)
        let lonSpan = (maxLon - minLon) * lonScale
        guard latSpan > 0 || lonSpan > 0 else { return [] }
        let availWidth = size.width - inset * 2
        let availHeight = size.height - inset * 2
        guard availWidth > 0, availHeight > 0 else { return [] }
        // Aspect-fit: a zero span on one axis (straight N–S or E–W line) fits by the other.
        var scale = CGFloat.greatestFiniteMagnitude
        if lonSpan > 0 { scale = min(scale, availWidth / CGFloat(lonSpan)) }
        if latSpan > 0 { scale = min(scale, availHeight / CGFloat(latSpan)) }
        let originX = inset + (availWidth - CGFloat(lonSpan) * scale) / 2
        let originY = inset + (availHeight - CGFloat(latSpan) * scale) / 2
        let projected = thinned.map { point in
            CGPoint(
                x: originX + CGFloat((point.longitude - minLon) * lonScale) * scale,
                y: originY + CGFloat(maxLat - point.latitude) * scale  // flip: north at the top
            )
        }
        return projected.count <= smoothingThreshold ? chaikin(projected) : projected
    }

    /// Uniform stride-thinning to ≤ `maxPoints`, always keeping the exact first and last fixes.
    private static func thin(_ points: [ShareRouteCoordinate]) -> [ShareRouteCoordinate] {
        guard points.count > maxPoints else { return points }
        let step = Int((Double(points.count) / Double(maxPoints)).rounded(.up))
        var kept = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if (points.count - 1) % step != 0 { kept.append(points[points.count - 1]) }
        return kept
    }

    /// One Chaikin corner-cutting pass (25/75 split), endpoints preserved.
    private static func chaikin(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var smoothed: [CGPoint] = [points[0]]
        smoothed.reserveCapacity(points.count * 2)
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            smoothed.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
            smoothed.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
        }
        smoothed.append(points[points.count - 1])
        return smoothed
    }
}

// MARK: - Route shape + view

/// Self-contained route polyline: projects the raw coordinates inside `path(in:)` with the
/// rect it's given, so callers never pre-project or worry about the view's final size.
struct ShareRouteShape: Shape {
    let coordinates: [ShareRouteCoordinate]
    var inset: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let points = ShareRouteProjector.normalized(points: coordinates, in: rect.size, inset: inset)
        guard points.count >= 2 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + points[0].x, y: rect.minY + points[0].y))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x, y: rect.minY + point.y))
        }
        return path
    }
}

/// The share card's glowing route treatment: soft accent halo under a white→accent gradient
/// core with a hairline highlight, plus start (green) and finish (accent) markers.
struct ShareRouteView: View {
    let coordinates: [ShareRouteCoordinate]
    let accent: Color
    var inset: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let shape = ShareRouteShape(coordinates: coordinates, inset: inset)
            let points = ShareRouteProjector.normalized(points: coordinates, in: geo.size, inset: inset)
            ZStack {
                shape
                    .stroke(accent.opacity(0.35), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                    .blur(radius: 10)
                shape
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.95), accent],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                    )
                shape
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let start = points.first, let end = points.last {
                    Circle()
                        .fill(PulseColors.success)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                        .position(start)
                    Circle()
                        .fill(accent.opacity(0.22))
                        .frame(width: 20, height: 20)
                        .position(end)
                    Circle()
                        .fill(accent)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .position(end)
                }
            }
        }
    }
}
