import ScrecMedia
import XCTest

@testable import ScrecKit

final class VideoPlanTests: XCTestCase {
    /// A MacBook's built-in display, in points.
    let screen = CGSize(width: 1800, height: 1169)

    func plan(_ options: Options = Options(), points: CGSize? = nil, scale: CGFloat = 2) -> VideoPlan {
        VideoPlan(points: points ?? screen, pixelScale: scale, options: options)
    }

    func testResolutionFollowsThePixelScaleAndIsEven() {
        let plan = plan()
        XCTAssertEqual(plan.width, 3600)
        XCTAssertEqual(plan.height, 2338)
        XCTAssertEqual(self.plan(points: CGSize(width: 101, height: 77), scale: 1).width % 2, 0)
        XCTAssertEqual(self.plan(points: CGSize(width: 101, height: 77), scale: 1).height % 2, 0)
    }

    func testPresetsSetBitrateAndResolution() {
        var options = Options()
        XCTAssertEqual(plan(options).bitrate, 12_625_200)  // medium: 1.5 bits per pixel
        options.quality = .high
        XCTAssertEqual(plan(options).bitrate, 25_250_400)  // high: twice that
        options.quality = .low
        let low = plan(options)
        XCTAssertEqual(low.width, 1800)  // low halves the resolution
        XCTAssertEqual(low.height, 1168)
        XCTAssertEqual(low.bitrate, 3_153_600)
    }

    func testExplicitScaleOverridesThePreset() {
        var options = Options()
        options.quality = .low
        options.scale = 1
        XCTAssertEqual(plan(options).width, 3600)
    }

    func testHEVCNeedsLessBitrate() {
        var options = Options()
        options.hevc = true
        XCTAssertEqual(plan(options).bitrate, 7_575_120)
    }

    func testExplicitBitrateWinsAndIsInMegabits() {
        var options = Options()
        options.bitrate = 4
        XCTAssertEqual(plan(options).bitrate, 4_000_000)
    }

    func testAnExplicitBitrateIsNotRaisedToTheFloor() {
        var options = Options()
        options.bitrate = 0.1
        XCTAssertEqual(plan(options).bitrate, 100_000)
    }

    func testBitrateHasAFloor() {
        var options = Options()
        options.quality = .low
        XCTAssertEqual(plan(options, points: CGSize(width: 16, height: 16), scale: 1).bitrate, 300_000)
    }

    func testSizePerHourIncludesAudio() {
        let plan = plan()
        XCTAssertEqual(plan.bytesPerHour, Double(plan.bitrate + MovieSettings.audioBitrate) / 8 * 3600)
        XCTAssertEqual(formatBytes(plan.bytesPerHour), "5.8 GB")
        XCTAssertEqual(plan.megabits, "12.6 Mbps")
    }

    func testMovieSettingsCarryTheEncodingChoices() {
        var options = Options()
        options.fps = 30
        options.hevc = true
        options.mic = true
        let plan = plan(options)
        XCTAssertEqual(
            plan.movieSettings(for: options),
            MovieSettings(width: plan.width, height: plan.height, videoBitrate: plan.bitrate, frameRate: 30, hevc: true, microphone: true))
    }
}

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(formatBytes(3_407), "3 KB")
        XCTAssertEqual(formatBytes(1_605_144), "2 MB")
        XCTAssertEqual(formatBytes(801_000_000), "801 MB")
        XCTAssertEqual(formatBytes(5_800_000_000), "5.8 GB")
    }

    func testClock() {
        XCTAssertEqual(formatClock(0), "0:00")
        XCTAssertEqual(formatClock(12.9), "0:12")
        XCTAssertEqual(formatClock(61), "1:01")
        XCTAssertEqual(formatClock(3599), "59:59")
        XCTAssertEqual(formatClock(3723), "1:02:03")
    }
}
