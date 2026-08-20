import Foundation

/// The RWfit history pager — the `LuckRingHistorySync` pattern on a two-framing family: request one
/// type, advance when its reply frames settle, skip it if nothing ever arrives. Types the active
/// framing doesn't speak (legacy has no HRV/stress/blood-sugar stream; JieLi has no breathe) are
/// skipped for free by the encoder returning nil.
///
/// Replays are safe: persistence upserts history by `(kind, timestamp)`, activity by bucket
/// timestamp, sleep by night. The vendor's delete-acks (`05 xx 30`) — which erase synced records
/// from the ring — are deliberately never sent: PulseLoop's idempotent upserts don't need them, and
/// leaving the log intact lets the user's original app keep working alongside ours.
@MainActor
final class RWfitHistorySync {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Full catalog, in request order (the vendor's own sync order: activity first, vitals after —
    /// `blesdk/service/l.java` / `y.java`). Unsupported-per-framing types drop out at request time.
    static let catalog: [RWfitHistoryType] = [
        .steps, .sleep, .heartRate, .bloodPressure, .spo2, .temperature, .breathe,
        .hrv, .stress, .bloodSugar,
    ]

    /// Post-workout backfill subset — only the logs a session can have added to.
    static let vitalsTypes: [RWfitHistoryType] = [.heartRate, .spo2]

    private let encoder = RWfitEncoder()
    private let gate: RWfitCommandGate
    /// Progress sink. `nil` publishes to the shared bus (the production path); tests inject a spy.
    private let progressSink: ((PulseEvent) -> Void)?

    /// Re-armed on every data frame of the in-flight type; firing means the type has settled.
    private let settleSeconds: TimeInterval
    /// Fires when a type produces nothing at all (unsupported / empty) — skip it.
    private let stallSeconds: TimeInterval

    /// Set by the driver at service discovery, with the gate's.
    var framing: RWfitFraming = .legacy

    private var queue: [RWfitHistoryType] = []
    private var currentType: RWfitHistoryType?
    private var settleTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?

    init(
        gate: RWfitCommandGate,
        settleSeconds: TimeInterval = 1.5,
        stallSeconds: TimeInterval = 6,
        progressSink: ((PulseEvent) -> Void)? = nil
    ) {
        self.gate = gate
        self.settleSeconds = settleSeconds
        self.stallSeconds = stallSeconds
        self.progressSink = progressSink
    }

    private func publish(_ event: PulseEvent) {
        if let progressSink {
            progressSink(event)
        } else {
            Task { await PulseEventBus.shared.publish(event) }
        }
    }

    var isRunning: Bool { currentType != nil }

    /// Seed the queue and request the first type. A pass already in flight wins — a re-entrant
    /// `start` would abandon the in-flight type mid-stream.
    func start(types: [RWfitHistoryType]) {
        guard !isRunning else { return }
        queue = types
        advance()
    }

    /// Abandon any in-flight pass (disconnect / teardown).
    func cancel() {
        cancelTimers()
        currentType = nil
        queue.removeAll()
    }

    /// Called by the driver for every completed history data frame. A frame for the in-flight type
    /// re-arms the settle window; anything else is ignored (late frames from a skipped type).
    func noteReceived(type: RWfitHistoryType) {
        guard let currentType, type == currentType else { return }
        stallTask?.cancel(); stallTask = nil
        armSettle()
    }

    // MARK: - Driving the queue

    private func advance() {
        cancelTimers()
        // Skip past types the active framing has no stream for.
        var request: RWfitOutbound?
        var type: RWfitHistoryType?
        while request == nil, !queue.isEmpty {
            let candidate = queue.removeFirst()
            request = encoder.historyRequest(framing: framing, type: candidate)
            type = candidate
        }
        guard let request, let type else {
            currentType = nil
            publish(.syncProgress(stage: "done"))
            return
        }
        currentType = type
        publish(.syncProgress(stage: "Syncing \(type.label)…"))
        gate.submit(request)
        armStall()
    }

    private func armSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            let nanos = UInt64((self?.settleSeconds ?? 1.5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.advance()
        }
    }

    private func armStall() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            let nanos = UInt64((self?.stallSeconds ?? 6) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.advance()   // no data ever arrived for this type — skip it
        }
    }

    private func cancelTimers() {
        settleTask?.cancel(); settleTask = nil
        stallTask?.cancel(); stallTask = nil
    }
}
