import Foundation

/// The RWfit protocol-level command queue: **one outstanding command at a time**, released by the
/// device's transport ACK (legacy `0xFE` matching our serial+cmd; JieLi flag-0x11 matching our
/// triple) or by a timeout after one retry. Mirrors `x5/d.java` / `x5/c.java`'s LinkedList queues,
/// including their inter-command spacing (100 ms legacy / 230 ms JieLi).
///
/// Lives behind the driver (which owns the codecs and sees the ACKs); the sync engine and history
/// pager submit logical `RWfitOutbound` commands and never see wire bytes. Our own outbound ACK
/// frames deliberately bypass this queue — they expect no reply, and delaying one stalls the ring's
/// retransmit loop (the vendor's `b3 == -1` fast path).
@MainActor
final class RWfitCommandGate {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let legacyCodec: RWfitLegacyCodec
    private let jlCodec: RWfitJLCodec

    /// Response timeout per attempt; the vendor allows 2 retries at a shorter spacing, but
    /// `RingBLEClient`'s own 4 s GATT write-ACK timeout already covers the transport layer, so one
    /// protocol retry is enough to survive a dropped notification.
    private let responseTimeout: TimeInterval
    private let legacySpacing: TimeInterval = 0.1
    private let jieliSpacing: TimeInterval = 0.23

    /// The framing every submitted command is framed with. Set by the driver at service discovery,
    /// before anything can be submitted (`runStartup` runs after `.connected`).
    var framing: RWfitFraming = .legacy

    private var queue: [RWfitOutbound] = []
    private var inFlight: RWfitOutbound?
    private var inFlightSerial = 0
    private var retried = false
    private var timeoutTask: Task<Void, Never>?
    private var spacingTask: Task<Void, Never>?

    init(
        writer: RingCommandWriter?,
        legacyCodec: RWfitLegacyCodec,
        jlCodec: RWfitJLCodec,
        responseTimeout: TimeInterval = 2
    ) {
        self.writer = writer
        self.legacyCodec = legacyCodec
        self.jlCodec = jlCodec
        self.responseTimeout = responseTimeout
    }

    var isIdle: Bool { inFlight == nil && queue.isEmpty }

    /// Enqueue a logical command; sends immediately when the channel is free.
    func submit(_ command: RWfitOutbound) {
        queue.append(command)
        pump()
    }

    /// Drop everything (disconnect/teardown). In-flight state must not survive into the next link —
    /// its serial would never match and would wedge the queue.
    func cancel() {
        timeoutTask?.cancel(); timeoutTask = nil
        spacingTask?.cancel(); spacingTask = nil
        queue.removeAll()
        inFlight = nil
        retried = false
    }

    // MARK: - ACKs from the device (driver calls these from `ingest`)

    /// Legacy `0xFE`: release when serial and cmd match the in-flight command (`x5/d.java i()`).
    func noteLegacyAck(cmd: UInt8, serial: Int) {
        guard case let .legacy(inCmd, _)? = inFlight, inCmd == cmd, serial == inFlightSerial else { return }
        release()
    }

    /// JieLi flag-0x11: release when the echoed triple matches (`x5/c.java f()`).
    func noteJieliAck(triple: RWfitJLTriple) {
        guard case let .jieli(payload)? = inFlight, payload.count >= 3,
              payload[0] == triple.cmd, payload[1] == triple.key, payload[2] == triple.keyFlag
        else { return }
        release()
    }

    // MARK: - Pump

    private func pump() {
        guard inFlight == nil, spacingTask == nil, !queue.isEmpty else { return }
        let command = queue.removeFirst()
        inFlight = command
        retried = false
        send(command)
    }

    private func send(_ command: RWfitOutbound) {
        switch command {
        case let .legacy(cmd, payload):
            let encoded = legacyCodec.encode(cmd: cmd, payload: payload)
            inFlightSerial = encoded.serial
            writer?.enqueue(encoded.frame)
        case let .jieli(payload):
            writer?.enqueue(jlCodec.encode(payload: payload))
        }
        armTimeout()
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            let nanos = UInt64((self?.responseTimeout ?? 2) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.timedOut()
        }
    }

    private func timedOut() {
        guard let command = inFlight else { return }
        if retried {
            // Two silent attempts: drop it and move on — wedging the queue on one lost command
            // starves everything behind it (the vendor does the same after its retry budget).
            release()
        } else {
            retried = true
            send(command)
        }
    }

    private func release() {
        timeoutTask?.cancel(); timeoutTask = nil
        inFlight = nil
        // Inter-command spacing: the firmware drops back-to-back commands (the vendor paces at
        // 100/230 ms), so the next send waits out the gap.
        let spacing = framing == .jieli ? jieliSpacing : legacySpacing
        spacingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.spacingTask = nil
            self.pump()
        }
    }
}
