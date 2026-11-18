import CoreGraphics

// The picker's logic, kept free of AppKit views so it can be unit tested.
//
// All coordinates are points with the origin at the top left. That is the space ScreenCaptureKit and `--region` use,
// so a selection can be handed to the recorder without any conversion.

/// A display the user can pick.
struct PickDisplay: Equatable {
    /// The number `--display` takes.
    let index: Int
    /// The system's ID for the display, which stays the same when displays are connected or removed.
    let id: CGDirectDisplayID
    /// Position among all displays, in the shared top-left-origin space.
    let frame: CGRect
    /// The same display's frame in AppKit's bottom-left-origin space, for placing windows on it.
    let screenFrame: CGRect
    /// Backing scale factor (2 on Retina).
    let scale: CGFloat
}

struct PickWindow: Equatable {
    let id: CGWindowID
    let frame: CGRect
}

struct PickMicrophone: Equatable {
    let id: String
    let name: String
    let bluetooth: Bool
}

/// What the picker can hand to the recorder.
enum PickTarget: Equatable {
    case display(PickDisplay)
    case window(CGWindowID)
    /// `rect` is relative to the top-left corner of the display.
    case region(PickDisplay, CGRect)
}

extension Options {
    /// Replaces whatever was selected before with `target`. Displays and windows are named by ID, so the recorder
    /// either records exactly what was picked or reports that it has gone.
    mutating func select(_ target: PickTarget) {
        window = nil
        windowID = nil
        region = nil
        displayID = nil
        switch target {
        case .display(let picked):
            display = picked.index
            displayID = picked.id
        case .window(let id):
            windowID = id
        case .region(let picked, let rect):
            display = picked.index
            displayID = picked.id
            region = rect
        }
    }
}

enum PickMode: Int {
    case display, window, region
}

/// A region drawn on one display. `rect` is relative to the display's top-left corner.
struct PickRegion: Equatable {
    var display: Int
    var rect: CGRect
}

/// What would be recorded right now.
struct PickSelection: Equatable {
    let target: PickTarget
    /// The display it is on, which decides the pixel scale.
    let display: PickDisplay
    /// Its size in points.
    let size: CGSize
}

/// A drag in region mode.
enum RegionDrag {
    /// Moving the whole region. `start` is in shared coordinates, so the region can be carried onto another display.
    case move(start: CGRect, from: CGPoint)
    /// Dragging edges or corners. `h` and `v` say which edge moves on each axis: -1 for left/top, 1 for right/bottom,
    /// 0 for none. `start` is relative to the display being drawn on. Drawing a new region is a resize of an empty
    /// rectangle by its bottom-right corner.
    case resize(start: CGRect, h: Int, v: Int)
}

struct PickerModel {
    /// How close to a region's edge a click still grabs the edge.
    static let gripMargin: CGFloat = 8
    /// Regions smaller than this (in either direction) are discarded; they are accidental clicks.
    static let minimumRegionSize: CGFloat = 16

    var displays: [PickDisplay]
    /// Front-most first.
    var windows: [PickWindow]
    var mode = PickMode.display
    /// In shared coordinates.
    var pointer: CGPoint
    var region: PickRegion?

    init(displays: [PickDisplay], windows: [PickWindow], pointer: CGPoint) {
        self.displays = displays
        self.windows = windows
        self.pointer = pointer
    }

    var hoveredWindow: PickWindow? { windows.first { $0.frame.contains(pointer) } }
    var hoveredDisplay: PickDisplay? { displays.first { $0.frame.contains(pointer) } }

    /// The current selection, or `nil` while there is nothing to record yet.
    var selection: PickSelection? {
        switch mode {
        case .display:
            guard let display = hoveredDisplay else { return nil }
            return PickSelection(target: .display(display), display: display, size: display.frame.size)
        case .window:
            guard let window = hoveredWindow, let display = hoveredDisplay else { return nil }
            return PickSelection(target: .window(window.id), display: display, size: window.frame.size)
        case .region:
            guard let region, let display = displays.first(where: { $0.index == region.display }) else { return nil }
            return PickSelection(target: .region(display, region.rect), display: display, size: region.rect.size)
        }
    }

