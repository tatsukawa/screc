import AppKit

final class OverlayWindow: NSWindow {
    /// A borderless window cannot become key by default, and without that it receives no key events.
    override var canBecomeKey: Bool { true }
}

/// The dimming overlay on one display. It draws the highlight and turns mouse input into model changes.
final class OverlayView: NSView {
    private enum Drag {
        case region(RegionDrag)
        /// Dragging the toolbar by its padding.
        case toolbar(last: CGPoint)
    }

    /// Weak: a window can outlive the picker for a moment (it may still draw after the picker is gone), and the picker
    /// owns the overlays anyway. Every entry point does nothing once the picker has gone.
    private weak var picker: Picker?
    let display: PickDisplay
    private var drag: Drag?

    init(picker: Picker, display: PickDisplay) {
        self.picker = picker
        self.display = display
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // Top-left origin, like the model.

    /// Reacts to the very first click, even on an overlay that is not in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let picker else { return }
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        if let hole = picker.model.highlight(on: display) {
            NSColor.clear.setFill()
            hole.fill(using: .copy)
            drawHighlightFrame(around: hole)
        }
        if let hint = picker.model.hint { drawHint(hint) }
    }

    private func drawHighlightFrame(around hole: CGRect) {
        guard let picker else { return }
        let accent = NSColor.controlAccentColor
        func stroke(_ rect: CGRect, _ color: NSColor, width: CGFloat) {
            color.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
            path.lineWidth = width
            path.stroke()
        }
        switch picker.model.mode {
        case .display:
            stroke(hole, accent, width: 4)
        case .window:
            accent.withAlphaComponent(0.2).setFill()  // Tint the window that would be chosen, as ⌘⇧5 does.
            hole.fill(using: .sourceOver)
            stroke(hole, accent, width: 2)
        case .region:
            stroke(hole, .white, width: 1.5)
            // Handles on the corners and on the middle of each edge.
            for x in [hole.minX, hole.midX, hole.maxX] {
                for y in [hole.minY, hole.midY, hole.maxY] where !(x == hole.midX && y == hole.midY) {
                    let knob = NSBezierPath(ovalIn: CGRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9))
                    NSColor.white.setFill()
                    knob.fill()
                    NSColor.black.withAlphaComponent(0.5).setStroke()
                    knob.stroke()
                }
            }
        }
    }

    private func drawHint(_ hint: String) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 6
        let text = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .shadow: shadow,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard let picker else { return .arrow }
        guard picker.model.mode == .region, !isOnToolbar(point) else { return .arrow }
        guard let region = picker.model.region, region.display == display.index,
            let grip = PickerModel.grip(at: point, in: region.rect)
        else { return .crosshair }
        if grip == (0, 0) { return drag == nil ? .openHand : .closedHand }
        // The edges the handle is on, as the bit set the system's resize cursors are named by: top, left, bottom, right.
        let edges: UInt = (grip.v < 0 ? 1 : 0) | (grip.h < 0 ? 2 : 0) | (grip.v > 0 ? 4 : 0) | (grip.h > 0 ? 8 : 0)
        return NSCursor.FrameResizePosition(rawValue: edges).map { .frameResize(position: $0, directions: .all) } ?? .crosshair
    }

    // MARK: Mouse

    private func location(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func isOnToolbar(_ point: CGPoint) -> Bool {
        guard let picker else { return false }
        return picker.toolbar.superview === self && picker.toolbar.frame.contains(point)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let picker else { return }
        let point = location(of: event)
        picker.model.movePointer(to: point, on: display)
        cursor(at: point).set()
        picker.refresh()
    }

    override func mouseDown(with event: NSEvent) {
        guard let picker else { return }
        let point = location(of: event)
        if isOnToolbar(point) {  // The padding around the controls drags the toolbar.
            drag = .toolbar(last: point)
            return
        }
        guard picker.model.mode == .region else {
            picker.model.movePointer(to: point, on: display)
            picker.start()
            return
        }
        drag = .region(picker.model.beginDrag(at: point, on: display))
        cursor(at: point).set()
        picker.refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let picker else { return }
        let point = location(of: event)
        switch drag {
        case .toolbar(let last):
            picker.toolbar.move(dx: point.x - last.x, dy: point.y - last.y)
            drag = .toolbar(last: point)
        case .region(let regionDrag):
            picker.model.continueDrag(regionDrag, to: point, on: display)
            picker.refresh()
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let picker, let finished = drag else { return }
        drag = nil
        if case .region = finished {
            picker.model.endDrag()
            cursor(at: location(of: event)).set()
            picker.refresh()
        }
    }
}
