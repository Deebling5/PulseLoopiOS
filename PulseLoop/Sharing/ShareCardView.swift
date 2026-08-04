import SwiftUI

// MARK: - Share card view

/// The exportable workout card, laid out on a 360-wide canvas and rendered offscreen by
/// `ShareCardRenderer`. Every surface is an explicit fill — no `pulseGlass`/materials, because
/// `ImageRenderer` has nothing behind the view to sample, so blurs would come out flat/black.
struct ShareCardView: View {
    let model: ShareCardModel
    let format: ShareCardFormat

    var body: some View {
        ZStack {
            background
            switch format {
            case .story: storyContent
            case .square: squareContent
            }
        }
        .frame(width: format.pointSize.width, height: format.pointSize.height)
        .clipped()
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            PulseColors.background
            // Aurora wash from the top-left corner, tinted by the activity accent.
            LinearGradient(
                stops: [
                    .init(color: model.accent.opacity(0.26), location: 0.0),
                    .init(color: model.accent.opacity(0.08), location: 0.35),
                    .init(color: .clear, location: 0.62)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Counter-glow near the top-right so the header floats in light, not shadow.
            RadialGradient(
                colors: [model.accent.opacity(0.16), .clear],
                center: UnitPoint(x: 0.85, y: 0.12),
                startRadius: 0, endRadius: 300
            )
            // Bottom vignette anchors the stats + footer against the wash.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.62),
                    .init(color: Color.black.opacity(0.38), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                .padding(12)
        }
    }

    // MARK: - Story (360x640)

    private var storyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 16)
            routeBand
                // Ideal 252, but compressible: with two stat rows + effort bar the fixed content
                // alone can exceed 640pt, so the art band is the element that gives way.
                .frame(minHeight: 140, idealHeight: 252, maxHeight: 252)
                .frame(maxWidth: .infinity)
            heroBlock(valueSize: 64)
                .padding(.top, 24)
            ForEach(Array(model.statRows.enumerated()), id: \.offset) { index, row in
                statRow(row)
                    .padding(.top, index == 0 ? 18 : 14)
            }
            Spacer(minLength: 16)
            if !model.zoneSegments.isEmpty {
                effortBar
                    .padding(.bottom, 20)
            }
            footer
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 36)
    }

    // MARK: - Square (360x360)

    private var squareContent: some View {
        ZStack(alignment: .top) {
            // Route (or glyph) as background art in the upper band; the bottom vignette keeps
            // the overlaid stats legible where they cross it. Starts below the header so the
            // glow never washes over the date line.
            squareArtBand
                .padding(.top, 52)
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 12)
                heroBlock(valueSize: 52)
                if let firstRow = model.statRows.first {
                    statRow(firstRow)
                        .padding(.top, 14)
                }
                if !model.zoneSegments.isEmpty {
                    effortBar
                        .padding(.top, 16)
                }
                footer
                    .padding(.top, 16)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
    }

    private var squareArtBand: some View {
        Group {
            if model.hasRoute {
                ShareRouteView(coordinates: model.routeCoordinates, accent: model.accent, inset: 36)
            } else {
                glyphArt
                    .scaleEffect(0.72)
            }
        }
        .opacity(0.85)
        .frame(height: 210)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.accent.opacity(0.14))
                Circle().stroke(model.accent.opacity(0.45), lineWidth: 1)
                Image(systemName: model.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.accent)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.activityLabel.uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(3.0)
                    .foregroundStyle(model.accent)
                Text(model.dateHeadline)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(PulseColors.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Route / glyph band

    private var routeBand: some View {
        Group {
            if model.hasRoute {
                ShareRouteView(coordinates: model.routeCoordinates, accent: model.accent, inset: 20)
            } else {
                glyphArt
            }
        }
    }

    /// Indoor treatment: the activity glyph over concentric "pulse" rings. The outer ring
    /// (radius 160) deliberately bleeds past the band and is clipped, reading as a crop of
    /// something larger.
    private var glyphArt: some View {
        ZStack {
            Circle().stroke(model.accent.opacity(0.22), lineWidth: 1).frame(width: 180, height: 180)
            Circle().stroke(model.accent.opacity(0.12), lineWidth: 1).frame(width: 250, height: 250)
            Circle().stroke(model.accent.opacity(0.06), lineWidth: 1).frame(width: 320, height: 320)
            Image(systemName: model.symbol)
                .font(.system(size: 150, weight: .thin))
                .foregroundStyle(
                    LinearGradient(
                        colors: [model.accent, model.accent.opacity(0.15)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Hero

    private func heroBlock(valueSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.heroStat.label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(PulseColors.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.heroStat.value)
                    .font(PulseFont.number(valueSize, .bold).monospacedDigit())
                    .foregroundStyle(model.heroStat.value == "—" ? PulseColors.textMuted : PulseColors.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit = model.heroStat.unit {
                    Text(unit)
                        .font(PulseFont.numberL)
                        .foregroundStyle(PulseColors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Stat rows

    private func statRow(_ row: [ShareCardStat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Rectangle()
                        .fill(PulseColors.borderSubtle)
                        .frame(width: 1, height: 28)
                }
                statColumn(stat)
            }
        }
    }

    private func statColumn(_ stat: ShareCardStat) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(stat.value)
                    .font(PulseFont.number(22).monospacedDigit())
                    .foregroundStyle(stat.value == "—" ? PulseColors.textMuted : PulseColors.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                // Small trailing unit ("/KM", "BPM") so pace/speed stay unambiguous on a card
                // seen out of app context.
                if let unit = stat.unit {
                    Text(unit)
                        .font(PulseFont.number(11, .medium))
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            Text(stat.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Effort bar

    private var effortBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("EFFORT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(PulseColors.textMuted)
                Spacer()
                if let caption = model.hrCaption {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(PulseColors.textSecondary)
                }
            }
            GeometryReader { geo in
                let segments = model.zoneSegments
                let spacing: CGFloat = 2
                let available = max(0, geo.size.width - spacing * CGFloat(max(0, segments.count - 1)))
                // Floor each slice at 3% so a few seconds in a zone still registers, then
                // renormalize so the floored widths still fill the bar exactly.
                let floored = segments.map { max($0.fraction, 0.03) }
                let total = floored.reduce(0, +)
                HStack(spacing: spacing) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: total > 0 ? available * floored[index] / total : 0)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image("pulseloop-logo")
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("PulseLoop")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PulseColors.textPrimary)
            Spacer()
            Text(model.dateFooter)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PulseColors.textMuted)
        }
    }
}
