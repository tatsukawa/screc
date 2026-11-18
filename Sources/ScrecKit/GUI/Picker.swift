import AppKit

/// Lets the user choose what to record, on screen, and reports the choice as an `Options` value.
///
/// It covers every display with a dimming overlay (`OverlayView`) and floats a `PickerToolbar` above one of them.
/// The geometry of the selection lives in `PickerModel`; this class connects the model to the views.
@MainActor
final class Picker {
    /// Keeps the picker alive while it is on screen.
    static var current: Picker?

    var model: PickerModel
    /// Called with the finished choice, after the picker has closed itself.
    var onPick: (Options) -> Void = { _ in }
    let toolbar: PickerToolbar
    private(set) var overlays: [OverlayView] = []

    private let options: Options
    private let microphones: [PickMicrophone]
    private var microphone: PickMicrophone?  // `nil` means no microphone.
    private var quality: Quality
    private var keyMonitor: Any?

    init(options: Options, displays: [PickDisplay], windows: [PickWindow], microphones: [PickMicrophone], pointer: CGPoint) {
        self.options = options
        self.microphones = microphones
        model = PickerModel(displays: displays, windows: windows, pointer: pointer)
        quality = options.quality
        microphone = options.mic ? microphones.first { $0.id == options.micDevice } : nil
        toolbar = PickerToolbar(mode: model.mode, microphones: microphones)

        toolbar.onCancel = { exit(0) }
        toolbar.onStart = { [unowned self] in start() }
        toolbar.onModeChange = { [unowned self] in
            model.mode = $0
            refresh()
        }
        toolbar.onMicrophoneChange = { [unowned self] in
            microphone = $0
            refresh()
        }
        toolbar.onQualityChange = { [unowned self] in
            quality = $0
            refresh()
        }
    }

    // MARK: Showing

    /// Creates one overlay window per display, with the toolbar on the display the pointer is on.
    func makeOverlays() {
        overlays = model.displays.map { display in
            let view = OverlayView(picker: self, display: display)
            let window = OverlayWindow(contentRect: display.screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(display.screenFrame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // Set explicitly: otherwise clicks on the transparent parts (inside the selection) fall through to the
            // windows below, and the selection could not be grabbed.
            window.ignoresMouseEvents = false
            // Above the menu bar and Dock, but below pop-up menus so the options menu is not hidden behind it.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.disableCursorRects()  // OverlayView sets the cursor itself.
            return view
        }
        let host = overlays.first { $0.display.frame.contains(model.pointer) } ?? overlays[0]
        toolbar.install(in: host)
        refresh()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for view in overlays { view.window?.orderFrontRegardless() }
        toolbar.window?.makeKey()
        // Enter and Esc are caught for the whole app, so they work whichever display's overlay is in front.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 36, 76:  // Return, Enter
                MainActor.assumeIsolated { self?.start() }
                return nil
            case 53:  // Esc
                exit(0)
            default:
                return event
            }
        }
    }

    // MARK: Updating

    /// Brings every view in line with the model: the overlays, the summary line, the options menu.
    func refresh() {
        var parts = [["Display", "Window", "Region"][model.mode.rawValue]]
        if let selection = model.selection {
            var estimated = options
            estimated.quality = quality
            let plan = VideoPlan(points: selection.size, pixelScale: selection.display.scale, options: estimated)
            parts.append("\(plan.width) × \(plan.height)")
            parts.append("up to about \(formatBytes(plan.bytesPerHour)) per hour")
        }
        parts.append(quality.title)
        parts.append(microphone.map { "Microphone: \($0.name)" + ($0.bluetooth ? " (what you hear drops to call quality)" : "") } ?? "No microphone")

        toolbar.update(
            caption: parts.joined(separator: "  ·  "),
            canRecord: model.mode == .display || (model.mode == .region && model.region != nil),
            microphone: microphone,
            quality: quality)
        for view in overlays { view.needsDisplay = true }
    }

    // MARK: Finishing

    /// Closes the picker and hands the choice on. Does nothing while there is no selection.
    func start() {
        guard let selection = model.selection else { return }
        var picked = options
        picked.select(selection.target)
        picked.mic = microphone != nil
        picked.micDevice = microphone?.id
        picked.quality = quality
        // Stop listening for keys, so Enter and Esc are not caught while the recording runs.
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for view in overlays { view.window?.orderOut(nil) }
        NSCursor.arrow.set()
        onPick(picked)
    }
}
