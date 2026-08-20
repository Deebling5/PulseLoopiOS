import Foundation

/// Pure byte → `RingDecodedEvent` parsers for both RWfit framings. Every layout is a port of the
/// vendor parser cited on it (`x5/b.java` unless noted); offsets are kept identical to the Java so
/// a fixture disagreement points straight at the source line.
///
/// Legacy history payloads arrive as one or more **day blocks** concatenated; JieLi history payloads
/// carry the 3-byte command triple at [0..2] and fixed-stride items from offset 3. All multi-byte
/// fields are big-endian; timestamps are local wall-clock epochs converted through `RWfitClock`.
struct RWfitDecoder {
    let clock: RWfitClock

    // MARK: - Legacy (0x7E family)

    func decodeLegacy(cmd: UInt8, payload: [UInt8]) -> [RingDecodedEvent] {
        let bytes = payload
        switch cmd {
        case RWfitLegacyCommand.deviceInfo:
            return decodeLegacyDeviceInfo(bytes)
        case RWfitLegacyCommand.battery, 0x60:
            // `[lowPower, powerStatus, power]` (`x5/b.java:3204`; 0x60 is the push variant).
            guard bytes.count >= 3 else { return [.unknown(commandId: cmd, raw: Data(bytes))] }
            return [.battery(percent: Int(bytes[2]))]
        case RWfitLegacyCommand.bindStatus:
            // `[bindStatus, bindType, userId UTF-16LE…]` (`c()` @1639). Diagnostic only.
            guard bytes.count >= 2 else { return [.unknown(commandId: cmd, raw: Data(bytes))] }
            return [.bind(action: bytes[0], state: bytes[1])]
        case RWfitLegacyCommand.features:
            return [.supportFunctions(Self.capabilities(fromLegacyFeatures: bytes))]
        case RWfitLegacyCommand.syncManifest:
            // Consumed by the history pager via the driver; nothing to persist.
            return [.commandAck(commandId: cmd)]
        default:
            return decodeLegacyHistory(cmd: cmd, bytes: bytes)
                ?? [.unknown(commandId: cmd, raw: Data(bytes))]
        }
    }

    /// The `0xA1`–`0xA7` history streams, split out of `decodeLegacy` so neither switch grows past
    /// the project's cyclomatic-complexity limit. nil ⇒ not a history command.
    private func decodeLegacyHistory(cmd: UInt8, bytes: [UInt8]) -> [RingDecodedEvent]? {
        switch cmd {
        case RWfitLegacyCommand.stepsHistory:
            return decodeLegacySteps(bytes)
        case RWfitLegacyCommand.sleepHistory:
            return decodeLegacySleep(bytes)
        case RWfitLegacyCommand.heartRateHistory:
            return decodeLegacyValueSeries(bytes, cmd: cmd) { ts, item in
                item[4] > 0 ? [.historyMeasurement(kind: .heartRate, value: Double(item[4]), timestamp: ts)] : []
            }
        case RWfitLegacyCommand.spo2History:
            return decodeLegacyValueSeries(bytes, cmd: cmd) { ts, item in
                item[4] > 0 ? [.historyMeasurement(kind: .spo2, value: Double(item[4]), timestamp: ts)] : []
            }
        case RWfitLegacyCommand.bloodPressureHistory:
            // 6-byte items `[ts u32][systolic][diastolic]` (`s0()`); split so each trends alone.
            return decodeLegacyValueSeries(bytes, cmd: cmd, itemStride: 6) { ts, item in
                guard item[4] > 0, item[5] > 0 else { return [] }
                return [
                    .historyMeasurement(kind: .bloodPressureSystolic, value: Double(item[4]), timestamp: ts),
                    .historyMeasurement(kind: .bloodPressureDiastolic, value: Double(item[5]), timestamp: ts),
                ]
            }
        case RWfitLegacyCommand.temperatureHistory:
            // `(raw + 200) / 10` °C (`u0()`) — raw 0 would be 20.0 °C, so treat 0 as "no sample".
            return decodeLegacyValueSeries(bytes, cmd: cmd) { ts, item in
                item[4] > 0
                    ? [.historyMeasurement(kind: .temperature, value: (Double(item[4]) + 200) / 10, timestamp: ts)]
                    : []
            }
        case RWfitLegacyCommand.breatheHistory:
            return decodeLegacyValueSeries(bytes, cmd: cmd) { ts, item in
                item[4] > 0
                    ? [.historyMeasurement(kind: .respiratoryRate, value: Double(item[4]), timestamp: ts)]
                    : []
            }
        default:
            return nil
        }
    }

