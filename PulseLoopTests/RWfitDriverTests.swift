import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The driver's two family-defining behaviours: **framing selection from the discovered GATT**
/// (the whole reason `WearableDriver.servicesDiscovered` exists) and **ACK-before-decode** on both
/// wire protocols — plus the command gate's single-outstanding discipline.
@MainActor
final class RWfitDriverTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
    }

    private let notify = CBUUID(string: RWfitUUIDs.notify)
    private let dataService = CBUUID(string: RWfitUUIDs.service)

    private func deviceFrame(cmd: UInt8, payload: [UInt8], serial: Int = 7) -> Data {
        var bytes: [UInt8] = [0x7e, 0x01, cmd, 0x00, UInt8(payload.count)]
        bytes += RWfitBytes.packU16BE(serial)
        bytes.append(payload.isEmpty ? 0 : RWfitBytes.xorChecksum(payload))
        bytes += payload
        return Data(bytes)
    }

    // MARK: - Framing selection

    func testDefaultsToLegacyFraming() {
        let driver = RWfitDriver(writer: FakeWriter())
        XCTAssertEqual(driver.framing, .legacy)
        driver.servicesDiscovered([dataService])
        XCTAssertEqual(driver.framing, .legacy, "A00A alone means the legacy firmware")
    }

    func testJieliServiceSelectsJieliFraming() {
        let driver = RWfitDriver(writer: FakeWriter())
        driver.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.jieli)])
        XCTAssertEqual(driver.framing, .jieli)
    }

    func testTelinkOrPixartOTAAlsoSelectJieli() {
        // `r5/b.java:703-727`: the Telink/PixArt OTA services flip the same platform flag as AE00.
        let telink = RWfitDriver(writer: FakeWriter())
        telink.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.telinkOTA)])
        XCTAssertEqual(telink.framing, .jieli)

        let pixart = RWfitDriver(writer: FakeWriter())
        pixart.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.pixartOTA)])
        XCTAssertEqual(pixart.framing, .jieli)
    }

    func testReconnectRedecidesFraming() {
        let driver = RWfitDriver(writer: FakeWriter())
        driver.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.jieli)])
        driver.connectionDidEnd()
        driver.connectionDidStart()
        driver.servicesDiscovered([dataService])
        XCTAssertEqual(driver.framing, .legacy, "each link's discovery decides afresh")
    }

    // MARK: - Legacy ingest

    func testLegacyDeviceFrameIsAckedBeforeDecode() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        driver.servicesDiscovered([dataService])

        let events = driver.ingest(deviceFrame(cmd: 0x01, payload: [0, 0, 88], serial: 5), from: notify)

        XCTAssertEqual(writer.sent.count, 1, "a device frame must be ACKed")
        let ack = [UInt8](writer.sent[0])
        XCTAssertEqual(ack[2], RWfitLegacyCommand.appAck)
        XCTAssertEqual(Array(ack[8...]), [0x00, 0x05, 0x01, 0x00], "[serial, cmd, ok]")
        guard case let .battery(percent)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(percent, 88)
    }

    func testLegacyChecksumFailureSendsNack() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        driver.servicesDiscovered([dataService])

        var corrupted = [UInt8](deviceFrame(cmd: 0x01, payload: [0, 0, 88], serial: 5))
        corrupted[8] ^= 0xff
        let events = driver.ingest(Data(corrupted), from: notify)

        XCTAssertTrue(events.isEmpty)
        let nack = [UInt8](writer.sent[0])
        XCTAssertEqual(Array(nack[8...]), [0x00, 0x05, 0x01, 0x02], "status 2 asks for a retransmit")
    }

    // MARK: - JieLi ingest

    func testJieliFrameIsAckedAndCapabilitiesAnnouncedOnce() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        driver.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.jieli)])

        let codec = RWfitJLCodec()
        let events = driver.ingest(codec.encode(payload: [0x02, 0x03, 0x10, 76, 0, 0]), from: notify)

        // ACK first: flag 0x11 + echoed triple.
        XCTAssertEqual(writer.sent.count, 1)
        let ack = [UInt8](writer.sent[0])
        XCTAssertEqual(ack[1], 0x11)
        XCTAssertEqual(Array(ack[6...]), [0x02, 0x03, 0x10])

        // Battery decoded, and the JieLi link's realtime capability grant rides the first ingest.
        guard case .battery? = events.first else { return XCTFail("got \(events)") }
        guard case let .supportFunctions(caps)? = events.last else {
            return XCTFail("expected the framing capability grant, got \(events)")
        }
        XCTAssertTrue(caps.isSuperset(of: RWfitDriver.jieliRealtimeCapabilities))

        // Second frame: no repeat announcement.
        let more = driver.ingest(codec.encode(payload: [0x02, 0x03, 0x10, 75, 0, 0]), from: notify)
        XCTAssertFalse(more.contains { if case .supportFunctions = $0 { true } else { false } })
    }

    func testCapabilityGrantsAccumulateAcrossSources() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        driver.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.jieli)])
        let codec = RWfitJLCodec()

        _ = driver.ingest(codec.encode(payload: [0x02, 0x03, 0x10, 76, 0, 0]), from: notify)
        // Bind reply grants BP via TLV; the announcement must still include the framing grant —
        // `applySupportFunctions` recomputes from the latest set, so partial sets would drop it.
        let bind: [UInt8] = [0x03, 0x01, 0x00, 1, 0, 0, 0, 0, 0x05, 0x04, 0x00]
        let events = driver.ingest(codec.encode(payload: bind), from: notify)
        guard case let .supportFunctions(caps)? = events.last else { return XCTFail("got \(events)") }
        XCTAssertTrue(caps.isSuperset(of: RWfitDriver.jieliRealtimeCapabilities))
        XCTAssertTrue(caps.isSuperset(of: [.bloodPressure, .manualBloodPressure]))
    }

    func testRealtimeAckUsesFourByteQuirk() {
        let writer = FakeWriter()
        let driver = RWfitDriver(writer: writer)
        driver.servicesDiscovered([dataService, CBUUID(string: RWfitUUIDs.jieli)])

        let codec = RWfitJLCodec()
        _ = driver.ingest(codec.encode(payload: [0x06, 0x09, 0x00, 0x03, 0x05, 62]), from: notify)
        let ack = [UInt8](writer.sent[0])
        XCTAssertEqual(Array(ack[6...]), [0x06, 0x09, 0x00, 0x00])
    }

    // MARK: - Command gate

    func testGateHoldsSecondCommandUntilDeviceAck() async {
        let writer = FakeWriter()
        let legacy = RWfitLegacyCodec()
        let gate = RWfitCommandGate(writer: writer, legacyCodec: legacy, jlCodec: RWfitJLCodec())

        gate.submit(.legacy(cmd: 0x01, payload: []))
        gate.submit(.legacy(cmd: 0x02, payload: []))
        XCTAssertEqual(writer.sent.count, 1, "strict single-outstanding")
        XCTAssertEqual([UInt8](writer.sent[0])[2], 0x01)

        gate.noteLegacyAck(cmd: 0x01, serial: 1)
        try? await Task.sleep(nanoseconds: 250_000_000)   // spacing (100 ms) + margin
        XCTAssertEqual(writer.sent.count, 2, "device ACK releases the next command")
        XCTAssertEqual([UInt8](writer.sent[1])[2], 0x02)
    }

    func testGateIgnoresMismatchedAck() async {
        let writer = FakeWriter()
        let gate = RWfitCommandGate(
            writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec()
        )
        gate.submit(.legacy(cmd: 0x01, payload: []))
        gate.submit(.legacy(cmd: 0x02, payload: []))

        gate.noteLegacyAck(cmd: 0x99, serial: 1)   // wrong cmd
        gate.noteLegacyAck(cmd: 0x01, serial: 42)  // wrong serial
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(writer.sent.count, 1, "a mismatched ACK must not release the queue")
        gate.cancel()
    }

    func testGateRetriesOnceThenDropsOnTimeout() async {
        let writer = FakeWriter()
        let gate = RWfitCommandGate(
            writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec(),
            responseTimeout: 0.05
        )
        gate.submit(.legacy(cmd: 0x01, payload: []))
        gate.submit(.legacy(cmd: 0x02, payload: []))

        try? await Task.sleep(nanoseconds: 500_000_000)
        let cmds = writer.sent.map { [UInt8]($0)[2] }
        // 0x02 begins its own attempt/retry cycle once 0x01 is dropped — only the order matters.
        XCTAssertEqual(Array(cmds.prefix(3)), [0x01, 0x01, 0x02],
                       "one retry of 0x01, then the queue moves on")
        gate.cancel()
    }

    func testGateJieliAckMatchesTriple() async {
        let writer = FakeWriter()
        let gate = RWfitCommandGate(
            writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec()
        )
        gate.framing = .jieli
        gate.submit(.jieli(payload: [0x02, 0x03, 0x10]))
        gate.submit(.jieli(payload: [0x02, 0x04, 0x10]))
        XCTAssertEqual(writer.sent.count, 1)

        gate.noteJieliAck(triple: RWfitJLTriple(cmd: 0x02, key: 0x03, keyFlag: 0x10))
        try? await Task.sleep(nanoseconds: 400_000_000)   // spacing (230 ms) + margin
        XCTAssertEqual(writer.sent.count, 2)
        XCTAssertEqual(Array([UInt8](writer.sent[1])[6...]), [0x02, 0x04, 0x10])
        gate.cancel()
    }
}
