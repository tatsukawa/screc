import AppKit
import XCTest

@testable import ScrecKit

/// A defaults domain of its own for each test, removed afterwards, so tests never touch the user's settings.
final class TemporaryDefaults {
    let name = "screc-tests-\(UUID().uuidString)"
    lazy var store = UserDefaults(suiteName: name)!

    deinit { UserDefaults().removePersistentDomain(forName: name) }
}

final class PreferencesTests: XCTestCase {
    func testDefaults() {
        let preferences = Preferences.load(from: TemporaryDefaults().store)
        XCTAssertEqual(preferences, Preferences())
        XCTAssertEqual(preferences.saveFolder, .movies)
        XCTAssertEqual(preferences.quality, .medium)
        XCTAssertFalse(preferences.hevc)
        XCTAssertEqual(preferences.fps, 60)
        XCTAssertTrue(preferences.showsCursor)
        XCTAssertNil(preferences.microphoneID)
        XCTAssertEqual(preferences.afterSaving, .showInFinder)
    }

    func testEverySettingIsStoredAndReadBack() {
        let defaults = TemporaryDefaults()
        var preferences = Preferences()
        preferences.saveFolder = .custom(URL(fileURLWithPath: "/tmp/recordings", isDirectory: true))
        preferences.quality = .high
        preferences.hevc = true
        preferences.fps = 30
        preferences.showsCursor = false
        preferences.microphoneID = "builtin"
        preferences.afterSaving = .open
        preferences.save(to: defaults.store)
        XCTAssertEqual(Preferences.load(from: defaults.store), preferences)
    }

    func testStandardFoldersAreStoredByName() {
        for folder in [Preferences.SaveFolder.movies, .desktop, .documents] {
            XCTAssertEqual(Preferences.SaveFolder(stored: folder.stored), folder)
            XCTAssertFalse(folder.stored.contains("/"), "a name, so it follows the user's home folder")
        }
        XCTAssertEqual(Preferences.SaveFolder.movies.url.lastPathComponent, "Movies")
    }

    func testInvalidStoredValuesFallBackToTheDefaults() {
        let defaults = TemporaryDefaults()
        defaults.store.set("somewhere", forKey: "saveFolder")
        defaults.store.set("ultra", forKey: "quality")
        defaults.store.set(45, forKey: "fps")
        defaults.store.set("explode", forKey: "afterSaving")
        let preferences = Preferences.load(from: defaults.store)
        XCTAssertEqual(preferences.saveFolder, .movies)
        XCTAssertEqual(preferences.quality, .medium)
        XCTAssertEqual(preferences.fps, 60)
        XCTAssertEqual(preferences.afterSaving, .showInFinder)
    }

    func testPreferencesFillInWhatTheCommandLineDidNotSay() throws {
        var preferences = Preferences()
        preferences.saveFolder = .desktop
        preferences.quality = .low
        preferences.hevc = true
        preferences.fps = 30
        preferences.showsCursor = false
        preferences.microphoneID = "builtin"

        var options = try Options.parse([])
        preferences.overridden(by: options).configure(&options)
        XCTAssertEqual(options.outputDirectory, Preferences.SaveFolder.desktop.url)
        XCTAssertEqual(options.quality, .low)
        XCTAssertTrue(options.hevc)
        XCTAssertEqual(options.fps, 30)
        XCTAssertFalse(options.showsCursor)
        XCTAssertTrue(options.mic)
        XCTAssertEqual(options.micDevice, "builtin")
    }

    func testOptionsGivenOnTheCommandLineWin() throws {
        var preferences = Preferences()
        preferences.quality = .low
        preferences.fps = 30
        preferences.microphoneID = "builtin"

        var options = try Options.parse(["--gui", "--quality", "high", "--fps", "24", "--mic-device", "usb", "--output-dir", "/tmp"])
        preferences.overridden(by: options).configure(&options)
        XCTAssertEqual(options.quality, .high)
        XCTAssertEqual(options.fps, 24)
        XCTAssertEqual(options.micDevice, "usb")
        XCTAssertEqual(options.outputDirectory?.path, "/tmp")

        var named = try Options.parse(["--gui", "~/clip.mp4"])
        preferences.overridden(by: named).configure(&named)
        XCTAssertNil(named.outputDirectory, "an output file was given, so no folder is needed")
    }

    func testNoRememberedMicrophoneMeansNone() throws {
        var options = try Options.parse([])
        Preferences().configure(&options)
        XCTAssertFalse(options.mic)
        XCTAssertNil(options.micDevice)
    }
}

final class DestinationTests: XCTestCase {
    let noon = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheOutputFileWins() throws {
        let options = try Options.parse(["/tmp/clip.mp4"])
        XCTAssertEqual(destinationURL(for: options, now: noon).path, "/tmp/clip.mp4")
    }

    func testRecordingsGoIntoTheOutputDirectory() throws {
        let options = try Options.parse(["--output-dir", "/tmp/recordings"])
        let url = destinationURL(for: options, now: noon)
        XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/recordings")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Recording-"))
        XCTAssertEqual(url.pathExtension, "mp4")
    }

    func testTheNameUsesTheGregorianDateWhateverTheUsersCalendar() throws {
        let name = destinationURL(for: try Options.parse(["--display", "0"]), now: noon).lastPathComponent
        // 1_800_000_000 is 15 January 2027, 08:00 UTC: the same day everywhere but at the date line.
        XCTAssertTrue(name.hasPrefix("Recording-202701"), name)
        XCTAssertNotNil(name.range(of: #"^Recording-\d{8}-\d{6}\.mp4$"#, options: .regularExpression), name)
    }

    func testWithoutEitherTheCurrentDirectoryIsUsed() throws {
        let url = destinationURL(for: try Options.parse(["--display", "0"]), now: noon)
        XCTAssertEqual(url.deletingLastPathComponent().path, FileManager.default.currentDirectoryPath)
    }
}
