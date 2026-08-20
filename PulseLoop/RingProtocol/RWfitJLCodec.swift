import Foundation

/// One deframed JieLi (`0xAB`) event, as surfaced to `RWfitDriver.ingest`.
enum RWfitJLInbound: Equatable {
    /// A complete device-initiated frame (flag `0x01`), CRC-verified. `payload` **includes** the
    /// 3-byte `{CMD, Key, KeyFlag}` triple at [0..2] — kept that way so decoder offsets match the
    /// vendor parsers (`x5/b.java`, which all start reading items at offset 3).
    case frame(triple: RWfitJLTriple, payload: [UInt8])
    /// The device ACKed one of our commands (flag `0x11`, triple echoed). Releases the command gate.
    case deviceAck(triple: RWfitJLTriple)
    /// A completed frame failed its CRC. The vendor drops these without a NACK (`r5/b.java`).
    case crcFailed
}

/// JieLi (`0xAB`) wire codec: framing, CRC-16/ARC, ACKs, and inbound continuation reassembly.
/// Byte-for-byte port of the encoder in `x5/c.java g()` and the inline decoder in
/// `r5/b.java onCharacteristicChanged`.
///
/// Header (6 bytes): `AB flag lenHi lenLo crcHi crcLo`, followed by the payload — whose first three
/// bytes are the `{CMD, Key, KeyFlag}` triple and count toward both `len` and the CRC. A payload
/// longer than one notification continues in **headerless** packets: raw payload bytes until `len`
/// have arrived.
@MainActor
final class RWfitJLCodec {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// In-flight reassembly of one logical frame (the protocol interleaves nothing — continuations
    /// immediately follow their header packet, `r5/b.java`'s single `x5.a` state struct).
    private var pendingFlag: UInt8 = 0
    private var pendingCRC: UInt16 = 0
    private var pendingLength = 0
    private var buffer: [UInt8] = []
    private var reassembling = false

    /// Discard any half-assembled frame. Call on connect/disconnect.
    func reset() {
        reassembling = false
        buffer.removeAll()
        pendingLength = 0
    }

    // MARK: - Encode

    /// Frame one payload (triple + data). `isAck: true` sets the reply flag `0x11` — used only for
    /// the ACKs we owe the device; everything else goes out as a request (`0x01`).
    func encode(payload: [UInt8], isAck: Bool = false) -> Data {
        var frame: [UInt8] = [0xab, isAck ? 0x11 : 0x01]
        frame.append(contentsOf: RWfitBytes.packU16BE(payload.count))
        let crc = RWfitBytes.crc16ARC(payload)
        frame.append(UInt8(crc >> 8))
        frame.append(UInt8(crc & 0xff))
        frame.append(contentsOf: payload)
        return Data(frame)
    }

    /// Build the app→device ACK for an inbound frame: flag `0x11`, payload = the echoed triple —
    /// with one quirk: the realtime-measure reply (`CMD 06, Key 09`) is ACKed with a fourth `0x00`
    /// byte (`r5/b.java`'s `if (b3 == 6 && b10 == 9)` special case).
    func ack(triple: RWfitJLTriple) -> Data {
        var payload = triple.bytes
        if triple.cmd == 0x06, triple.key == 0x09 {
            payload.append(0x00)
        }
        return encode(payload: payload, isAck: true)
    }

    // MARK: - Decode

    /// Feed one notification. Returns the events completed by it (usually none mid-reassembly).
    func decode(_ data: Data) -> [RWfitJLInbound] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        if !reassembling {
            // Expecting a header packet. Anything without the magic is noise (e.g. a legacy frame on
            // a mis-detected link) — the vendor logs and drops it; so do we.
            guard bytes.count >= 6, bytes[0] == 0xab else { return [] }
            pendingFlag = bytes[1]
            pendingLength = RWfitBytes.u16BE(bytes, 2)
            pendingCRC = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            buffer = Array(bytes.dropFirst(6))
            reassembling = true
        } else {
            // Headerless continuation: raw payload bytes (`r5/b.java`'s multi-packet branch).
            buffer.append(contentsOf: bytes)
        }

        guard buffer.count >= pendingLength else { return [] }
        let payload = Array(buffer.prefix(pendingLength))
        let flag = pendingFlag
        let expectedCRC = pendingCRC
        reset()

        guard payload.count >= 3 else { return [] }
        guard RWfitBytes.crc16ARC(payload) == expectedCRC else { return [.crcFailed] }
        let triple = RWfitJLTriple(cmd: payload[0], key: payload[1], keyFlag: payload[2])
        return flag == 0x11 ? [.deviceAck(triple: triple)] : [.frame(triple: triple, payload: payload)]
    }
}
