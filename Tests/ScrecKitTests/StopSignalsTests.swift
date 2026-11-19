import Darwin
import XCTest

@testable import ScrecKit

final class StopSignalsTests: XCTestCase {
    private enum Marker: Error { case published }

    func testSignalsQueuedDuringPublicationCannotStopOrDiscardTheSavedFile() async {
        // Use a signal that the recorder does not normally handle or send outside this test process.
        let previous = signal(SIGUSR1, SIG_IGN)
        defer { signal(SIGUSR1, previous) }
        let control = Control()
        let abort = expectation(description: "abort after publishing")
        abort.isInverted = true
        let signals = StopSignals(control: control, numbers: [SIGUSR1]) { abort.fulfill() }
        let published = signals.finish {
            XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
            XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
            return true
        }
        XCTAssertTrue(published)
        await fulfillment(of: [abort], timeout: 0.1)
        control.reportFailure(Marker.published)
        var events = control.events.makeAsyncIterator()
        guard case .failed(Marker.published)? = await events.next() else {
            return XCTFail("a signal reached the old recording control")
        }
    }
}
