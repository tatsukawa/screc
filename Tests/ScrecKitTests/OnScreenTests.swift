import AppKit
import XCTest

@testable import ScrecKit

/// Tests that need windows on a real screen, because they ask the window server about them. Run them with
/// `SCREC_UI_TESTS=1 swift test`. Windows appear on screen for a moment while they run.
///
/// Set `SCREC_SNAPSHOT_DIR` as well to get pictures of the picker and the stop panel as they really render.
@MainActor
final class OnScreenTests: XCTestCase {
    /// The IDs of all windows the window server lists as on screen.
    func onScreenWindowIDs() -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Stop panel

    func testStopPanelIsOnScreenAndStopsExactlyOnce() throws {
        try requireOnScreenTests()
        prepareAppKit()
        var stops = 0
        let indicator = RecordingIndicator { stops += 1 }
        indicator.prepare()
        defer { indicator.panel.orderOut(nil) }
        spin()

        XCTAssertGreaterThan(indicator.windowID, 0)
        XCTAssertTrue(
            onScreenWindowIDs().contains(indicator.windowID),
            "the panel must be listed as an on-screen window, otherwise it cannot be excluded from the recording")
        XCTAssertTrue(indicator.panel.styleMask.contains(.nonactivatingPanel), "clicking it must not take focus from the recorded app")

        indicator.started()
        XCTAssertEqual(indicator.phase, .recording)
        XCTAssertFalse(indicator.stopButton.isHidden)

        indicator.stopButton.performClick(nil)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(indicator.phase, .saving)
        XCTAssertTrue(indicator.stopButton.isHidden)

        indicator.stopButton.performClick(nil)
        XCTAssertEqual(stops, 1, "a second click must not stop again")

        indicator.saved()
        XCTAssertEqual(indicator.phase, .saved)
    }

