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

    /// Where the snapshot tests write their pictures, created if needed. Every snapshot test must create it: tests run in
    /// name order, so the first one to run is not always the same one.
    func snapshotDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["SCREC_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set SCREC_SNAPSHOT_DIR to write pictures of the UI.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Waits until the window server lists every one of `windows` as on screen. A fixed delay is not enough the first
    /// time a window is shown, when fonts and images are still loading.
    func waitUntilOnScreen(_ windows: [NSWindow], timeout: TimeInterval = 3) {
        let ids = Set(windows.map { CGWindowID($0.windowNumber) })
        let deadline = Date().addingTimeInterval(timeout)
        while !ids.isSubset(of: onScreenWindowIDs()) && Date() < deadline { spin(0.05) }
        spin(0.2)  // and let it draw
    }

    // MARK: Stop panel

    func testStopPanelIsOnScreenAndStopsExactlyOnce() throws {
        try requireOnScreenTests()
        prepareAppKit()
        var stops = 0
        let indicator = RecordingIndicator { stops += 1 }
        indicator.prepare()
        defer { indicator.panel.orderOut(nil) }
        waitUntilOnScreen([indicator.panel])

        XCTAssertGreaterThan(indicator.windowID, 0)
        XCTAssertTrue(
            onScreenWindowIDs().contains(indicator.windowID),
            "the panel must be listed as an on-screen window, otherwise it cannot be excluded from the recording")
        XCTAssertTrue(indicator.panel.styleMask.contains(.nonactivatingPanel), "clicking it must not take focus from the recorded app")

        indicator.started()
        XCTAssertEqual(indicator.phase, .recording)
        XCTAssertFalse(indicator.stopButton.isHidden)
        let app = ScrecAppDelegate.shared
        XCTAssertEqual(app.applicationDockMenu(NSApp)?.items.map(\.title), ["Stop Recording"])

        // Quitting while recording stops and saves instead.
        XCTAssertEqual(app.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(indicator.phase, .saving)
        XCTAssertTrue(indicator.stopButton.isHidden)
        XCTAssertNil(app.applicationDockMenu(NSApp), "nothing to stop any more")
        XCTAssertEqual(app.applicationShouldTerminate(NSApp), .terminateCancel, "it quits by itself once saved")

        indicator.stopButton.performClick(nil)
        XCTAssertEqual(stops, 1, "a second click must not stop again")

        indicator.saved()
        XCTAssertEqual(indicator.phase, .saved)
        XCTAssertEqual(app.applicationShouldTerminate(NSApp), .terminateNow)
        RecordingIndicator.current = nil
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
        waitUntilOnScreen([backdrop, picker.overlays[0].window!])
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
        let directory = try snapshotDirectory()

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
        waitUntilOnScreen([indicator.panel, panelBackdrop])
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

    func testOptionsMenuSnapshot() throws {
        try requireOnScreenTests()
        let directory = try snapshotDirectory()
        let stage = makeStage(size: CGSize(width: 700, height: 360))
        defer { stage.close() }
        let menu = try XCTUnwrap(stage.picker.toolbar.optionsMenu)
        let path = "\(directory)/options-menu.png"
        var failure: Error?
        let deadline = Date().addingTimeInterval(3)
        // A menu runs its own event loop while it is open, so the picture is taken from a timer inside that loop, as
        // soon as the window server lists the menu's window (waiting a fixed time is not reliable on a first run).
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let menus = list.filter {
                    ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                        && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
                }
                guard !menus.isEmpty || Date() > deadline else { return }
                timer.invalidate()
                self.spin(0.3)  // let it finish drawing
                let ids = menus.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
                let bounds = menus.compactMap {
                    ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                }
                do {
                    guard !ids.isEmpty else { throw NSError(domain: "screc-tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "the menu never appeared"]) }
                    try self.writeSnapshot(ofScreenRect: bounds.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -20, dy: -20), windowIDs: ids, to: path)
                } catch { failure = error }
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Open it near the top of the screen, so that the whole menu fits below it.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        menu.popUp(positioning: nil, at: CGPoint(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.maxY - 30), in: nil)
        if let failure { throw failure }
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
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let rect = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        try writeSnapshot(ofScreenRect: rect, windowIDs: windows.map { CGWindowID($0.windowNumber) }, to: path)
    }

    /// The same, with the rectangle in screen coordinates (origin at the top left) and the windows given by ID.
    func writeSnapshot(ofScreenRect rect: CGRect, windowIDs: [CGWindowID], to path: String) throws {
        guard let createImage = windowImageFunction else {
            throw XCTSkip("CGWindowListCreateImageFromArray is not available on this system")
        }
        // A CFArray of window IDs stored as bare values, which is what the function expects. Front-most first.
        var ids = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
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
