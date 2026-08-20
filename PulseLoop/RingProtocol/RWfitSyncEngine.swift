import Foundation

/// RWfit sync engine. Connect pushes the clock first (both firmwares stamp history off their RTC),
/// then identity/profile/config reads and writes, then the history catalog pass. History is **not**
/// driven from `handle(_:)` — the pager (driver-owned, the only thing that sees frames) advances
/// itself off the ring's data frames, so `handle` is a no-op (the LuckRing pattern).
///
/// The framing is the driver's live decision, read through `framingProvider` at send time: the
/// engine is built at pairing, before service discovery has decided the framing, so a captured
/// value would freeze the default.
@MainActor
final class RWfitSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private let gate: RWfitCommandGate
    private let historySync: RWfitHistorySync
    private let clock: RWfitClock
    private let framingProvider: () -> RWfitFraming
    private let encoder = RWfitEncoder()

    /// Pushed in by `RingSyncCoordinator` before `runStartup`, so the handshake carries the user's
    /// real profile / goal. Defaults keep a freshly-paired ring sane until the store is read.
    private var userProfile = UserProfileValues(metric: true, sex: nil, age: nil, heightCm: nil, weightKg: nil)
    private var goalSteps = 10_000

    /// Whether this app has ever bound an RWfit ring. The bind write stores our user id on the ring;
    /// it only needs to happen once, and re-claiming on every connect would stomp a tester's
    /// vendor-app binding harder than necessary. (Same single-flag tradeoff as the LuckRing engine.)
    private static let pairFinishedKey = "rwfit.pairFinished"

    init(
        gate: RWfitCommandGate,
        historySync: RWfitHistorySync,
        clock: RWfitClock,
        framingProvider: @escaping () -> RWfitFraming
    ) {
        self.gate = gate
        self.historySync = historySync
        self.clock = clock
        self.framingProvider = framingProvider
    }

    private var framing: RWfitFraming { framingProvider() }

    // MARK: - Startup

    func runStartup() {
        // Clock first: everything the ring logs from this moment is stamped against it.
        clock.capture()
        gate.submit(encoder.setTime(framing: framing, components: clock.nowComponents()))

        // Bind once (stores our id), then always read bind status — on JieLi the status reply's
        // trailing TLV is the capability bitmap, so the read doubles as capability discovery.
        let firstPair = !UserDefaults.standard.bool(forKey: Self.pairFinishedKey)
        if firstPair {
            gate.submit(encoder.bind(framing: framing))
            UserDefaults.standard.set(true, forKey: Self.pairFinishedKey)
        }
        gate.submit(encoder.bindStatus(framing: framing))

        gate.submit(encoder.userProfile(framing: framing, profile: userProfile, goalSteps: goalSteps))
        gate.submit(encoder.units(framing: framing, metric: userProfile.metric))

        gate.submit(encoder.deviceInfo(framing: framing))
        gate.submit(encoder.battery(framing: framing))
        if framing == .legacy {
            // Legacy capability discovery is its own command (0x03 SupportMenuBean).
            gate.submit(encoder.features(framing: .legacy))
        }

        historySync.start(types: RWfitHistorySync.catalog)
    }

    /// History is pager-driven — nothing here advances it.
    func handle(_ event: RingDecodedEvent) {}

    // MARK: - History passes (re-entering `start` is a no-op while a pass is in flight)

    func syncHistory() {
        historySync.start(types: RWfitHistorySync.catalog)
    }

    func syncVitalsHistory() {
        historySync.start(types: RWfitHistorySync.vitalsTypes)
    }

    // MARK: - Live actions (JieLi-only `06 09` toggles; capability-gated so legacy UIs never call)

    func startHeartRate() { submitRealtime(type: RWfitJLDataType.heartRate, on: true) }
    func stopHeartRate() { submitRealtime(type: RWfitJLDataType.heartRate, on: false) }
    func startSpO2() { submitRealtime(type: RWfitJLDataType.spo2, on: true) }
    func stopSpO2() { submitRealtime(type: RWfitJLDataType.spo2, on: false) }
    func startHRV() { submitRealtime(type: RWfitJLDataType.hrv, on: true) }
    func stopHRV() { submitRealtime(type: RWfitJLDataType.hrv, on: false) }
    func startBloodPressure() { submitRealtime(type: RWfitJLDataType.bloodPressure, on: true) }
    func stopBloodPressure() { submitRealtime(type: RWfitJLDataType.bloodPressure, on: false) }

    /// The double gate: capability-gated UI shouldn't reach here on a legacy link, and if it does
    /// anyway the command is dropped rather than sent as bytes the firmware never defined.
    private func submitRealtime(type: UInt8, on: Bool) {
        guard framing == .jieli else { return }
        gate.submit(encoder.realtimeMeasure(type: type, on: on))
    }

    func findDevice() {}   // no find-ring command located in the vendor source

    func setGoal(steps: Int) {
        goalSteps = steps
        gate.submit(encoder.goal(framing: framing, steps: steps, profile: userProfile))
    }

    // MARK: - Clock / battery / profile

    /// The ring stamps records from its own RTC — timezone and wall-clock changes must be re-pushed.
    func resyncTime() {
        clock.capture()
        gate.submit(encoder.setTime(framing: framing, components: clock.nowComponents()))
    }

    func requestBattery() {
        gate.submit(encoder.battery(framing: framing))
    }

    func setUserProfile(_ profile: UserProfileValues) { userProfile = profile }

    func applyUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
        gate.submit(encoder.userProfile(framing: framing, profile: profile, goalSteps: goalSteps))
    }

    // MARK: - Teardown

    /// Release the ring on Forget (legacy 0x44 / JieLi `03 01 30 00`) and forget the bind latch so
    /// a future re-pair claims it again.
    func unbind() {
        gate.submit(encoder.unbind(framing: framing))
        UserDefaults.standard.set(false, forKey: Self.pairFinishedKey)
    }
}
