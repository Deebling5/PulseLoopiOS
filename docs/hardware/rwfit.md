---
title: RWfit rings
description: >-
  The RWfit-app ring family (com.rw.revivalfit): one A00A GATT, two wire
  protocols (legacy 0x7E and JieLi 0xAB), rebuilt for PulseLoop from the vendor
  app's source with the vendor's cooperation. Steps, HR, SpO₂, sleep, and — per
  ring — BP, HRV, stress, temperature, blood sugar.
---

# RWfit rings

**PulseLoop support: 🧪 Limited — no unit tested on hardware yet**

A commodity smart-ring family whose companion app is **RWfit**
(`com.rw.revivalfit`, v6.0.5 at the time of analysis). The rings are sold under
assorted storefront brands — the one unit we know of in the field was bought as
a **"Colmi"**, though the family shares nothing with the Colmi/QRing protocol.
Unusually, this integration was built **with the vendor's cooperation**: the
company behind the app shared their source, and every byte layout below is
reconstructed from it rather than from packet captures.

!!! warning "Limited support — reconstructed, not yet observed"
    No RWfit ring has been connected to PulseLoop hardware-in-hand. Every layout
    is unit-tested against fixture bytes derived from the vendor parsers, and
    every decoded metric is range-gated before storage, so a misdecode is
    dropped rather than saved as garbage — but the first real diagnostics
    capture is what promotes any of this from "reconstructed" to "observed".
    The open items are tagged **[unconfirmed]** below.

## One GATT, two protocols

Every ring in the family exposes the same data GATT:

| UUID | Role |
|---|---|
| `A00A` | Primary data service |
| `B002` | Write (commands; with-response accepted) |
| `B003` | Notify (replies + pushes) |

But the family spans **two incompatible wire framings**, and the advertisement
does not say which one a given ring speaks. The vendor app decides *after
connecting*, from which sibling services service discovery turns up
(`r5/b.java:684-740` in the decompile):

- **JieLi `AE00`**, the **Telink OTA** service (`00010203-…-0d1912`), or the
  **PixArt OTA** service (`FF00`) present → **JieLi framing** (`0xAB`).
- None of them → **legacy framing** (`0x7E`, "Realtek" in vendor comments).

PulseLoop does the same: the RWfit family is a single device type, and
`RWfitDriver.servicesDiscovered` picks the codec before the first byte is
written. This is the only family that needed a framework hook for it
(`WearableDriver.servicesDiscovered`).

### Discovery / advertisement

The vendor scanner (`r5/d.java:70-134`) recognizes its rings by:

- the advertised **`A00A` service** (its `pidType 1` raw pattern
  `02 01 06 03 03 0a a0` is Flags + a 16-bit service list), or
- **manufacturer data** opening with company ID `0x05D6` (`d6 05 02 00`, or
  `d6 05` + ASCII `AT`) or `0x06D6` (`d6 06 02 00` — the "T-Ring" line).

`RWfitCoordinator` matches exactly these signals and **no names**: rebranders
rename rings, and until a diagnostics export shows a real advertised name, any
name pattern would be a guess.

## Legacy framing (`0x7E`)