    func testStopPanelSitsBelowTheMenuBarAtTheTopOfTheScreen() throws {
        try requireOnScreenTests()
        prepareAppKit()
        let indicator = RecordingIndicator {}
        indicator.prepare()
        defer { indicator.panel.orderOut(nil) }
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.intersects(indicator.panel.frame) })
        XCTAssertLessThanOrEqual(indicator.panel.frame.maxY, screen.visibleFrame.maxY)
        XCTAssertGreaterThan(indicator.panel.frame.minY, screen.visibleFrame.maxY - 100)
        XCTAssertEqual(indicator.panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
    }

    // MARK: Picker overlay

    /// A picker on a small piece of the real screen, with a plain window behind it that stands for "the apps below".
    @MainActor
    struct Stage {
        let picker: Picker
        let frame: CGRect  // in AppKit coordinates
        let backdrop: NSWindow

        var overlayWindow: NSWindow { picker.overlays[0].window! }

        func close() {
            overlayWindow.orderOut(nil)
            backdrop.orderOut(nil)
        }
    }

    func makeStage(windows: [PickWindow] = [], size: CGSize = CGSize(width: 700, height: 360)) -> Stage {
        prepareAppKit()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = CGRect(x: screen.frame.maxX - size.width - 20, y: screen.frame.minY + 90, width: size.width, height: size.height)
        let display = PickDisplay(index: 0, id: 101, frame: CGRect(origin: .zero, size: size), screenFrame: frame, scale: 2)
        let picker = Picker(options: Options(), displays: [display], windows: windows, microphones: [], pointer: CGPoint(x: 100, y: 100))
        picker.makeOverlays()

        let backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = .systemTeal
        backdrop.isReleasedWhenClosed = false
        backdrop.level = NSWindow.Level(rawValue: picker.overlays[0].window!.level.rawValue - 1)
        backdrop.orderFrontRegardless()
        picker.overlays[0].window?.orderFrontRegardless()
        spin()
        return Stage(picker: picker, frame: frame, backdrop: backdrop)
    }

    /// The number of the window the window server would send a click at `point` (top-left based, within the stage) to.
    func windowReceivingClick(at point: CGPoint, on stage: Stage) -> Int {
        NSWindow.windowNumber(at: CGPoint(x: stage.frame.minX + point.x, y: stage.frame.maxY - point.y), belowWindowWithWindowNumber: 0)
    }

    /// Regression test: the inside of the selection is transparent, and clicks there used to fall through to the
    /// windows below, which made it impossible to grab the selection and move it.
    func testClicksInsideTheTransparentSelectionReachTheOverlay() throws {
        try requireOnScreenTests()
        let stage = makeStage()
        defer { stage.close() }
        let overlay = stage.overlayWindow.windowNumber

        stage.picker.model.mode = .region
        stage.picker.model.region = PickRegion(display: 0, rect: CGRect(x: 100, y: 60, width: 250, height: 120))
        stage.picker.refresh()
        spin()
        XCTAssertEqual(windowReceivingClick(at: CGPoint(x: 650, y: 20), on: stage), overlay, "dimmed area")
        XCTAssertEqual(windowReceivingClick(at: CGPoint(x: 200, y: 100), on: stage), overlay, "inside the selection")

        stage.picker.model.mode = .display  // here the whole display is the selection
        stage.picker.refresh()
        spin()
        XCTAssertEqual(windowReceivingClick(at: CGPoint(x: 200, y: 100), on: stage), overlay, "inside the highlighted display")
    }

    // MARK: Pictures

    func testSnapshots() throws {
        try requireOnScreenTests()
        guard let directory = ProcessInfo.processInfo.environment["SCREC_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set SCREC_SNAPSHOT_DIR to write pictures of the UI.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // The picker, in each mode, over a colourful backdrop so that the glass has something to refract.
        let stage = makeStage(windows: [PickWindow(id: 1, frame: CGRect(x: 60, y: 30, width: 420, height: 200))], size: CGSize(width: 900, height: 420))
        defer { stage.close() }
        stage.backdrop.contentView = NSImageView(image: backdropImage(size: stage.frame.size))
        let overlay = stage.picker.overlays[0]

        func shoot(_ name: String) throws {
            spin(0.45)
            try writeSnapshot(of: stage.frame, windows: [stage.overlayWindow, stage.backdrop], to: "\(directory)/\(name).png")
        }
        overlay.mouseMoved(with: mouseEvent(.mouseMoved, at: CGPoint(x: 100, y: 100), in: overlay))
        try shoot("picker-display")
        stage.picker.model.mode = .window
        overlay.mouseMoved(with: mouseEvent(.mouseMoved, at: CGPoint(x: 200, y: 100), in: overlay))
        try shoot("picker-window")
        stage.picker.model.mode = .region
        stage.picker.refresh()
        try shoot("picker-region-empty")
        overlay.drag(CGPoint(x: 540, y: 40), CGPoint(x: 850, y: 250))
        try shoot("picker-region")

        // The stop panel, while recording, while saving and when saved.
        var panelFrame = CGRect.zero
        let indicator = RecordingIndicator {}
        indicator.prepare()
        panelFrame = indicator.panel.frame.insetBy(dx: -40, dy: -30)
        let panelBackdrop = NSWindow(contentRect: panelFrame, styleMask: .borderless, backing: .buffered, defer: false)
        panelBackdrop.contentView = NSImageView(image: backdropImage(size: panelFrame.size))
        panelBackdrop.isReleasedWhenClosed = false
        panelBackdrop.level = .floating  // below the panel's .statusBar
        panelBackdrop.orderFrontRegardless()
        defer {
            indicator.panel.orderOut(nil)
            panelBackdrop.orderOut(nil)
        }
        indicator.started()
        spin(1.3)  // let the clock show 0:01
        let panelWindows = [indicator.panel, panelBackdrop]
        try writeSnapshot(of: panelFrame, windows: panelWindows, to: "\(directory)/panel-recording.png")
        indicator.stopButton.performClick(nil)
        spin(0.3)
        try writeSnapshot(of: panelFrame, windows: panelWindows, to: "\(directory)/panel-saving.png")
        indicator.saved()
        spin(0.3)
        try writeSnapshot(of: panelFrame, windows: panelWindows, to: "\(directory)/panel-saved.png")
    }

    /// A gradient with a white card and a dark card, standing in for windows of other apps.
    func backdropImage(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemIndigo, .systemPink])!.draw(in: rect, angle: 30)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: 60, y: rect.height - 230, width: 420, height: 200), xRadius: 10, yRadius: 10).fill()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: CGRect(x: 520, y: 40, width: 340, height: rect.height - 80)).fill()
            return true
        }
    }

    /// Writes a picture of `windows`, composited as they are on screen, cropped to `frame` (AppKit coordinates).
    /// Only the given windows, all of them this test's own, are captured: nothing else on the screen can end up in the
    /// picture, and no screen recording permission is needed.
    func writeSnapshot(of frame: CGRect, windows: [NSWindow], to path: String) throws {
        guard let createImage = windowImageFunction else {
            throw XCTSkip("CGWindowListCreateImageFromArray is not available on this system")
        }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let rect = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        // A CFArray of window IDs stored as bare values, which is what the function expects. Front-most first.
        var ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = try XCTUnwrap(CFArrayCreate(nil, &ids, ids.count, nil))
        let image = try XCTUnwrap(createImage(rect, array, 8)?.takeRetainedValue(), "could not capture \(path)")  // 8: best resolution
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}

/// `CGWindowListCreateImageFromArray` is marked unavailable in the current SDK, which wants ScreenCaptureKit and its
/// permission prompt instead; capturing this process's own windows needs neither. It is looked up at run time, so that
/// the tests still build and run if a future macOS removes it: the snapshot test is then skipped.
private typealias WindowImageFunction = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
private let windowImageFunction: WindowImageFunction? = {
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let symbol = dlsym(defaultHandle, "CGWindowListCreateImageFromArray") else { return nil }
    return unsafeBitCast(symbol, to: WindowImageFunction.self)
}()
