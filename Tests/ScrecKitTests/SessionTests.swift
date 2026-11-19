import AppKit
import XCTest

@testable import ScrecKit

/// The life of the GUI between recordings. Nothing is put on the screen and nothing is recorded: the session's picker
/// factory, presentation, recording and quitting are replaced.
@MainActor
final class SessionTests: XCTestCase {
    final class Log {
        var recorded: [Options] = []
        var quits = 0
        var pickersMade = 0
        var presentations = 0
    }

    func makeSession(staysOpen: Bool, log: Log) -> GUISession {
        prepareAppKit()
        let frame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let session = GUISession(
            options: Options(), staysOpen: staysOpen,
            makePicker: { options in
                log.pickersMade += 1
                return Picker(
                    options: options, displays: [PickDisplay(index: 0, id: 101, frame: frame, screenFrame: frame, scale: 2)],
                    windows: [], microphones: [], pointer: CGPoint(x: 400, y: 300))
            },
            recordPicked: { log.recorded.append($0) })
        session.present = { picker in
            log.presentations += 1
            if picker.overlays.isEmpty { picker.makeOverlays() }
        }
        session.quit = { log.quits += 1 }
        return session
    }

    /// Waits for the work the session hands to tasks: building a picker, recording.
    func settle(until condition: @escaping () -> Bool) async {
        var turns = 0
        while !condition() && turns < 200 {
            await Task.yield()
            turns += 1
        }
    }

    func openPicker(_ session: GUISession) async throws -> Picker {
        session.newRecording()
        await settle { session.picker != nil }
        return try XCTUnwrap(session.picker)
    }

    // MARK: Opened as an app

    func testAnAppStaysOpenAfterARecordingAndCanRecordAgain() async throws {
        let log = Log()
        let session = makeSession(staysOpen: true, log: log)
        let picker = try await openPicker(session)
        XCTAssertEqual(session.state, .choosing)

        picker.start()
        await settle { session.state == .idle }
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.quits, 0, "an app does not quit after a recording")
        XCTAssertNil(session.picker)
        XCTAssertTrue(picker.overlays.allSatisfy { $0.window?.isVisible != true }, "the old picker is gone")

        _ = try await openPicker(session)
        XCTAssertEqual(log.pickersMade, 2, "a fresh picker, for what is on screen now")
    }

    func testAnAppStaysOpenWhenThePickerIsCancelled() async throws {
        let log = Log()
        let session = makeSession(staysOpen: true, log: log)
        let picker = try await openPicker(session)
        picker.cancel()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(log.quits, 0)
        XCTAssertTrue(log.recorded.isEmpty)
        XCTAssertNil(Picker.current)
    }

    func testThereIsNeverASecondPicker() async throws {
        let log = Log()
        let session = makeSession(staysOpen: true, log: log)
        _ = try await openPicker(session)
        session.newRecording()  // the Dock icon clicked again, say
        session.newRecording()
        await settle { false }
        XCTAssertEqual(log.pickersMade, 1)
        XCTAssertEqual(log.presentations, 3)
        XCTAssertEqual(session.state, .choosing)
    }

    // MARK: Run from a terminal

    func testFromATerminalScrecQuitsAfterOneRecording() async throws {
        let log = Log()
        let session = makeSession(staysOpen: false, log: log)
        try await openPicker(session).start()
        await settle { log.quits > 0 }
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.quits, 1)
    }

    func testFromATerminalCancellingQuits() async throws {
        let log = Log()
        let session = makeSession(staysOpen: false, log: log)
        try await openPicker(session).cancel()
        XCTAssertEqual(log.quits, 1)
        XCTAssertTrue(log.recorded.isEmpty)
    }

    // MARK: Picker

    func testCancellingIsReportedOnceAndOnlyWhileChoosing() async throws {
        let log = Log()
        let session = makeSession(staysOpen: true, log: log)
        let picker = try await openPicker(session)
        var cancels = 0
        picker.onCancel = { cancels += 1 }
        picker.cancel()
        picker.cancel()
        XCTAssertEqual(cancels, 1)
        XCTAssertFalse(picker.isChoosing)
    }
}
