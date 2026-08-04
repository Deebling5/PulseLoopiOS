import SwiftUI
import SwiftData
import UIKit

/// Per-workout Strava action row shown on the post-record summary and the activity detail screen.
///
/// Renders nothing unless the Strava integration is enabled and the workout is finished. Walks the
/// upload lifecycle: idle "Push to Strava" button (Strava-orange, mirroring the delete button's
/// tinted-outline shape) → disabled uploading row → "On Strava" deep link once an activity id is
/// stored. Upload errors surface as a caption under the button, which stays tappable as the retry.
struct StravaUploadRow: View {
    @Environment(\.modelContext) private var modelContext
    let session: ActivitySession

    init(session: ActivitySession) {
        self.session = session
    }

    /// Strava brand orange — deliberately not a palette colour; the row is third-party branded.
    private static let stravaOrange = Color(red: 0.988, green: 0.298, blue: 0.008)

    var body: some View {
        if StravaPrefsStore.shared.prefs.masterEnabled, session.status == .finished {
            VStack(spacing: 8) {
                if let activityId = session.stravaActivityId {
                    uploadedRow(activityId: activityId)
                } else if StravaUploadService.shared.uploadingSessionIds.contains(session.id) {
                    uploadingRow
                } else {
                    uploadButton
                    if let message = StravaUploadService.shared.lastErrorBySession[session.id] {
                        Text(message)
                            .font(PulseFont.caption.weight(.regular))
                            .foregroundStyle(PulseColors.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    // MARK: - States

    private var uploadButton: some View {
        Button {
            Task { await StravaUploadService.shared.upload(session: session, context: modelContext) }
        } label: {
            Label("Push to Strava", systemImage: "arrow.up.circle.fill")
                .font(PulseFont.callout)
                .foregroundStyle(Self.stravaOrange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Self.stravaOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Self.stravaOrange.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var uploadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Self.stravaOrange)
            Text("Uploading to Strava…")
                .font(PulseFont.callout)
                .foregroundStyle(Self.stravaOrange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Self.stravaOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Self.stravaOrange.opacity(0.4), lineWidth: 1))
        .opacity(0.75)
    }

    private func uploadedRow(activityId: String) -> some View {
        Button {
            openOnStrava(activityId: activityId)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PulseColors.success)
                Text("On Strava")
                    .font(PulseFont.callout)
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(PulseColors.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.success.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Deep link

    private func openOnStrava(activityId: String) {
        // A duplicate reconciled on Strava's side stores a non-numeric sentinel instead of a real
        // activity id, so there is nothing to deep-link to — land on the athlete's training log.
        guard !activityId.isEmpty, activityId.allSatisfy(\.isNumber) else {
            if let url = URL(string: "https://www.strava.com/athlete/training") {
                UIApplication.shared.open(url)
            }
            return
        }
        guard let appURL = URL(string: "strava://activities/\(activityId)"),
              let webURL = URL(string: "https://www.strava.com/activities/\(activityId)") else { return }
        UIApplication.shared.open(appURL) { opened in
            if !opened { UIApplication.shared.open(webURL) }
        }
    }
}
