import AppKit
import XCTest

@testable import ScrecKit

/// The life of the GUI between recordings. Nothing is put on the screen and nothing is recorded: the session's picker
/// factory, presentation, recording and quitting are replaced.
@MainActor
final class SessionTests: XCTestCase {
    final class Log {
        var recorded: [Options] = []
        /// The exit status of each quit.
        var quits: [Int32] = []
        var reported: [String] = []
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
        session.quit = { log.quits.append($0) }
        session.report = { log.reported.append("\($0)") }
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
        XCTAssertEqual(session.state, .recording)
        XCTAssertNil(session.picker)
        session.newRecording()
        XCTAssertEqual(log.presentations, 1, "reopening must not show the old picker")
        await settle { session.state == .idle }
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.quits, [], "an app does not quit after a recording")
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
        XCTAssertEqual(log.quits, [])
        XCTAssertTrue(log.recorded.isEmpty)
        XCTAssertNil(session.picker)
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

    // MARK: Failures

    func testAnAppStaysOpenWhenARecordingFails() async throws {
        let log = Log()
        let session = makeSession(staysOpen: true, log: log)
        session.recordPicked = { _ in throw ScrecError("the window you picked is no longer on screen") }
        try await openPicker(session).start()
        await settle { session.state == .idle }
        XCTAssertEqual(log.reported, ["the window you picked is no longer on screen"])
        XCTAssertEqual(log.quits, [], "a failed recording must not quit the app")

        _ = try await openPicker(session)
        XCTAssertEqual(session.state, .choosing, "and it can record again")
    }

    func testAnAppStaysOpenWhenThePickerCannotBeMade() async throws {
        let log = Log()
        let session = makeSession(staysOpen: true, log: log)
        let makePicker = session.makePicker
        session.makePicker = { _ in throw ScrecError("screen recording is not permitted") }
        session.newRecording()
        await settle { session.state == .idle }
        XCTAssertEqual(log.reported, ["screen recording is not permitted"])
        XCTAssertEqual(log.quits, [])

        session.makePicker = makePicker
        _ = try await openPicker(session)
        XCTAssertEqual(session.state, .choosing)
    }

    func testFromATerminalAFailedRecordingQuitsWithAnError() async throws {
        let log = Log()
        let session = makeSession(staysOpen: false, log: log)
        session.recordPicked = { _ in throw ScrecError("the folder /gone does not exist") }
        try await openPicker(session).start()
        await settle { !log.quits.isEmpty }
        XCTAssertEqual(log.quits, [1])
        XCTAssertEqual(log.reported.count, 1)
    }

    func testStoppingBeforeTheFirstFrameIsNotAFailure() async throws {
        let log = Log()
        let session = makeSession(staysOpen: false, log: log)
        session.recordPicked = { _ in throw ScrecError.nothingRecorded }
        try await openPicker(session).start()
        await settle { !log.quits.isEmpty }
        XCTAssertEqual(log.quits, [0])
    }

    // MARK: Quitting while recording

    func testQuittingWhileRecordingSavesFirstAndThenQuits() async throws {
        final class Recording {
            var stops = 0
            var indicator: RecordingIndicator?
            var finish: CheckedContinuation<Void, Never>?
            var replies: [Bool] = []
        }
        let log = Log()
        let recording = Recording()
        let session = makeSession(staysOpen: true, log: log)
        session.recordPicked = { _ in
            // Stands for recordAndReveal, without putting the stop panel on the screen.
            let indicator = RecordingIndicator { recording.stops += 1 }
            RecordingIndicator.current = indicator
            recording.indicator = indicator
            defer { RecordingIndicator.current = nil }
            await withCheckedContinuation { recording.finish = $0 }
            indicator.saved()
        }
        GUISession.shared = session
        defer { GUISession.shared = nil }
        let delegate = ScrecAppDelegate()
        delegate.replyToTerminate = { recording.replies.append($0) }

        try await openPicker(session).start()
        await settle { recording.finish != nil }
        // Still starting up: the stop is queued, so that the recording ends as soon as it begins.
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertEqual(recording.stops, 1, "one stop, however often quit is chosen")
        XCTAssertEqual(recording.indicator?.phase, .saving)
        recording.indicator?.started()
        XCTAssertEqual(recording.indicator?.phase, .saving, "a stopped indicator does not start again")
        XCTAssertEqual(recording.replies, [], "not before the recording is saved")

        recording.finish?.resume()
        await settle { !recording.replies.isEmpty }
        XCTAssertEqual(recording.replies, [true], "quits once saved")
        XCTAssertEqual(session.state, .idle)
    }

    func testQuittingWhileWaitingQuitsAtOnce() async throws {
        let log = Log()
        let session = makeSession(staysOpen: true, log: log)
        GUISession.shared = session
        defer { GUISession.shared = nil }
        XCTAssertEqual(ScrecAppDelegate().applicationShouldTerminate(NSApp), .terminateNow)
        _ = try await openPicker(session)
        XCTAssertEqual(ScrecAppDelegate().applicationShouldTerminate(NSApp), .terminateNow)
    }

    // MARK: Run from a terminal

    func testFromATerminalScrecQuitsAfterOneRecording() async throws {
        let log = Log()
        let session = makeSession(staysOpen: false, log: log)
        try await openPicker(session).start()
        await settle { !log.quits.isEmpty }
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.quits, [0])
    }

    func testFromATerminalCancellingQuits() async throws {
        let log = Log()
        let session = makeSession(staysOpen: false, log: log)
        try await openPicker(session).cancel()
        XCTAssertEqual(log.quits, [0])
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