    /// `[len, deviceClazz UTF-8, len2, deviceNo UTF-8]` (`o()` @2259).
    private func decodeLegacyDeviceInfo(_ bytes: [UInt8]) -> [RingDecodedEvent] {
        guard !bytes.isEmpty else { return [.unknown(commandId: RWfitLegacyCommand.deviceInfo, raw: Data())] }
        let clazzLen = Int(bytes[0])
        guard bytes.count >= 1 + clazzLen + 1 else {
            return [.unknown(commandId: RWfitLegacyCommand.deviceInfo, raw: Data(bytes))]
        }
        let clazz = String(bytes: bytes[1..<(1 + clazzLen)], encoding: .utf8) ?? ""
        let noLen = Int(bytes[1 + clazzLen])
        let noStart = 2 + clazzLen
        let deviceNo = bytes.count >= noStart + noLen
            ? String(bytes: bytes[noStart..<(noStart + noLen)], encoding: .utf8) ?? ""
            : ""
        let version = [clazz, deviceNo].filter { !$0.isEmpty }.joined(separator: " ")
        return version.isEmpty
            ? [.commandAck(commandId: RWfitLegacyCommand.deviceInfo)]
            : [.firmware(version: version)]
    }

    /// Legacy day-series template: `[ts u32][count u16]` + `count` fixed-stride items whose first
    /// four bytes are the item's own timestamp (`w0()`/`r0()`/`s0()`/`u0()`/`t0()`).
    private func decodeLegacyValueSeries(
        _ bytes: [UInt8],
        cmd: UInt8,
        itemStride: Int = 5,
        item decodeItem: (Date, [UInt8]) -> [RingDecodedEvent]
    ) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        var offset = 0
        while offset + 6 <= bytes.count {
            let count = RWfitBytes.u16BE(bytes, offset + 4)
            offset += 6
            for _ in 0..<count {
                guard offset + itemStride <= bytes.count else { return events }
                let item = Array(bytes[offset..<(offset + itemStride)])
                let timestamp = clock.date(fromLegacyEpoch: RWfitBytes.u32BE(item, 0))
                events.append(contentsOf: decodeItem(timestamp, item))
                offset += itemStride
            }
        }
        return events.isEmpty ? [.commandAck(commandId: cmd)] : events
    }

    /// Steps day blocks (`C0()` @397): 15-byte header `[ts u32][steps u24][kcal u24][dist u24]
    /// [count u16]` + `count` × 8-byte slot items `[slotIndex][steps u16][kcal u24][dist u16]`.
    ///
    /// The slot items are published as **one bucket per day** using the header totals: the slot
    /// index's wall-clock width is not derivable from the protocol (an open question for the first
    /// hardware capture), and a wrong width would scatter steps across the wrong hours. A single
    /// day bucket keeps the daily total exact — the persistence layer sums distinct buckets per day.
    private func decodeLegacySteps(_ bytes: [UInt8]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        var offset = 0
        while offset + 15 <= bytes.count {
            let dayStart = clock.date(fromLegacyEpoch: RWfitBytes.u32BE(bytes, offset))
            let steps = RWfitBytes.u24BE(bytes, offset + 4)
            let distance = Double(RWfitBytes.u24BE(bytes, offset + 10))
            let count = RWfitBytes.u16BE(bytes, offset + 13)
            offset += 15 + count * 8
            if steps > 0 {
                events.append(.activityBucket(timestamp: dayStart, steps: steps, distanceMeters: distance))
            }
        }
        return events.isEmpty ? [.commandAck(commandId: RWfitLegacyCommand.stepsHistory)] : events
    }

    /// Sleep night blocks (`A0()` @180): 16-byte header `[night ts u32][totalMin u16]
    /// [asleep epoch u32][awake epoch u32][count u16]` + `count` × 2-byte items `[minutes][type]`,
    /// type 0 = awake, 1 = light, 2 = deep, 3 = REM (`service/s1.java:1635`). Items run
    /// consecutively from the asleep epoch; expanded to per-minute stages for `.sleepTimeline`.
    private func decodeLegacySleep(_ bytes: [UInt8]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        var offset = 0
        while offset + 16 <= bytes.count {
            let asleep = clock.date(fromLegacyEpoch: RWfitBytes.u32BE(bytes, offset + 6))
            let count = RWfitBytes.u16BE(bytes, offset + 14)
            offset += 16
            var stages: [SleepStage] = []
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { break }
                let minutes = Int(bytes[offset])
                stages.append(contentsOf: Array(repeating: Self.legacySleepStage(bytes[offset + 1]), count: minutes))
                offset += 2
            }
            if !stages.isEmpty {
                events.append(.sleepTimeline(timestamp: asleep, stages: stages))
            }
        }
        return events.isEmpty ? [.commandAck(commandId: RWfitLegacyCommand.sleepHistory)] : events
    }

    private static func legacySleepStage(_ type: UInt8) -> SleepStage {
        switch type {
        case 0: return .awake
        case 1: return .light
        case 2: return .deep
        case 3: return .rem
        default: return .unknown
        }
    }

    /// Legacy `0x03` SupportMenuBean bitmap, byte 0 LSB-first: step, sleep, hr, bloodPress,
    /// bloodOxy, bodyTemp, ecg, breathe (`x5/b.java:1872`). Only the bits that gate a
    /// `WearableCapability` are mapped; the baseline metrics don't need their bits.
    static func capabilities(fromLegacyFeatures bytes: [UInt8]) -> Set<WearableCapability> {
        guard !bytes.isEmpty else { return [] }
        var caps: Set<WearableCapability> = []
        if bytes[0] & (1 << 3) != 0 { caps.insert(.bloodPressure) }
        if bytes[0] & (1 << 5) != 0 { caps.insert(.temperature) }
        return caps
    }

    // MARK: - JieLi (0xAB family)

    /// `payload` includes the `{CMD, Key, KeyFlag}` triple at [0..2] (vendor parsers start at 3).
    func decodeJieli(triple: RWfitJLTriple, payload: [UInt8]) -> [RingDecodedEvent] {
        switch (triple.cmd, triple.key) {
        case (0x02, 0x03):
            // `[3]` = percent, `[4..5]` = millivolts (`G()`).
            guard payload.count >= 4 else { return [.unknown(commandId: triple.cmd, raw: Data(payload))] }
            return [.battery(percent: Int(payload[3]))]
        case (0x02, 0x04):
            // `[3..5]` = firmware version triplet (`C()` @332).
            guard payload.count >= 6 else { return [.unknown(commandId: triple.cmd, raw: Data(payload))] }
            return [.firmware(version: payload[3...5].map(String.init).joined(separator: "."))]
        case (0x02, 0x01):
            return [.timeSyncAck(timestamp: Date())]
        case (0x03, 0x01):
            return decodeJieliBind(payload)
        case (0x05, _):
            return decodeJieliHistory(key: triple.key, payload: payload)
                ?? [.unknown(commandId: triple.cmd, raw: Data(payload))]
        case (0x06, 0x09):
            return decodeJieliRealtime(payload)
        default:
            return [.unknown(commandId: triple.cmd, raw: Data(payload))]
        }
    }

    /// The `05`-group history streams, split out of `decodeJieli` so neither switch grows past the
    /// project's cyclomatic-complexity limit. nil ⇒ a `05` type we don't decode.
    private func decodeJieliHistory(key: UInt8, payload: [UInt8]) -> [RingDecodedEvent]? {
        switch key {
        case RWfitJLDataType.steps:
            return decodeJieliSteps(payload)
        case RWfitJLDataType.sleep:
            return decodeJieliSleep(payload)
        case RWfitJLDataType.heartRate:
            return decodeJieliSeries(payload, cmd: key) { ts, item in
                item[4] > 0 ? [.historyMeasurement(kind: .heartRate, value: Double(item[4]), timestamp: ts)] : []
            }
        case RWfitJLDataType.spo2:
            return decodeJieliSeries(payload, cmd: key) { ts, item in
                item[4] > 0 ? [.historyMeasurement(kind: .spo2, value: Double(item[4]), timestamp: ts)] : []
            }
        case RWfitJLDataType.bloodPressure:
            // `[4]` systolic, `[5]` diastolic (`T()`).
            return decodeJieliSeries(payload, cmd: key) { ts, item in
                guard item[4] > 0, item[5] > 0 else { return [] }
                return [
                    .historyMeasurement(kind: .bloodPressureSystolic, value: Double(item[4]), timestamp: ts),
                    .historyMeasurement(kind: .bloodPressureDiastolic, value: Double(item[5]), timestamp: ts),
                ]
            }
        case RWfitJLDataType.temperature:
            // `[4..5]` u16 BE ÷ 10 °C (`U()`).
            return decodeJieliSeries(payload, cmd: key) { ts, item in
                let raw = RWfitBytes.u16BE(item, 4)
                return raw > 0
                    ? [.historyMeasurement(kind: .temperature, value: Double(raw) / 10, timestamp: ts)]
                    : []
            }
        case RWfitJLDataType.hrv:
            return decodeJieliSeries(payload, cmd: key) { ts, item in
                item[4] > 0 ? [.historyMeasurement(kind: .hrv, value: Double(item[4]), timestamp: ts)] : []
            }
        case RWfitJLDataType.stress:
            return decodeJieliSeries(payload, cmd: key) { ts, item in
                item[4] > 0 ? [.historyMeasurement(kind: .stress, value: Double(item[4]), timestamp: ts)] : []
            }
        case RWfitJLDataType.bloodSugar:
            // `[4..5]` u16 BE ÷ 10 = mmol/L (`R()`); converted to the mg/dL the app displays.
            return decodeJieliSeries(payload, cmd: key) { ts, item in
                let mmol = Double(RWfitBytes.u16BE(item, 4)) / 10
                return mmol > 0
                    ? [.historyMeasurement(kind: .bloodSugar, value: mmol * 18.016, timestamp: ts)]
                    : []
            }
        default:
            return nil
        }
    }

    /// Bind-status reply (`u()` @2636): `[3]` = bindStatus; from offset 8, a NUL-terminated run of
    /// `(0x05, type)` pairs advertising which `05`-group streams the ring supports — the JieLi
    /// family's capability bitmap.
    private func decodeJieliBind(_ payload: [UInt8]) -> [RingDecodedEvent] {
        guard payload.count >= 4 else { return [.unknown(commandId: 0x03, raw: Data(payload))] }
        var events: [RingDecodedEvent] = [.bind(action: payload[3], state: 0)]
        if payload.count > 8 {
            events.append(.supportFunctions(Self.capabilities(fromJieliBindTLV: Array(payload.dropFirst(8)))))
        }
        return events
    }

    /// Map the bind reply's `(0x05, type)` pairs onto gated capabilities. Scanning stops at the
    /// first NUL, like the vendor (`u()` counts NULs and only reads pairs before the first).
    /// The vendor's own decompile skips type 8 (temperature) — treated here as an R8 artifact and
    /// mapped anyway; a wrong grant renders one empty card, a missed one hides a real sensor.
    static func capabilities(fromJieliBindTLV tlv: [UInt8]) -> Set<WearableCapability> {
        var caps: Set<WearableCapability> = []
        var index = 0
        while index + 1 < tlv.count, tlv[index] != 0 {
            if tlv[index] == 0x05 {
                switch tlv[index + 1] {
                case RWfitJLDataType.bloodPressure: caps.formUnion([.bloodPressure, .manualBloodPressure])
                case RWfitJLDataType.temperature: caps.insert(.temperature)
                case RWfitJLDataType.hrv: caps.formUnion([.hrv, .manualHrv])
                case RWfitJLDataType.stress: caps.insert(.stress)
                case RWfitJLDataType.bloodSugar: caps.insert(.bloodSugar)
                default: break
                }
            }
            index += 2
        }
        return caps
    }

    /// JieLi 6-byte-stride series template: items from offset 3, `[ts2000 u32][value][…]`
    /// (`V()`/`S()`/`T()`/`U()`/`W()`/`Y()`/`R()`).
    private func decodeJieliSeries(
        _ payload: [UInt8],
        cmd: UInt8,
        item decodeItem: (Date, [UInt8]) -> [RingDecodedEvent]
    ) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        var offset = 3
        while offset + 6 <= payload.count {
            let item = Array(payload[offset..<(offset + 6)])
            let timestamp = clock.date(fromJieliEpoch: RWfitBytes.u32BE(item, 0))
            events.append(contentsOf: decodeItem(timestamp, item))
            offset += 6
        }
        return events.isEmpty ? [.commandAck(commandId: cmd)] : events
    }

    /// JieLi steps (`a0()` @1549): 16-byte records `[ts2000 u32][pad][steps u24][kcal×10 u32]
    /// [distance u32]`. The vendor renders `distance / 10000` (km), so the raw unit is decimetres —
    /// ÷10 for metres. One record per day slot; published as buckets so re-syncs upsert.
    private func decodeJieliSteps(_ payload: [UInt8]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        var offset = 3
        while offset + 16 <= payload.count {
            let timestamp = clock.date(fromJieliEpoch: RWfitBytes.u32BE(payload, offset))
            let steps = RWfitBytes.u24BE(payload, offset + 5)
            let distanceMeters = Double(RWfitBytes.u32BE(payload, offset + 12)) / 10
            offset += 16
            if steps > 0 {
                events.append(.activityBucket(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters))
            }
        }
        return events.isEmpty ? [.commandAck(commandId: RWfitJLDataType.steps)] : events
    }

    /// JieLi sleep (`Z()` @1520 + reconstruction in `service/s1.java:1004`): 7-byte records
    /// `[ts2000 u32][sleepModel][pad2]` forming a **stage-transition stream**: `0x11` opens a
    /// session (its first segment counts as light sleep), `0x22` closes it, and 1/2/3-or-0/4 mark
    /// deep/light/awake/REM segments whose lengths are the gaps between consecutive records.
    private func decodeJieliSleep(_ payload: [UInt8]) -> [RingDecodedEvent] {
        var records: [(timestamp: Date, model: UInt8)] = []
        var offset = 3
        while offset + 7 <= payload.count {
            records.append((
                timestamp: clock.date(fromJieliEpoch: RWfitBytes.u32BE(payload, offset)),
                model: payload[offset + 4]
            ))
            offset += 7
        }

        var events: [RingDecodedEvent] = []
        var sessionStart: Date?
        var stages: [SleepStage] = []
        for (index, record) in records.enumerated() {
            if record.model == 0x11 {
                sessionStart = record.timestamp
                stages = []
            }
            guard let start = sessionStart else { continue }
            if record.model == 0x22 {
                if !stages.isEmpty {
                    events.append(.sleepTimeline(timestamp: start, stages: stages))
                }
                sessionStart = nil
                stages = []
                continue
            }
            // Segment length = gap to the next record (`s1.java`'s consecutive-delta division).
            guard index + 1 < records.count else { continue }
            let minutes = Int(records[index + 1].timestamp.timeIntervalSince(record.timestamp) / 60)
            guard minutes > 0, minutes < 24 * 60 else { continue }
            stages.append(contentsOf: Array(repeating: Self.jieliSleepStage(record.model), count: minutes))
        }
        return events.isEmpty ? [.commandAck(commandId: RWfitJLDataType.sleep)] : events
    }

    private static func jieliSleepStage(_ model: UInt8) -> SleepStage {
        switch model {
        case 1: return .deep
        case 2: return .light
        case 3, 0: return .awake
        case 4: return .rem
        case 0x11: return .light   // session-start marker doubles as the first light segment
        default: return .unknown
        }
    }

    /// Realtime-measure reply (`x5/b.java:3734`, internal id 31): `[3]` echoes the measurement type,
    /// `[5]` carries the reading **minus 10** (the vendor displays `data[5] + 10`; presumably a
    /// transport offset so 0 can mean "measuring"). Zero → still measuring, surfaced as an ack.
    private func decodeJieliRealtime(_ payload: [UInt8]) -> [RingDecodedEvent] {
        guard payload.count > 5, payload[5] > 0 else { return [.commandAck(commandId: 0x06)] }
        let value = Int(payload[5]) + 10
        let now = Date()
        switch payload[3] {
        case RWfitJLDataType.heartRate: return [.heartRateSample(bpm: value, timestamp: now)]
        case RWfitJLDataType.spo2: return [.spo2Result(value: value, timestamp: now)]
        case RWfitJLDataType.hrv: return [.hrvSample(value: value, timestamp: now)]
        case RWfitJLDataType.stress: return [.stressSample(value: value, timestamp: now)]
        default: return [.unknown(commandId: 0x06, raw: Data(payload))]
        }
    }
}