    /// The area to leave undimmed on `display`, relative to that display.
    func highlight(on display: PickDisplay) -> CGRect? {
        let global: CGRect?
        switch mode {
        case .display: global = hoveredDisplay?.index == display.index ? display.frame : nil
        case .window: global = hoveredWindow?.frame
        case .region: return region?.display == display.index ? region?.rect : nil
        }
        guard let rect = global?.intersection(display.frame), !rect.isEmpty else { return nil }
        return rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    /// A hint to show in the middle of the screen while nothing is selected yet.
    var hint: String? {
        switch mode {
        case .display: return nil
        case .window: return hoveredWindow == nil ? "Click the window to record" : nil
        case .region: return region == nil ? "Drag to select the area to record" : nil
        }
    }

    // MARK: Pointer and region dragging

    /// Records the pointer position, given relative to `display`.
    mutating func movePointer(to point: CGPoint, on display: PickDisplay) {
        pointer = CGPoint(x: point.x + display.frame.minX, y: point.y + display.frame.minY)
    }

    /// Which part of `rect` a click at `point` grabs: `(0, 0)` for the inside, otherwise the edge or corner as in
    /// `RegionDrag.resize`. `nil` when the point is not on the region.
    static func grip(at point: CGPoint, in rect: CGRect) -> (h: Int, v: Int)? {
        let margin = gripMargin
        guard rect.insetBy(dx: -margin, dy: -margin).contains(point) else { return nil }
        let h = abs(point.x - rect.minX) <= margin ? -1 : abs(point.x - rect.maxX) <= margin ? 1 : 0
        let v = abs(point.y - rect.minY) <= margin ? -1 : abs(point.y - rect.maxY) <= margin ? 1 : 0
        return (h, v)
    }

    /// Starts a drag at `point` on `display`: grabs the existing region by its body or an edge, or starts a new one.
    mutating func beginDrag(at point: CGPoint, on display: PickDisplay) -> RegionDrag {
        movePointer(to: point, on: display)
        if let region, region.display == display.index, let grip = Self.grip(at: point, in: region.rect) {
            if grip == (0, 0) {
                return .move(start: region.rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY), from: pointer)
            }
            return .resize(start: region.rect, h: grip.h, v: grip.v)
        }
        region = nil
        return .resize(start: CGRect(origin: point, size: .zero), h: 1, v: 1)
    }

    /// Continues a drag with the pointer now at `point` on `display`.
    mutating func continueDrag(_ drag: RegionDrag, to point: CGPoint, on display: PickDisplay) {
        movePointer(to: point, on: display)
        switch drag {
        case .move(let start, let from):
            // When the pointer enters another display the region follows it there. A recording covers one display only,
            // so the region always lies entirely on a single display and shrinks if the new one is smaller.
            guard let target = hoveredDisplay ?? displays.first(where: { $0.index == region?.display }) else { return }
            let frame = target.frame
            let size = CGSize(width: min(start.width, frame.width), height: min(start.height, frame.height))
            let x = min(max((start.minX + pointer.x - from.x).rounded(), frame.minX), frame.maxX - size.width)
            let y = min(max((start.minY + pointer.y - from.y).rounded(), frame.minY), frame.maxY - size.height)
            region = PickRegion(display: target.index, rect: CGRect(x: x - frame.minX, y: y - frame.minY, width: size.width, height: size.height))
        case .resize(let start, let h, let v):
            let x = [h < 0 ? point.x : start.minX, h > 0 ? point.x : start.maxX]
            let y = [v < 0 ? point.y : start.minY, v > 0 ? point.y : start.maxY]
            let bounds = CGRect(origin: .zero, size: display.frame.size)
            let rect = CGRect(x: x.min()!, y: y.min()!, width: abs(x[1] - x[0]), height: abs(y[1] - y[0])).integral.intersection(bounds)
            guard !rect.isNull else { return }
            region = PickRegion(display: display.index, rect: rect)
        }
    }

    /// Ends a drag. A region that came out too small was just a click, so it is dropped.
    mutating func endDrag() {
        if let rect = region?.rect, rect.width < Self.minimumRegionSize || rect.height < Self.minimumRegionSize { region = nil }
    }
}
