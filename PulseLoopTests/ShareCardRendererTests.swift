import XCTest
import SwiftUI
@testable import PulseLoop

@MainActor
final class ShareCardRendererTests: XCTestCase {

    /// Minimal but representative model built memberwise — no store or session needed.
    private func makeModel() -> ShareCardModel {
        ShareCardModel(
            activityLabel: "RUN",
            symbol: "figure.run",
            accent: PulseColors.heartRate,
            dateHeadline: "SAT · JUL 26 · 7:32 AM",
            dateFooter: "July 26, 2026",
            heroStat: ShareCardStat(label: "DISTANCE", value: "5.02", unit: "KM"),
            statRows: [
                [
                    ShareCardStat(label: "DURATION", value: "26:12", unit: nil),
                    ShareCardStat(label: "PACE", value: "5:13", unit: "/KM"),
                    ShareCardStat(label: "AVG HR", value: "152", unit: "BPM")
                ]
            ],
            routeCoordinates: [],
            zoneSegments: [
                ShareZoneSegment(color: PulseColors.zoneBlue, fraction: 0.4),
                ShareZoneSegment(color: PulseColors.zoneMint, fraction: 0.6)
            ],
            hrCaption: "AVG 152 · MAX 171 BPM",
            hasRoute: false
        )
    }

    private func pixelSize(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func testStoryRendersAt1080x1920() {
        let image = ShareCardRenderer.render(model: makeModel(), format: .story)
        XCTAssertNotNil(image, "story render should produce an image")
        XCTAssertEqual(pixelSize(image!), CGSize(width: 1080, height: 1920))
    }

    func testSquareRendersAt1080x1080() {
        let image = ShareCardRenderer.render(model: makeModel(), format: .square)
        XCTAssertNotNil(image, "square render should produce an image")
        XCTAssertEqual(pixelSize(image!), CGSize(width: 1080, height: 1080))
    }

    func testShareImageWrapsPNGWithFilename() {
        let image = ShareCardRenderer.shareImage(
            model: makeModel(), format: .story, date: Date(timeIntervalSince1970: 1_784_000_000)
        )
        XCTAssertNotNil(image)
        XCTAssertFalse(image!.pngData.isEmpty)
        XCTAssertTrue(image!.filename.hasPrefix("pulseloop-run-"))
        XCTAssertTrue(image!.filename.hasSuffix(".png"))
    }
}
