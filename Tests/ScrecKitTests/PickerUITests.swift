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

    func makePicker(options: Options = Options(), store: UserDefaults? = nil) -> Picker {
        prepareAppKit()
        let frame = CGRect(origin: .zero, size: size)
        let picker = Picker(
            options: options,
            displays: [PickDisplay(index: 0, id: 101, frame: frame, screenFrame: frame, scale: 2)],
            windows: [PickWindow(id: 11, frame: CGRect(x: 200, y: 150, width: 700, height: 450))],
            microphones: microphones,
            pointer: CGPoint(x: 400, y: 300),
            store: store)
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
        XCTAssertEqual(log.options.first?.displayID, 101)
        XCTAssertNil(log.options.first?.windowID)
        XCTAssertNil(log.options.first?.region)
    }

    func testClickingAWindowRecordsThatWindowOnly() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        try selectMode(.window, in: picker)
        picker.overlays[0].click(at: CGPoint(x: 1500, y: 900))  // not on the window
        XCTAssertTrue(log.options.isEmpty)
        picker.overlays[0].click(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(log.options.first?.windowID, 11)
        XCTAssertNil(log.options.first?.window)
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

    func testARegionGivenWithGUIIsSelectedAtStart() throws {
        let picker = makePicker(options: try Options.parse(["--gui", "--quality", "high", "--region", "100,50,640,360"]))
        let log = picks(from: picker)
        XCTAssertEqual(picker.model.mode, .region)
        XCTAssertTrue(try button(titled: "Record", in: picker).isEnabled)
        picker.start()
        XCTAssertEqual(log.options.first?.region, CGRect(x: 100, y: 50, width: 640, height: 360))
        XCTAssertEqual(log.options.first?.displayID, 101)
        XCTAssertEqual(log.options.first?.quality, .high)
    }

    func testTheOptionsMenuHoldsEverySetting() throws {
        let picker = makePicker()
        let titles = try XCTUnwrap(picker.toolbar.optionsMenu).items.filter { !$0.isSeparatorItem }.map(\.title)
        for title in [
            "Save to", "Movies", "Desktop", "Documents", "Other Location…", "Microphone", "None", "Quality", "Format", "H.264",
            "HEVC", "Frame Rate", "60 fps", "30 fps", "Show Mouse Pointer", "After Saving", "Show in Finder", "Open", "Do Nothing",
        ] {
            XCTAssertTrue(titles.contains(title), "missing \(title)")
        }
        XCTAssertFalse(titles.contains("Settings…"), "there is no separate Settings window")
    }

    func testTheMenuIsOnlyRebuiltWhenASettingChanges() throws {
        let defaults = TemporaryDefaults()
        let picker = makePicker(store: defaults.store)
        let menu = try XCTUnwrap(picker.toolbar.optionsMenu)
        picker.refresh()  // as on every mouse move
        picker.refresh()
        XCTAssertTrue(picker.toolbar.optionsMenu === menu)
        try choose("Desktop", in: picker)
        XCTAssertFalse(picker.toolbar.optionsMenu === menu)
        XCTAssertEqual(try menuItem("Desktop", in: picker).state, .on)
    }

    func testTheMenuStartsWithTheDefaults() throws {
        let picker = makePicker()
        for checked in ["Movies", "None", Quality.medium.title, "H.264", "60 fps", "Show Mouse Pointer", "Show in Finder"] {
            XCTAssertEqual(try menuItem(checked, in: picker).state, .on, checked)
        }
        for unchecked in ["Desktop", Quality.high.title, "HEVC", "30 fps", "Open"] {
            XCTAssertEqual(try menuItem(unchecked, in: picker).state, .off, unchecked)
        }
    }

    func testEveryMenuChoiceReachesTheRecording() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        for title in ["Desktop", "MacBook Pro Microphone", Quality.low.title, "HEVC", "30 fps", "Show Mouse Pointer"] {
            try choose(title, in: picker)
        }
        XCTAssertEqual(try menuItem("Show Mouse Pointer", in: picker).state, .off, "it toggles")
        picker.start()
        let picked = try XCTUnwrap(log.options.first)
        XCTAssertEqual(picked.outputDirectory, Preferences.SaveFolder.desktop.url)
        XCTAssertEqual(picked.micDevice, "builtin")
        XCTAssertTrue(picked.mic)
        XCTAssertEqual(picked.quality, .low)
        XCTAssertTrue(picked.hevc)
        XCTAssertEqual(picked.fps, 30)
        XCTAssertFalse(picked.showsCursor)
    }

    func testOtherLocationAsksForAFolderAndListsIt() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        let folder = URL(fileURLWithPath: "/tmp/screc recordings", isDirectory: true)
        picker.chooseFolder = { _ in folder }
        try choose("Other Location…", in: picker)
        XCTAssertEqual(try menuItem("screc recordings", in: picker).state, .on)
        XCTAssertEqual(try menuItem("Movies", in: picker).state, .off)
        XCTAssertTrue(summary(of: picker).contains("Saves to screc recordings"))
        picker.start()
        XCTAssertEqual(log.options.first?.outputDirectory, folder)
    }

    func testCancellingTheFolderDialogChangesNothing() throws {
        let picker = makePicker()
        picker.chooseFolder = { _ in nil }
        try choose("Other Location…", in: picker)
        XCTAssertEqual(try menuItem("Movies", in: picker).state, .on)
        XCTAssertTrue(picker.overlays.allSatisfy { $0.window?.isVisible == false })
    }

    func testChoicesAreRememberedForNextTime() throws {
        let defaults = TemporaryDefaults()
        let picker = makePicker(store: defaults.store)
        for title in ["Documents", "MacBook Pro Microphone", Quality.low.title, "HEVC", "30 fps", "Show Mouse Pointer", "Do Nothing"] {
            try choose(title, in: picker)
        }
        var expected = Preferences()
        expected.saveFolder = .documents
        expected.microphoneID = "builtin"
        expected.quality = .low
        expected.hevc = true
        expected.fps = 30
        expected.showsCursor = false
        expected.afterSaving = .nothing
        XCTAssertEqual(Preferences.load(from: defaults.store), expected)

        let next = makePicker(store: defaults.store)  // the next time screc opens
        XCTAssertEqual(next.settings, expected)
        XCTAssertEqual(try menuItem("Documents", in: next).state, .on)
    }

    func testChoosingOneSettingLeavesUnrelatedStoredValuesAlone() throws {
        let defaults = TemporaryDefaults()
        defaults.store.set("future-preset", forKey: "quality")
        let picker = makePicker(store: defaults.store)
        try choose("Desktop", in: picker)
        XCTAssertEqual(defaults.store.string(forKey: "saveFolder"), "desktop")
        XCTAssertEqual(defaults.store.string(forKey: "quality"), "future-preset")
        XCTAssertNil(defaults.store.object(forKey: "fps"))
        try choose(Quality.medium.title, in: picker)
        XCTAssertEqual(defaults.store.string(forKey: "quality"), Quality.medium.rawValue)
    }

    func testCommandLineOptionsAreShownButNotRemembered() throws {
        let defaults = TemporaryDefaults()
        let options = try Options.parse(["--gui", "--quality", "high", "--hevc", "--no-cursor"])
        let picker = makePicker(options: options, store: defaults.store)
        XCTAssertEqual(try menuItem(Quality.high.title, in: picker).state, .on)
        XCTAssertEqual(try menuItem("HEVC", in: picker).state, .on)
        XCTAssertEqual(try menuItem("Show Mouse Pointer", in: picker).state, .off)

        try choose("Desktop", in: picker)
        let stored = Preferences.load(from: defaults.store)
        XCTAssertEqual(stored.saveFolder, .desktop, "what was chosen is remembered")
        XCTAssertEqual(stored.quality, .medium, "what the command line said is not")
        XCTAssertFalse(stored.hevc)
        XCTAssertTrue(stored.showsCursor)
    }

    func testARememberedMicrophoneThatIsNotConnectedMeansNone() throws {
        let defaults = TemporaryDefaults()
        var stored = Preferences()
        stored.microphoneID = "usb-unplugged"
        stored.save(to: defaults.store)
        let picker = makePicker(store: defaults.store)
        let log = picks(from: picker)
        XCTAssertEqual(try menuItem("None", in: picker).state, .on)
        picker.start()
        XCTAssertEqual(log.options.first?.mic, false)
    }

    func testAnOutputFileFromTheCommandLineIsKept() throws {
        let picker = makePicker(options: try Options.parse(["--gui", "/tmp/clip.mp4"]))
        let log = picks(from: picker)
        XCTAssertFalse(summary(of: picker).contains("Saves to"))
        picker.start()
        XCTAssertEqual(log.options.first?.output?.path, "/tmp/clip.mp4")
        XCTAssertNil(log.options.first?.outputDirectory)
    }

    func testAPickerOnlyHandsOnOneChoice() throws {
        let picker = makePicker()
        let log = picks(from: picker)
        picker.start()
        picker.start()
        XCTAssertEqual(log.options.count, 1)
        XCTAssertFalse(picker.isChoosing)
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
        XCTAssertTrue(summary(of: picker).contains("estimated 5.8 GB per hour"))
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
    func testAStopPanelIsFreedWithItsRecording() {
        prepareAppKit()
        weak var weakIndicator: RecordingIndicator?
        weak var weakControl: Control?
        autoreleasepool {
            let control = Control()
            let indicator = makeIndicator(for: control)
            weakIndicator = indicator
            weakControl = control
            control.onStopping?()
            XCTAssertEqual(indicator.phase, .saving, "the recording reaches the panel")
            indicator.dismiss()
        }
        XCTAssertNil(weakIndicator, "the app records many times; stop panels must not pile up")
        XCTAssertNil(weakControl)
    }

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
