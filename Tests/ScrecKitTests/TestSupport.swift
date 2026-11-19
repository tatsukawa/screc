import AppKit
import XCTest

@testable import ScrecKit

/// The on-screen tests show real windows, which would flash on the screen of whoever runs `swift test`,
/// so they only run when `SCREC_UI_TESTS=1` is set.
func requireOnScreenTests() throws {
    guard ProcessInfo.processInfo.environment["SCREC_UI_TESTS"] == "1" else {
        throw XCTSkip("Shows windows on screen. Run with SCREC_UI_TESTS=1 to include it.")
    }
}

/// Lets the tests create windows and views without a running application.
@MainActor
func prepareAppKit() {
    NSApplication.shared.setActivationPolicy(.accessory)
}

/// All views of type `T` below `root`.
@MainActor
func subviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    root.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + subviews(of: type, in: $0) }
}

/// A mouse event at `point`, given in the top-left-origin coordinates of `view`, which must fill its window.
@MainActor
func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) -> NSEvent {
    NSEvent.mouseEvent(
        with: type, location: CGPoint(x: point.x, y: view.bounds.height - point.y), modifierFlags: [], timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

extension OverlayView {
    /// Presses, drags and releases the mouse.
    func drag(_ points: CGPoint...) {
        mouseDown(with: mouseEvent(.leftMouseDown, at: points[0], in: self))
        for point in points.dropFirst() { mouseDragged(with: mouseEvent(.leftMouseDragged, at: point, in: self)) }
        mouseUp(with: mouseEvent(.leftMouseUp, at: points.last!, in: self))
    }

    func click(at point: CGPoint) { drag(point) }
}

extension Preferences {
    /// Seeds a complete set of preferences in a test's temporary defaults domain.
    func save(to defaults: UserDefaults) {
        for setting in Setting.allCases { save(setting, to: defaults) }
    }
}
