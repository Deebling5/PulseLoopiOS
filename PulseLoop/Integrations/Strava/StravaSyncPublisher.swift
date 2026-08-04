import SwiftUI
import SwiftData

/// Drives automatic Strava uploads off the same coalesced `PulseDataChange` signal the widget and
/// Health publishers ride. When ring data lands (or a scene-phase edge fires), it debounces briefly
/// and then asks `StravaUploadService` to push every newly-finished workout past the watermark.
/// Retained for the app's lifetime by `PulseLoopApp` (like `HealthSyncPublisher`).
///
/// Refresh discipline mirrors the Health publisher: a history sync bumps the token once per batch,
/// but several batches can land in quick succession, so the publish is debounced. Scene-phase edges
/// are also caught (`kick()`) since Settings-side changes don't bump the sync token.
///
/// Guards before every scheduled pass — master toggle on, automatic mode chosen, and a connected
/// Strava account — so a manual-mode or disconnected user never wakes the upload path.
/// `StravaUploadService` re-checks the same guards, but short-circuiting here avoids arming a
/// pointless debounce timer.
@MainActor
final class StravaSyncPublisher {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private let modelContext: ModelContext
    private var debounceTask: Task<Void, Never>?

    /// Matches the Health publisher's 15 s: uploads are heavy network work and never user-visible
    /// from this path, so a full sync burst coalesces into one upload pass.
    private static let debounceSeconds: Double = 15

    init(context: ModelContext) {
        self.modelContext = context
    }

    func start() {
        observeDataChange()
    }

    /// Scene-phase edge trigger — routes through the same debounce path as a data change.
    func kick() {
        scheduleUpload()
    }

    /// `withObservationTracking` is one-shot: re-arm after every fire, then debounce the upload so
    /// one burst of persistence batches produces one upload pass.
    private func observeDataChange() {
        withObservationTracking {
            _ = PulseDataChange.shared.token
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDataChange()
                self.scheduleUpload()
            }
        }
    }

    private func scheduleUpload() {
        guard shouldUpload() else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            guard let self, self.shouldUpload() else { return }
            // A `false` return means a pass was already in flight and this trigger was dropped.
            // Workouts that finished after that pass took its fetch snapshot would otherwise wait
            // for an unrelated trigger, so re-arm a fresh debounce to pick them up once the
            // in-flight pass finishes.
            let ran = await StravaUploadService.shared.uploadNewFinished(context: self.modelContext)
            if !ran { self.scheduleUpload() }
        }
    }

    private func shouldUpload() -> Bool {
        StravaPrefsStore.shared.prefs.masterEnabled
            && StravaPrefsStore.shared.prefs.uploadMode == .automatic
            && StravaAuthService.shared.isConnected
    }
}
