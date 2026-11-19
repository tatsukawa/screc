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
