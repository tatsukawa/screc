import XCTest

@testable import ScrecMedia

final class AudioMixTests: XCTestCase {
    func testAppendFailureSurvivesAnotherTrackFinishing() async {
        do {
            try await withCheckedThrowingContinuation { continuation in
                let completion = PumpCompletion(count: 2, done: continuation)
                completion.trackFinished()
                XCTAssertFalse(completion.isFinished)
                completion.failed()
                XCTAssertTrue(completion.isFinished)
                completion.trackFinished()
            }
            XCTFail("the mix must fail if a track could not be copied")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
    }
}

final class MovieWriterTests: XCTestCase {
    func testStoppingBeforeTheFirstFrameSaysThatNothingWasRecorded() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screc-tests-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let movie = try MovieWriter(
            url: url, settings: MovieSettings(width: 640, height: 360, videoBitrate: 1_000_000, frameRate: 30, hevc: false, microphone: false))
        do {
            try await movie.finish()
            XCTFail("there is nothing to save")
        } catch {
            XCTAssertEqual(error as? MovieWriterError, .noFrames)
        }
    }
}
