import AppKit
import XCTest

@testable import ScrecKit

/// Tests the picker's views and how they are wired to the model. No window is ever shown on screen.
@MainActor
final class PickerUITests: XCTestCase {
    let size = CGSize(width: 1800, height: 1169)
    let microphones = [
        PickMicrophone(id: "builtin", name: "MacBook Pro Microphone", bluetooth: false),
        PickMicrophone(id: "buds", name: "Bluetooth Headset", bluetooth: true),
    ]

    func makePicker(options: Options = Options()) -> Picker {
        prepareAppKit()
        let frame = CGRect(origin: .zero, size: size)
        let picker = Picker(
            options: options,
            displays: [PickDisplay(index: 0, frame: frame, screenFrame: frame, scale: 2)],
            windows: [PickWindow(id: 11, frame: CGRect(x: 200, y: 150, width: 700, height: 450))],
            microphones: microphones,
            pointer: CGPoint(x: 400, y: 300))
        picker.makeOverlays()
        picker.overlays[0].layoutSubtreeIfNeeded()
        return picker
    }

    /// Records what the picker hands on.
    func picks(from picker: Picker) -> PickLog {
        let log = PickLog()
        picker.onPick = { log.options.append($0) }
        return log
    }

    final class PickLog {
        var options: [Options] = []
    }

    func menuItem(_ title: String, in picker: Picker) throws -> NSMenuItem {
        let button = try XCTUnwrap(subviews(of: NSPopUpButton.self, in: picker.toolbar).first)
        return try XCTUnwrap(button.menu?.items.first { $0.title == title }, "no menu item \(title)")
    }

    func choose(_ title: String, in picker: Picker) throws {
        let item = try menuItem(title, in: picker)
        _ = NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
    }

    func summary(of picker: Picker) -> String {
        subviews(of: NSTextField.self, in: picker.toolbar).map(\.stringValue).joined()
    }

    func button(titled title: String, in picker: Picker) throws -> NSButton {
        try XCTUnwrap(subviews(of: NSButton.self, in: picker.toolbar).first { $0.attributedTitle.string == title })
    }

    func selectMode(_ mode: PickMode, in picker: Picker) throws {
        let control = try XCTUnwrap(subviews(of: NSSegmentedControl.self, in: picker.toolbar).first)
        control.selectedSegment = mode.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
    }

    // MARK: Tests

    func testClickingInDisplayModeStartsTheRecording() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        picker.overlays[0].click(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(log.options.count, 1)
        XCTAssertEqual(log.options.first?.display, 0)
        XCTAssertNil(log.options.first?.window)
        XCTAssertNil(log.options.first?.region)
    }

    func testClickingAWindowRecordsThatWindowOnly() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        try selectMode(.window, in: picker)
        picker.overlays[0].click(at: CGPoint(x: 1500, y: 900))  // not on the window
        XCTAssertTrue(log.options.isEmpty)
        picker.overlays[0].click(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(log.options.first?.window, "11")
    }

    func testARegionIsRecordedOnceDrawn() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        try selectMode(.region, in: picker)
        picker.start()
        XCTAssertTrue(log.options.isEmpty, "there is no region yet")
        XCTAssertFalse(try button(titled: "Record", in: picker).isEnabled)