Source of truth: `x5/d.java` (framing/queue), `x5/b.java` (parsers),
`…/mlkit_vision_common/p.java` (builders — R8 relocated the SDK's `CmdHelper`).

```
7E 01 <cmd> <flags> <len> <serHi> <serLo> <xor> <payload…>
```

Multi-packet frames set flag bit 3 and insert `totalBE(2) currentBE(2)` at
[8..11]. The checksum is XOR over the payload. Every inbound frame must be
ACKed (app → device cmd `0xFF`, payload `[serHi, serLo, cmd, status]`; status
`0x02` = checksum NACK, triggers retransmit), and the device ACKs app commands
with `0xFE` — the queue is strictly one-outstanding-command.

Commands used: `0x00` device info, `0x01` battery, `0x02`/`0x20` bind status /
bind (userId UTF-16LE), `0x03` feature bitmap, `0x21` set time (local calendar
components), `0x24` units, `0x2E` profile (+ goal), `0x44` unbind,
`0xA0` sync manifest, `0xA1`–`0xA7` history (steps, sleep, HR, BP, SpO₂,
temperature, breathe) — all history requests are empty-payload.

Record layouts (evidence: `x5/b.java`, function @ line):

| Stream | Layout | Evidence | Confidence |
|---|---|---|---|
| Steps | day hdr `[ts u32][steps u24][kcal u24][dist u24][n u16]` + n × 8B slots `[idx][steps u16][kcal u24][dist u16]` | `C0()` @397 | slot *width* unknown → PulseLoop publishes the day totals as one bucket **[unconfirmed: slot duration, distance unit]** |
| HR / SpO₂ / breathe | day hdr `[ts u32][n u16]` + n × 5B `[ts u32][value]` | `w0()` @2914, `r0()` @2457, `t0()` | known |
| Blood pressure | 6B items `[ts u32][sys][dia]` | `s0()` | known |
| Temperature | 5B items; °C = `(raw + 200) / 10` | `u0()` | known |
| Sleep | night hdr `[ts u32][totalMin u16][asleep u32][awake u32][n u16]` + n × 2B `[minutes][type]`; 0 awake / 1 light / 2 deep / 3 REM | `A0()` @180, `s1.java:1635` | known |

The vendor app has **no on-demand measurement command** on this framing — the
measure pages only ever emit the JieLi command — so PulseLoop's manual/live
measurement capabilities are granted only on JieLi links.

## JieLi framing (`0xAB`)

Source of truth: `x5/c.java` (encode), `r5/b.java:386-492` (decode),
`y5/c.java` (the 160-entry `{CMD,Key,KeyFlag}` → internal-id map — the Rosetta
Stone), `y5/d.java` (CRC-16/ARC).

```
AB <flag> <lenHi> <lenLo> <crcHi> <crcLo> <CMD> <Key> <KeyFlag> <data…>
```

`flag` `0x01` = request/push, `0x11` = ACK. `len` and the CRC (CRC-16/ARC,
poly `0xA001` reflected, init 0) cover the payload *including* the 3-byte
triple. Continuation packets are **headerless** — raw payload bytes until `len`
have arrived. Inbound frames are ACKed by echoing the triple with flag `0x11`
(the `06 09` realtime reply gets a 4th `0x00` byte).

Triples used: `02 01 00` set time (year−2000), `02 03 10` battery, `02 04 10`
device info, `02 06 00` profile (height/weight as **little-endian floats** —
the protocol's one LE field), `02 07 00` goal, `02 11 00` units, `03 01 00/20/30`
bind status / bind / unbind, `05 xx 10` history, `06 09 00 <type> 05 <en>`
realtime measure toggle.

History records all start at payload offset 3 (after the triple), timestamps
are **seconds since 2000-01-01** (+946684800):

| Stream | Triple | Layout | Evidence | Confidence |
|---|---|---|---|---|
| Steps | `05 02 10` | 16B `[ts][pad][steps u24][kcal×10 u32][dist u32]` | `a0()` @1549 | distance ÷10 → metres inferred from the app's ÷10000 → km **[unconfirmed: distance unit]** |
| HR / SpO₂ / HRV / stress | `05 03/09/0A/0D 10` | 6B `[ts u32][value][pad]` | `V()` @1291, `S()` @1127, `W()`, `Y()` | known |
| Blood pressure | `05 04 10` | 6B `[ts][sys][dia]` | `T()` | known |
| Temperature | `05 08 10` | 6B `[ts][u16 ÷10 °C]` | `U()` | known |
| Blood sugar | `05 10 10` | 6B `[ts][u16 ÷10 mmol/L]` (→ mg/dL in app) | `R()` | known |
| Sleep | `05 05 10` | 7B `[ts][model][pad2]` **transition stream**: `0x11` session start (first segment = light), `0x22` end, 1 deep / 2 light / 3·0 awake / 4 REM; durations = deltas | `Z()` @1520, `s1.java:1004` | known |
| Realtime reply | `06 09 …` | value = `data[5] + 10`, type echoed at `[3]` | `x5/b.java:3734` | **[unconfirmed: the +10 offset]** |

The bind-status reply (`03 01 00`) carries a trailing `(0x05, type)` TLV run
listing which `05`-group streams the ring supports — the JieLi family's
capability bitmap, which PulseLoop feeds into capability refinement.

## Timestamps & timezone

Both firmwares run their RTC on **local wall-clock time** (the app sets it from
local calendar components) and stamp history with local epochs. **PulseLoop
deliberately diverges from the vendor's conversion math**: the vendor's legacy
parsers add a fixed hour whenever the zone merely *observes* DST (wrong half
the year), and its JieLi parsers use the offset at parse time (wrong across a
DST boundary). PulseLoop latches `secondsFromGMT` at clock-push time
(`RWfitClock`, the `JringClock` contract) so encode and decode always agree.

## Capability policy

- **Baseline** (every unit): HR, SpO₂, steps, sleep (+REM), battery.
- **Bitmap-gated** (granted per unit): temperature, BP, HRV, stress, blood
  sugar — from the legacy `0x03` feature bitmap or the JieLi bind TLV — plus
  the whole manual/realtime measurement set, granted only on JieLi links
  (the legacy protocol has no measure command).
- The vendor's **delete-acks** (`05 xx 30`), which erase synced records from
  the ring, are **never sent** — PulseLoop upserts idempotently, and leaving
  the log intact keeps the original app working alongside.

## Needs on-device confirmation

1. **Which framing real rings speak** (both are implemented; the tester's unit
   decides which one gets validated first).
2. Legacy steps **slot duration** and both framings' **distance units**.
3. The realtime reply's **+10 value offset**.
4. The legacy **bind type byte** (PulseLoop sends `0x01`) and whether binding
   is required at all for history to flow.
5. Advertised **names** for the catalog card's patterns (currently empty).

### The validation loop

Release builds don't store protocol bytes by default. A remote tester can:
Settings → Privacy & Data → Diagnostics → enable **Capture Bluetooth
diagnostics** → pair/sync → **Export diagnostics** → share the JSON. The
export's `rawPackets` rows carry direction, hex, decoded kind and confidence —
`unknown` rows are undecoded opcodes, and the `device`/`logs` sections carry
the advertisement name and connection timeline. Turning the toggle off and
tapping **Clear captured packets** removes the stored bytes.
