import XCTest
@testable import PulseLoop

/// The RWfit history pager: sequential per-type paging with settle/stall advancement (the LuckRing
/// contract), plus the RWfit-specific wrinkle — types the active framing has no stream for are
/// skipped without a request or a timeout.
@MainActor
final class RWfitHistorySyncTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
        /// Legacy request cmd ids ([2] of each 0x7E frame).
        var legacyCommands: [UInt8] { sent.map { [UInt8]($0)[2] } }
    }

    private final class Spy {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        var stages: [String] = []
        var didFinish: Bool { stages.contains("done") }
    }

    private func makeSync(
        writer: FakeWriter, spy: Spy,
        framing: RWfitFraming = .legacy,
        settle: TimeInterval, stall: TimeInterval
    ) -> (RWfitHistorySync, RWfitCommandGate) {
        let gate = RWfitCommandGate(writer: writer, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec())
        gate.framing = framing
        let sync = RWfitHistorySync(gate: gate, settleSeconds: settle, stallSeconds: stall, progressSink: {
            if case let .syncProgress(stage) = $0 { spy.stages.append(stage) }
        })
        sync.framing = framing
        return (sync, gate)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testSequentialAdvanceOnDataSettle() async {
        let writer = FakeWriter()
        let spy = Spy()
        let (sync, gate) = makeSync(writer: writer, spy: spy, settle: 0.05, stall: 5)

        sync.start(types: [.steps, .sleep])
        XCTAssertEqual(writer.legacyCommands, [RWfitLegacyCommand.stepsHistory],
                       "the first type is requested immediately")

        gate.noteLegacyAck(cmd: RWfitLegacyCommand.stepsHistory, serial: 1)   // free the gate
        sync.noteReceived(type: .steps)
        await sleep(0.3)
        XCTAssertEqual(writer.legacyCommands,
                       [RWfitLegacyCommand.stepsHistory, RWfitLegacyCommand.sleepHistory],
                       "the pass advanced once the steps data settled")

        gate.noteLegacyAck(cmd: RWfitLegacyCommand.sleepHistory, serial: 2)
        sync.noteReceived(type: .sleep)
        await sleep(0.3)
        XCTAssertFalse(sync.isRunning)
        XCTAssertTrue(spy.didFinish)
        gate.cancel()
    }

    func testUnansweredTypeIsSkippedOnStall() async {
        let writer = FakeWriter()
        let spy = Spy()
        let (sync, gate) = makeSync(writer: writer, spy: spy, settle: 5, stall: 0.05)

        sync.start(types: [.temperature])
        await sleep(0.3)
        XCTAssertFalse(sync.isRunning, "a type that never answers is skipped on the stall timeout")
        XCTAssertTrue(spy.didFinish)
        gate.cancel()
    }

    func testFramingUnsupportedTypesAreSkippedWithoutRequests() async {
        // Legacy has no HRV/stress/blood-sugar stream — the pass must complete without writing a
        // single request or burning a stall timeout on them.
        let writer = FakeWriter()
        let spy = Spy()
        let (sync, gate) = makeSync(writer: writer, spy: spy, framing: .legacy, settle: 5, stall: 5)

        sync.start(types: [.hrv, .stress, .bloodSugar])
        XCTAssertTrue(writer.sent.isEmpty, "no request for streams the framing doesn't define")
        XCTAssertFalse(sync.isRunning)
        XCTAssertTrue(spy.didFinish)
        gate.cancel()
    }

    func testJieliSkipsBreatheButRequestsHRV() {
        let writer = FakeWriter()
        let spy = Spy()
        let (sync, gate) = makeSync(writer: writer, spy: spy, framing: .jieli, settle: 5, stall: 5)

        sync.start(types: [.breathe, .hrv])
        XCTAssertEqual(writer.sent.count, 1, "breathe is legacy-only; HRV is requested")
        XCTAssertEqual(Array([UInt8](writer.sent[0])[6...]), [0x05, 0x0a, 0x10])
        sync.cancel()
        gate.cancel()
    }

    func testReEntrantStartIsIgnoredWhileRunning() async {
        let writer = FakeWriter()
        let spy = Spy()
        let (sync, gate) = makeSync(writer: writer, spy: spy, settle: 5, stall: 5)

        sync.start(types: [.steps])
        sync.start(types: [.sleep])   // must not interrupt the in-flight pass
        XCTAssertEqual(writer.legacyCommands, [RWfitLegacyCommand.stepsHistory])
        sync.cancel()
        gate.cancel()
        await sleep(0.05)
    }

    func testCancelStopsThePass() async {
        let writer = FakeWriter()
        let spy = Spy()
        let (sync, gate) = makeSync(writer: writer, spy: spy, settle: 0.05, stall: 0.05)

        sync.start(types: [.steps, .sleep, .heartRate])
        sync.cancel()
        await sleep(0.3)
        XCTAssertEqual(writer.legacyCommands, [RWfitLegacyCommand.stepsHistory],
                       "no request may fire after cancel — timers must be dead")
        XCTAssertFalse(spy.didFinish)
        gate.cancel()
    }
}
