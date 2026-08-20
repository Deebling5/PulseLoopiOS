import Foundation
@preconcurrency import CoreBluetooth

/// RWfit driver. One GATT — service `A00A`, write `B002`, notify `B003` — but **two wire framings**,
/// and which one this ring speaks is only knowable from the sibling services it exposes:
/// JieLi `AE00` / Telink OTA / PixArt `FF00` present ⇒ JieLi `0xAB` framing; none ⇒ legacy `0x7E`
/// (the vendor's `onServicesDiscovered`, `r5/b.java:684-740`). `servicesDiscovered` makes that call
/// before any characteristic I/O, so framing is fixed before the first outbound frame.
///
/// **Framing is identity** — the command gate frames logical commands itself (it owns the serial
/// counter the device-ACK matching needs), and outbound protocol ACKs are built pre-framed by the
/// codecs. **Inbound is ACK-before-decode**: both firmwares retransmit a device-initiated frame
/// until the app answers, so the ACK is enqueued before decoding can slow anything down (the
/// LuckRing discipline; vendor equivalent in `x5/d.java h()` / `r5/b.java`).
@MainActor
final class RWfitDriver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let legacyCodec = RWfitLegacyCodec()
    private let jlCodec = RWfitJLCodec()
    private let clock = RWfitClock()
    private let decoder: RWfitDecoder
    private let gate: RWfitCommandGate
    /// The history pager. Driver-owned because only the driver sees frames (`noteReceived`); handed
    /// to the engine so `runStartup`/`syncHistory` can seed passes.
    private let historySync: RWfitHistorySync

    /// The wire framing of the current link. Defaults to `.legacy` (the harmless direction — see
    /// `RWfitFraming`) until `servicesDiscovered` decides.
    private(set) var framing: RWfitFraming = .legacy

    /// Everything this unit has claimed so far — framing-implied realtime commands plus whatever the
    /// feature reply / bind TLV granted. Grows monotonically; each growth is re-published whole
    /// because `RingBLEClient.applySupportFunctions` recomputes from the latest set (last write
    /// wins, so partial announcements would drop earlier grants).
    private var derivedCapabilities: Set<WearableCapability> = []
    /// Whether this link has already folded the framing-implied capabilities in.
    private var framingCapabilitiesAnnounced = false

    /// The on-demand measurement commands are JieLi-only — the vendor app has no legacy sender for
    /// them — so a JieLi link grants the manual/realtime set the coordinator pre-approved.
    static let jieliRealtimeCapabilities: Set<WearableCapability> = [
        .realtimeHeartRate, .manualHeartRate, .manualSpo2,
    ]

    init(writer: RingCommandWriter) {
        self.writer = writer
        self.decoder = RWfitDecoder(clock: clock)
        self.gate = RWfitCommandGate(writer: writer, legacyCodec: legacyCodec, jlCodec: jlCodec)
        self.historySync = RWfitHistorySync(gate: gate)
    }

    // MARK: - BLE topology

    let serviceUUIDs: [CBUUID] = [CBUUID(string: RWfitUUIDs.service)]
    let writeUUID = CBUUID(string: RWfitUUIDs.write)
    let notifyUUIDs: [CBUUID] = [CBUUID(string: RWfitUUIDs.notify)]
    let batteryServiceUUID: CBUUID? = nil    // battery is in-band (legacy 0x01 / JieLi 02 03 10)
    let batteryCharUUID: CBUUID? = nil
    /// Single notify channel; declaring it documents that nothing may fire before B003 notifies.
    var requiredSubscriptionsBeforeConnected: [CBUUID] { notifyUUIDs }

    /// Identity — the command gate and codecs emit fully framed packets.
    func frame(_ command: Data) -> Data { command }

    // MARK: - Framing selection

    func servicesDiscovered(_ services: [CBUUID]) {
        let jieliMarkers = [RWfitUUIDs.jieli, RWfitUUIDs.telinkOTA, RWfitUUIDs.pixartOTA]
            .map { CBUUID(string: $0) }
        framing = services.contains(where: jieliMarkers.contains) ? .jieli : .legacy
        gate.framing = framing
        historySync.framing = framing
    }

    // MARK: - Lifecycle

    /// Auto-reconnect reuses this driver: stale reassembly would corrupt the new link's first
    /// frames, and a half-run history pass would mis-bucket its types. Framing is re-decided by the
    /// fresh discovery pass; derived capabilities persist (a unit's sensors don't change between
    /// links) but the framing grant is re-folded per link in case the firmware changed shape.
    func connectionDidStart() {
        legacyCodec.reset()
        jlCodec.reset()
        gate.cancel()
        historySync.cancel()
        framingCapabilitiesAnnounced = false
    }

    /// The pager's settle/stall timers and the gate's retry timer must not refill the write queue
    /// across the reconnect gap.
    func connectionDidEnd() {
        legacyCodec.reset()
        jlCodec.reset()
        gate.cancel()
        historySync.cancel()
    }

    // MARK: - Inbound

    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        var events = framing == .jieli ? ingestJieli(data) : ingestLegacy(data)

        // Fold the framing-implied capabilities in once per link, piggybacked on the first inbound
        // frame — the earliest moment an event can flow up to `applySupportFunctions`.
        if framing == .jieli, !framingCapabilitiesAnnounced {
            framingCapabilitiesAnnounced = true
            derivedCapabilities.formUnion(Self.jieliRealtimeCapabilities)
            events.append(.supportFunctions(derivedCapabilities))
        }
        return events
    }

    private func ingestLegacy(_ data: Data) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for inbound in legacyCodec.decode(data) {
            switch inbound {
            case let .ackNeeded(cmd, serial):
                // ACK before decode — the ring retransmits until we answer.
                writer?.enqueue(legacyCodec.ack(cmd: cmd, serial: serial, status: 0x00))
            case let .checksumFailed(cmd, serial):
                // NACK (status 2) asks the device to retransmit the frame (`x5/d.java h()`).
                writer?.enqueue(legacyCodec.ack(cmd: cmd, serial: serial, status: 0x02))
            case let .deviceAck(cmd, serial, _):
                gate.noteLegacyAck(cmd: cmd, serial: serial)
            case let .frame(cmd, payload):
                if let type = RWfitHistoryType(legacyCommand: cmd) {
                    historySync.noteReceived(type: type)
                }
                events.append(contentsOf: intercept(decoder.decodeLegacy(cmd: cmd, payload: payload)))
            }
        }
        return events
    }

    private func ingestJieli(_ data: Data) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for inbound in jlCodec.decode(data) {
            switch inbound {
            case let .deviceAck(triple):
                gate.noteJieliAck(triple: triple)
            case .crcFailed:
                break   // the vendor drops silently; the ring retransmits on its own
            case let .frame(triple, payload):
                // ACK before decode (flag 0x11, triple echoed — `r5/b.java`).
                writer?.enqueue(jlCodec.ack(triple: triple))
                if triple.cmd == 0x05, let type = RWfitHistoryType(jlType: triple.key) {
                    historySync.noteReceived(type: type)
                }
                events.append(contentsOf: intercept(decoder.decodeJieli(triple: triple, payload: payload)))
            }
        }
        return events
    }

    /// Fold any decoder capability grant into the cumulative set before it goes up — the client's
    /// refinement recomputes from whatever set it last saw, so every announcement must be the whole
    /// truth so far, not just this frame's contribution.
    private func intercept(_ decoded: [RingDecodedEvent]) -> [RingDecodedEvent] {
        decoded.map { event in
            guard case let .supportFunctions(granted) = event else { return event }
            derivedCapabilities.formUnion(granted)
            return .supportFunctions(derivedCapabilities)
        }
    }

    func makeSyncEngine() -> RingSyncEngine {
        RWfitSyncEngine(gate: gate, historySync: historySync, clock: clock, framingProvider: { [weak self] in
            self?.framing ?? .legacy
        })
    }
}
