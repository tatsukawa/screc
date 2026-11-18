import XCTest

@testable import ScrecKit

final class OutputFileTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Starts an output and puts a "recording" into its staging directory, as the writer would.
    func record(to name: String, contents: String = "video") throws -> OutputFile {
        let output = try OutputFile(destination: file(name))
        try Data(contents.utf8).write(to: output.recording)
        return output
    }

    func testAnExistingFileIsRefused() throws {
        try Data("old".utf8).write(to: file("taken.mp4"))
        XCTAssertThrowsError(try OutputFile(destination: file("taken.mp4")))
    }

    func testADanglingSymbolicLinkIsRefusedRatherThanFollowed() throws {
        try FileManager.default.createSymbolicLink(at: file("link.mp4"), withDestinationURL: file("elsewhere.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("link.mp4").path), "fileExists follows the link")
        XCTAssertThrowsError(try OutputFile(destination: file("link.mp4")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("elsewhere.txt").path), "nothing may be written through the link")
    }

    func testNothingAppearsUnderTheFinalNameUntilPublished() throws {
        let output = try record(to: "clip.mp4")
        XCTAssertFalse(OutputFile.entryExists(at: file("clip.mp4").path))
        XCTAssertNotEqual(output.staging.deletingLastPathComponent(), directory, "staging is not in the destination directory")
    }

    func testPublishingMovesTheRecordingAndMakesItPrivate() throws {
        let output = try record(to: "clip.mp4")
        let saved = try output.publish()
        XCTAssertEqual(saved, file("clip.mp4"))
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "video")
        let permissions = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.staging.path), "the staging directory is removed")
    }

    func testAFileThatAppearedWhileRecordingIsNotReplaced() throws {
        let output = try record(to: "clip.mp4", contents: "new")
        try Data("someone else's".utf8).write(to: file("clip.mp4"))
        let saved = try output.publish()
        XCTAssertEqual(saved, file("clip-2.mp4"))
        XCTAssertEqual(try String(contentsOf: file("clip.mp4"), encoding: .utf8), "someone else's")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "new")
    }

    func testDiscardingOnlyRemovesTheStagingDirectory() throws {
        try Data("keep".utf8).write(to: file("neighbour.mp4"))
        let output = try record(to: "clip.mp4")
        output.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file("neighbour.mp4").path))
        XCTAssertFalse(OutputFile.entryExists(at: file("clip.mp4").path))
    }
}

final class PrintableTests: XCTestCase {
    func testControlCharactersFromOtherProgramsAreNeutralised() {
        XCTAssertEqual(printable("Safari — Apple"), "Safari — Apple")
        XCTAssertEqual(printable("evil\u{1B}[2J\ntitle"), "evil?[2J?title")  // escape sequence and line break
        XCTAssertEqual(printable("abc\u{202E}def"), "abc?def")  // right-to-left override
    }
}
