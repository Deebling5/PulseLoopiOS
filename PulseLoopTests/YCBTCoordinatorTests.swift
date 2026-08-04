import XCTest
import CoreBluetooth
@testable import PulseLoop

/// What makes an R10M an R10M: its advertised identity and its capability set. The protocol itself is
/// the shared `YCBT*` stack, covered by the other YCBT suites.
@MainActor
final class YCBTCoordinatorTests: XCTestCase {
    private func advertisement(services: [String] = [], manufacturer: Data? = nil) -> AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: services.map { CBUUID(string: $0) }, manufacturerData: manufacturer)
    }

    // MARK: Matching

    /// Both separators have been observed on the hardware. `R10M FCF4` is the validated unit.
    func testClaimsTheR10MByName() {
        for name in ["R10M FCF4", "R10M_FCF4", "R10M-FCF4", "R10M", "r10m fcf4"] {
            XCTAssertTrue(
                YCBTCoordinator.matches(name: name, advertisement: advertisement()),
                "\(name) should be claimed"
            )
        }
    }

    /// The R10M advertises its proprietary service, unlike the TK5 — so the service alone is enough even
    /// when the local name is something nobody recognizes.
    func testClaimsAnyRingAdvertisingTheProprietaryService() {
        XCTAssertTrue(YCBTCoordinator.matches(
            name: "Unknown Ring",
            advertisement: advertisement(services: [YCBTUUIDs.service])
        ))
    }

    /// A QRing service means the ring answers to `ColmiDriver`. This coordinator is registered ahead of
    /// it, so the disqualifier has to run first and win outright.
    func testRejectsRingsAdvertisingAQRingService() {
        XCTAssertFalse(YCBTCoordinator.matches(
            name: "R10M FCF4",
            advertisement: advertisement(services: [ColmiUUIDs.serviceV1])
        ))
        XCTAssertFalse(YCBTCoordinator.matches(
            name: "R10M FCF4",
            advertisement: advertisement(services: [ColmiUUIDs.serviceV2])
        ))
    }

    /// Registered ahead of `TK5Coordinator` and `ColmiSmartHealthCoordinator`, so it must not claim rings
    /// those families catalog — they are YCBT too, but their capability baselines were written for
    /// different hardware.
    func testDoesNotClaimTheOtherYCBTFamilies() {
        XCTAssertFalse(YCBTCoordinator.matches(name: "TK5 24AA", advertisement: advertisement()))
        XCTAssertFalse(YCBTCoordinator.matches(name: "R99 54DC", advertisement: advertisement()))
        XCTAssertFalse(YCBTCoordinator.matches(name: "R02_A1B2", advertisement: advertisement()))
        XCTAssertFalse(YCBTCoordinator.matches(name: "SMART_RING", advertisement: advertisement()))
        XCTAssertFalse(YCBTCoordinator.matches(name: nil, advertisement: advertisement()))
    }

    /// The Yucheng company ID is shared by every ring in this SDK family, the TK5 included, so it must
    /// not be a claim signal here — `TK5Coordinator` is checked after us and would never get the chance.
    func testDoesNotClaimOnTheSharedManufacturerMarkerAlone() {
        XCTAssertFalse(YCBTCoordinator.matches(
            name: "Some Ring",
            advertisement: advertisement(manufacturer: Data([0x10, 0x78, 0x65, 0x01]))
        ))
    }

    /// Registry order is load-bearing: `ColmiSmartHealthCoordinator`'s `<MODEL> <4 hex>` convention
    /// accepts "R10M FCF4", so it must not be reached first.
    func testIsRegisteredAheadOfTheColmiCoordinators() {
        let order = RingBLEClient.coordinators.map { ObjectIdentifier($0) }
        guard let ycbt = order.firstIndex(of: ObjectIdentifier(YCBTCoordinator.self)),
              let smartHealth = order.firstIndex(of: ObjectIdentifier(ColmiSmartHealthCoordinator.self)),
              let colmi = order.firstIndex(of: ObjectIdentifier(ColmiCoordinator.self)),
              let tk5 = order.firstIndex(of: ObjectIdentifier(TK5Coordinator.self)) else {
            return XCTFail("every YCBT-adjacent coordinator must be registered")
        }
        XCTAssertLessThan(ycbt, smartHealth)
        XCTAssertLessThan(ycbt, colmi)
        XCTAssertLessThan(ycbt, tk5)
    }

    /// The whole point of the family: an R10M resolves to the YCBT driver, not a Colmi one.
    func testScanResolvesAnR10MToTheYCBTFamily() {
        XCTAssertEqual(
            RingBLEClient.matchDeviceType(name: "R10M FCF4", advertisement: advertisement()),
            .ycbt
        )
    }

    // MARK: Capabilities

    /// Everything in the baseline is an unconditional promise — the refinement is additive-only, so the
    /// ring's bitmap can never take one back. Only what the R10M was *seen* doing belongs here.
    func testBaselineIsWhatTheHardwareSessionConfirmed() {
        XCTAssertEqual(YCBTCoordinator().capabilities, [
            .heartRate, .spo2, .steps, .sleep, .remSleep, .battery,
            .manualHeartRate, .manualSpo2,
            .realtimeHeartRate, .realtimeSteps,
            .measurementInterval,
        ])
    }

    /// HRV is gated here and baseline on the TK5 — deliberately. The TK5's HRV was observed and
    /// cross-checked against the vendor app; nobody has seen an R10M produce one, and FW 2.32 does not
    /// declare the bit.
    func testPerSKUSensorsAreBitmapGated() {
        let gated = YCBTCoordinator().bitmapGatedCapabilities
        for capability in [
            WearableCapability.temperature, .bloodPressure, .manualBloodPressure,
            .stress, .fatigue, .bloodSugar, .hrv, .manualHrv, .findDevice,
        ] {
            XCTAssertTrue(gated.contains(capability), "\(capability) should be bitmap-gated")
            XCTAssertFalse(YCBTCoordinator().capabilities.contains(capability), "\(capability) is not baseline")
        }
    }

    /// `.spo2History` is in **neither** set, and that is what stops the `05 1a` query being issued at
    /// all — the R10M has no dedicated SpO₂ log, its all-day SpO₂ rides the `05 09` combined record.
    /// Putting it in the gated set instead would be worse than useless: no bit maps to it, so the gate
    /// could never be satisfied, and the type would be unreachable rather than simply unrequested.
    func testSpo2HistoryIsNeitherBaselineNorGated() {
        let coordinator = YCBTCoordinator()
        XCTAssertFalse(coordinator.capabilities.contains(.spo2History))
        XCTAssertFalse(coordinator.bitmapGatedCapabilities.contains(.spo2History))
    }

    /// A bitmap claiming something outside the gated set cannot smuggle it in.
    func testRefinementStaysAdditiveAndPreApproved() {
        let coordinator = YCBTCoordinator()
        let refined = coordinator.refinedCapabilities(bitmapDerived: [.bloodPressure, .powerOff])
        XCTAssertTrue(refined.contains(.bloodPressure), "a pre-approved claim is granted")
        XCTAssertFalse(refined.contains(.powerOff), "a claim this family never gated is refused")
        XCTAssertTrue(coordinator.capabilities.isSubset(of: refined), "the baseline is never revoked")
    }

    // MARK: Firmware quirks

    /// The two R10M workarounds, asserted where they are declared. Their effect on the wire is covered by
    /// `YCBTEncoderTests`.
    func testDriverCarriesTheR10MFirmwareQuirks() {
        final class Writer: RingCommandWriter {
            nonisolated deinit {}
            func enqueue(_ command: Data) {}
        }
        guard let driver = YCBTCoordinator().makeDriver(writer: Writer()) as? YCBTDriver else {
            return XCTFail("the YCBT family must build a YCBTDriver")
        }
        // Both indication channels are required before the handshake may start.
        XCTAssertEqual(driver.requiredSubscriptionsBeforeConnected, [
            CBUUID(string: YCBTUUIDs.command),
            CBUUID(string: YCBTUUIDs.stream),
        ])
    }

    // MARK: Catalog identity

    func testR10MCatalogEntry() {
        guard let model = WearableModel.model(advertisedName: "R10M FCF4") else {
            return XCTFail("R10M FCF4 must resolve to a catalog model")
        }
        XCTAssertEqual(model.id, "r10m")
        XCTAssertEqual(model.displayName, "R10M (LittleMeatball)")
        XCTAssertEqual(model.brand, "LittleMeatball")
        XCTAssertEqual(model.family, .ycbt)
        XCTAssertEqual(model.imageName, "r10m")
        XCTAssertTrue(model.appVariants.isEmpty, "single-firmware ring — no app-variant picker")
        XCTAssertEqual(WearableModel.model(advertisedName: "R10M_FCF4")?.id, "r10m")
    }

    /// The catalog pattern is narrower than the coordinator's on purpose: this one drives user-facing
    /// identity, and mislabelling a ring is worse than showing it un-named.
    func testCatalogPatternIsNarrowerThanTheCoordinators() {
        XCTAssertNil(WearableModel.model(advertisedName: "R10M-FCF4"))
        XCTAssertNil(WearableModel.model(advertisedName: "R10M"))
        XCTAssertTrue(YCBTCoordinator.matches(name: "R10M-FCF4", advertisement: advertisement()))
    }
}
