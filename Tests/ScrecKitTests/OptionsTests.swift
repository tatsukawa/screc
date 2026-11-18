import XCTest

@testable import ScrecKit

final class OptionsTests: XCTestCase {
    func testNoArgumentsOpensTheGUI() throws {
        let options = try Options.parse([])
        XCTAssertTrue(options.gui)
        XCTAssertEqual(options.display, 0)
        XCTAssertEqual(options.fps, 60)
        XCTAssertEqual(options.quality, .medium)
        XCTAssertFalse(options.mic)
    }

    func testAnyArgumentSelectsTheCommandLine() throws {
        XCTAssertFalse(try Options.parse(["--display", "0"]).gui)
        XCTAssertTrue(try Options.parse(["--gui", "--hevc"]).gui)
        XCTAssertTrue(try Options.parse(["--gui", "--hevc"]).hevc)
    }

    func testEveryOptionIsParsed() throws {
        let options = try Options.parse([
            "--display", "2", "--region", "10,20,300,200", "--quality", "low", "--scale", "0.5", "--bitrate", "4.5",
            "--fps", "30", "--hevc", "--duration", "12.5", "--mic", "out.mp4",
        ])
        XCTAssertEqual(options.display, 2)
        XCTAssertEqual(options.region, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(options.quality, .low)
        XCTAssertEqual(options.scale, 0.5)
        XCTAssertEqual(options.bitrate, 4.5)
        XCTAssertEqual(options.fps, 30)
        XCTAssertTrue(options.hevc)
        XCTAssertEqual(options.duration, 12.5)
        XCTAssertTrue(options.mic)
        XCTAssertNil(options.micDevice)
        XCTAssertEqual(options.output?.lastPathComponent, "out.mp4")
    }

    func testMicDeviceImpliesMic() throws {
        let options = try Options.parse(["--mic-device", "headset"])
        XCTAssertTrue(options.mic)
        XCTAssertEqual(options.micDevice, "headset")
    }

    func testWindowAndList() throws {
        XCTAssertEqual(try Options.parse(["--window", "Safari"]).window, "Safari")
        XCTAssertTrue(try Options.parse(["--list"]).list)
    }

    func testOutputPathExpandsTheTilde() throws {
        let output = try XCTUnwrap(Options.parse(["~/clip.mp4"]).output)
        XCTAssertEqual(output.path, NSString(string: "~/clip.mp4").expandingTildeInPath)
    }

    func testHelp() {
        XCTAssertThrowsError(try Options.parse(["--help"])) { XCTAssertEqual($0 as? UsageError, .help) }
        XCTAssertThrowsError(try Options.parse(["--display", "0", "-h"])) { XCTAssertEqual($0 as? UsageError, .help) }
    }

    func testInvalidArguments() {
        let invalid: [[String]] = [
            ["--display"],  // missing value
            ["--display", "-1"],
            ["--display", "one"],
            ["--region", "1,2,3"],  // too few numbers
            ["--region", "0,0,0,100"],  // empty
            ["--region", "-1,0,10,10"],  // negative origin
            ["--quality", "best"],
            ["--scale", "2"],
            ["--scale", "0"],
            ["--bitrate", "0"],
            ["--bitrate", "500"],
            ["--fps", "0"],
            ["--fps", "241"],
            ["--duration", "0"],
            ["--window"],
            ["--mic-device"],
            ["--bogus"],
            ["a.mp4", "b.mp4"],  // two outputs
            ["--window", "x", "--region", "0,0,10,10"],  // both a window and a region
            ["--region", "10,typo,20,300,200"],  // a typo must not silently drop a field
            ["--region", "10,,20,300"],  // an empty field
            ["--region", "1,2,3,4,5"],  // too many numbers
            ["--region", "inf,0,10,10"],
            ["--region", "0,0,nan,10"],
            ["--duration", "inf"],  // the timer cannot represent it
            ["--duration", "nan"],
            ["--duration", "1e300"],
            ["--duration", "604801"],  // more than a week
            ["--gui", "--window", "Safari"],  // the picker cannot start from a window
            ["--gui", "--display", "1"],  // nor from a whole display
            ["--gui", "--list"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try Options.parse(arguments), "\(arguments)") { error in
                guard case UsageError.invalid(let message)? = error as? UsageError else {
                    return XCTFail("\(arguments) threw \(error), expected an invalid-argument error")
                }
                XCTAssertFalse(message.isEmpty)
            }
        }
    }

    func testRegionAllowsSpacesAroundNumbers() throws {
        XCTAssertEqual(try Options.parse(["--region", "0, 10, 640, 360"]).region, CGRect(x: 0, y: 10, width: 640, height: 360))
    }

    func testTheGUICanStartFromARegion() throws {
        let options = try Options.parse(["--gui", "--display", "1", "--region", "0,0,640,360"])
        XCTAssertTrue(options.gui)
        XCTAssertEqual(options.display, 1)
        XCTAssertEqual(options.region, CGRect(x: 0, y: 0, width: 640, height: 360))
    }

    func testBoundaryValuesAreAccepted() throws {
        XCTAssertEqual(try Options.parse(["--duration", "604800"]).duration, 604_800)
        XCTAssertEqual(try Options.parse(["--fps", "1"]).fps, 1)
        XCTAssertEqual(try Options.parse(["--fps", "240"]).fps, 240)
        XCTAssertEqual(try Options.parse(["--scale", "0.1"]).scale, 0.1)
        XCTAssertEqual(try Options.parse(["--scale", "1"]).scale, 1)
        XCTAssertEqual(try Options.parse(["--bitrate", "200"]).bitrate, 200)
    }
}
