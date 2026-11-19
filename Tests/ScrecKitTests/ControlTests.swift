import XCTest

@testable import ScrecKit

final class ControlTests: XCTestCase {
    private enum Failure: Error { case interrupted }

    func testCancellingTheDurationTaskDoesNotRequestAStop() async {
        let control = Control()
        let timer = control.stop(after: .seconds(604_800))
        timer.cancel()
        await timer.value

        control.reportFailure(Failure.interrupted)
        var events = control.events.makeAsyncIterator()
        guard case .failed(Failure.interrupted)? = await events.next() else {
            return XCTFail("the cancelled timer sent a stop event")
        }
    }

    func testTheDurationTaskRequestsAStop() async {
        let control = Control()
        await control.stop(after: .zero).value
        control.reportFailure(Failure.interrupted)
        var events = control.events.makeAsyncIterator()
        guard case .stopRequested? = await events.next() else {
            return XCTFail("the duration timer did not send a stop event")
        }
    }
}
