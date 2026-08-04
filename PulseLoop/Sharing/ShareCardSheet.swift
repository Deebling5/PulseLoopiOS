import SwiftUI
import SwiftData

// MARK: - Share card sheet

/// Full-height sheet with a live scaled preview of the share card, a story/square format
/// toggle, and a `ShareLink` exporting the rendered PNG.
struct ShareCardSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Query private var profiles: [UserProfile]
    let session: ActivitySession
    @State private var format: ShareCardFormat = .story
    @State private var model: ShareCardModel?
    @State private var shareImage: ShareCardImage?

    init(session: ActivitySession) {
        self.session = session
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Share workout")
                .font(PulseFont.title3.weight(.bold))
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, 8)

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            formatToggle

            shareButton
        }
        .padding(20)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(PulseColors.background)
        .onAppear(perform: buildModel)
        .onChange(of: format) { _, _ in renderShareImage() }
    }

    // MARK: - Model / render

    private func buildModel() {
        guard model == nil else { return }
        let data = WorkoutSummaryData.build(session: session, context: modelContext)
        let profile = profiles.first
        let built = ShareCardModel.build(
            session: session, data: data, units: profile?.units ?? .metric, age: profile?.age
        )
        model = built
        renderShareImage()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "shareCardDump") {
            ShareCardRenderer.dumpToDocuments(model: built)
        }
        #endif
    }

    /// Renders once per model/format change so `ShareLink` hands over a finished PNG instantly
    /// instead of blocking the share-sheet presentation on a 3x render.
    private func renderShareImage() {
        guard let model else { return }
        shareImage = ShareCardRenderer.shareImage(model: model, format: format)
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { geo in
            if let model {
                let size = format.pointSize
                let scale = min(geo.size.width / size.width, geo.size.height / size.height)
                ShareCardView(model: model, format: format)
                    .scaleEffect(scale)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 10)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            } else {
                ProgressView()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .animation(.snappy(duration: 0.25), value: format)
    }

    // MARK: - Format toggle

    private var formatToggle: some View {
        HStack(spacing: 10) {
            formatPill("Story 9:16", .story)
            formatPill("Square 1:1", .square)
        }
    }

    private func formatPill(_ title: String, _ value: ShareCardFormat) -> some View {
        let active = format == value
        return Button { format = value } label: {
            Text(title)
                .font(PulseFont.footnote)
                .foregroundStyle(active ? PulseColors.textPrimary : PulseColors.textSecondary)
                .padding(.horizontal, 16).padding(.vertical, 9)
                // Solid pills, not glass — mirrors the effort pills in the workout summary
                // (glass can't sample glass; these sit over the sheet's own surface).
                .background {
                    if active {
                        Capsule().fill(PulseColors.accent.opacity(0.18))
                    } else {
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.white.opacity(0.07)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                }
                .overlay(
                    Capsule().stroke(active ? PulseColors.accent : PulseColors.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Share button

    private var shareLabel: some View {
        Label("Share card", systemImage: "square.and.arrow.up")
            .labelStyle(.titleAndIcon)
            .font(PulseFont.bodyEmphasis)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
    }

    /// Mirrors `PrimaryButton`'s treatment (accent-tinted glass on iOS 26, solid capsule
    /// otherwise) — `ShareLink` supplies its own button, so the style is applied inline.
    @ViewBuilder
    private var shareButton: some View {
        if let shareImage, let model {
            let link = ShareLink(
                item: shareImage,
                preview: SharePreview(
                    "\(model.activityLabel.capitalized) · \(model.dateFooter)",
                    image: shareImage.previewImage
                )
            ) {
                shareLabel.foregroundStyle(.white)
            }
            if #available(iOS 26, *), !reduceTransparency {
                link
                    .buttonStyle(.glass)
                    .tint(PulseColors.accent)
                    .clipShape(Capsule())
            } else {
                link
                    .background(PulseColors.accent)
                    .clipShape(Capsule())
            }
        } else {
            // Render failed (or is still pending) — keep the affordance visible but inert.
            shareLabel
                .foregroundStyle(.white.opacity(0.5))
                .background(PulseColors.accent.opacity(0.4))
                .clipShape(Capsule())
        }
    }
}