        picker.overlays[0].drag(CGPoint(x: 300, y: 200), CGPoint(x: 900, y: 650))
        XCTAssertTrue(try button(titled: "Record", in: picker).isEnabled)
        picker.start()
        XCTAssertEqual(log.options.first?.region, CGRect(x: 300, y: 200, width: 600, height: 450))
    }

    func testOptionsMenuStartsWithTheCommandLineChoices() throws {
        var options = Options()
        options.mic = true
        options.micDevice = "builtin"
        options.quality = .low
        let picker = makePicker(options: options)
        XCTAssertEqual(try menuItem("MacBook Pro Microphone", in: picker).state, .on)
        XCTAssertEqual(try menuItem("None", in: picker).state, .off)
        XCTAssertEqual(try menuItem(Quality.low.title, in: picker).state, .on)
        XCTAssertEqual(try menuItem(Quality.medium.title, in: picker).state, .off)
    }

    func testChoosingAMicrophoneAndQualityInTheMenu() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        XCTAssertEqual(try menuItem("None", in: picker).state, .on)
        XCTAssertEqual(try menuItem(Quality.medium.title, in: picker).state, .on)

        try choose("MacBook Pro Microphone", in: picker)
        XCTAssertEqual(try menuItem("MacBook Pro Microphone", in: picker).state, .on)
        XCTAssertEqual(try menuItem("None", in: picker).state, .off)
        XCTAssertTrue(summary(of: picker).contains("MacBook"))
        picker.start()
        XCTAssertEqual(log.options.last?.mic, true)
        XCTAssertEqual(log.options.last?.micDevice, "builtin")

        try choose(Quality.high.title, in: picker)
        try choose("None", in: picker)
        picker.start()
        XCTAssertEqual(log.options.last?.mic, false)
        XCTAssertNil(log.options.last?.micDevice)
        XCTAssertEqual(log.options.last?.quality, .high)
    }

    func testTheSummaryWarnsAboutABluetoothMicrophone() throws {
        let picker = makePicker()
        try choose("MacBook Pro Microphone", in: picker)
        XCTAssertFalse(summary(of: picker).contains("call quality"))
        try choose("Bluetooth Headset", in: picker)
        XCTAssertTrue(summary(of: picker).contains("call quality"))
    }

    func testTheSummaryShowsTheOutputSizeForTheSelection() throws {
        let picker = makePicker()
        XCTAssertTrue(summary(of: picker).contains("3600 × 2338"))
        try selectMode(.window, in: picker)
        XCTAssertTrue(summary(of: picker).contains("1400 × 900"))
    }

    func testTheToolbarCanBeDraggedButNotOffTheDisplay() throws {
        let picker = makePicker()
        let overlay = picker.overlays[0]
        let start = picker.toolbar.frame
        let grab = CGPoint(x: start.minX + 6, y: start.maxY - 4)  // the padding of the toolbar, not a control

        overlay.drag(grab, CGPoint(x: grab.x + 100, y: grab.y - 50))
        overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(picker.toolbar.frame.origin, CGPoint(x: start.minX + 100, y: start.minY - 50))

        let moved = picker.toolbar.frame
        overlay.drag(CGPoint(x: moved.minX + 6, y: moved.maxY - 4), CGPoint(x: 6000, y: 6000))
        overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(picker.toolbar.frame.maxX, size.width)
        XCTAssertEqual(picker.toolbar.frame.maxY, size.height)
    }

    func testDraggingTheToolbarNeverStartsARecordingOrTouchesTheRegion() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        try selectMode(.region, in: picker)
        let overlay = picker.overlays[0]
        overlay.drag(CGPoint(x: 300, y: 200), CGPoint(x: 700, y: 500))
        let region = picker.model.region

        let bar = picker.toolbar.frame
        overlay.drag(CGPoint(x: bar.minX + 6, y: bar.maxY - 4), CGPoint(x: bar.minX + 106, y: bar.maxY - 54))
        overlay.click(at: CGPoint(x: bar.minX + 6, y: bar.maxY - 4))
        XCTAssertTrue(log.options.isEmpty)
        XCTAssertEqual(picker.model.region, region)
    }
}

@MainActor
final class RecordingIndicatorHeadlessTests: XCTestCase {
    func testStoppingIsIgnoredUntilTheRecordingHasStarted() {
        prepareAppKit()
        var stops = 0
        let indicator = RecordingIndicator { stops += 1 }
        XCTAssertEqual(indicator.phase, .starting)
        XCTAssertTrue(indicator.stopButton.isHidden)
        indicator.stopButton.sendAction(indicator.stopButton.action, to: indicator.stopButton.target)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(indicator.phase, .starting)
    }
}
