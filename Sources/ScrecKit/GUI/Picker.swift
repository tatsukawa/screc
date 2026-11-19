import AppKit

/// Lets the user choose what to record, on screen, and reports the choice as an `Options` value.
///
/// It covers every display with a dimming overlay (`OverlayView`) and floats a `PickerToolbar` above one of them.
/// The geometry of the selection lives in `PickerModel`; this class connects the model to the views.
@MainActor
final class Picker {
    var model: PickerModel
    /// Called with the finished choice, after the picker has closed itself.
    var onPick: (Options) -> Void = { _ in }
    /// Called when the user cancels (✕ or Esc), after the picker has closed itself.
    var onCancel: () -> Void = {}
    let toolbar: PickerToolbar
    private(set) var overlays: [OverlayView] = []

    /// What the command line said. It also carries what the menu does not cover: an output file, bitrate, duration…
    private let options: Options
    /// The settings shown in the Options menu: the stored ones, overridden by the command line, then by the menu.
    private(set) var settings: Preferences
    private let microphones: [PickMicrophone]
    private var keyMonitor: Any?
    /// Where choices made in the Options menu are remembered for next time; `nil` to remember nothing (tests).
    private let store: UserDefaults?
    /// Whether the picker is still choosing, rather than closed by a choice.
    private(set) var isChoosing = true
    /// Asks for a folder for "Other Location…". Replaced in tests.
    var chooseFolder: (URL) -> URL? = Picker.askForFolder

    init(
        options: Options, displays: [PickDisplay], windows: [PickWindow], microphones: [PickMicrophone], pointer: CGPoint,
        store: UserDefaults? = nil
    ) {
        self.options = options
        self.microphones = microphones
        self.store = store
        var settings = (store.map { Preferences.load(from: $0) } ?? Preferences()).overridden(by: options)
        // A microphone remembered from last time that is not connected now: start without one rather than fail.
        if let id = settings.microphoneID, !microphones.contains(where: { $0.id == id }) { settings.microphoneID = nil }
        self.settings = settings
        model = PickerModel(displays: displays, windows: windows, pointer: pointer)
        // `--gui --region` starts with that region selected, on the display `--display` names.
        if let region = options.region { model.selectRegion(region, on: options.display) }
        toolbar = PickerToolbar(mode: model.mode, microphones: microphones)

        // Weak: the toolbar lives in an overlay window, which can outlive the picker for a moment.
        toolbar.onCancel = { [weak self] in self?.cancel() }
        toolbar.onStart = { [weak self] in self?.start() }
        toolbar.onModeChange = { [weak self] mode in
            self?.model.mode = mode
            self?.refresh()
        }
        toolbar.onChoice = { [weak self] in self?.choose($0) }
    }

    // MARK: Options menu

    /// Applies a choice from the Options menu and remembers it for next time, as ⌘⇧5 does.
    func choose(_ choice: PickerChoice) {
        let setting: Preferences.Setting
        switch choice {
        case .saveFolder(let folder):
            settings.saveFolder = folder
            setting = .saveFolder
        case .otherFolder:
            // The overlays would hide the folder dialog, so they step aside while it is open.
            let wasShown = keyMonitor != nil
            if wasShown { hide() }
            let folder = chooseFolder(settings.saveFolder.url)
            if wasShown { show() }
            guard let folder else { return }
            settings.saveFolder = .custom(folder)
            setting = .saveFolder
        case .microphone(let id):
            settings.microphoneID = id
            setting = .microphone
        case .quality(let quality):
            settings.quality = quality
            setting = .quality
        case .hevc(let hevc):
            settings.hevc = hevc
            setting = .hevc
        case .fps(let fps):
            settings.fps = fps
            setting = .fps
        case .showsCursor(let shows):
            settings.showsCursor = shows
            setting = .showsCursor
        case .afterSaving(let action):
            settings.afterSaving = action
            setting = .afterSaving
        }
        if let store { settings.save(setting, to: store) }
        refresh()
    }

    private static func askForFolder(_ start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder to save recordings in."
        panel.directoryURL = start
        // Like any panel it would hide while screc is not the active app; see `showFailureDialog`.
        panel.hidesOnDeactivate = false
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
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
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 36, 76:  // Return, Enter
                MainActor.assumeIsolated { self?.start() }
                return nil
            case 53:  // Esc
                MainActor.assumeIsolated { self?.cancel() }
                return nil
            default:
                return event
            }
        }
    }

    /// Takes the overlays off the screen and stops listening for keys: for the folder dialog, an error dialog, or
    /// when a choice has been made.
    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for view in overlays { view.window?.orderOut(nil) }
        NSCursor.arrow.set()
    }

    // MARK: Updating

    /// Brings every view in line with the model: the overlays, the summary line, the options menu.
    func refresh() {
        var parts = [["Display", "Window", "Region"][model.mode.rawValue]]
        let selection = model.selection
        if let selection {
            let plan = VideoPlan(points: selection.size, pixelScale: selection.display.scale, options: recordingOptions)
            parts.append("\(plan.width) × \(plan.height)")
            parts.append("up to about \(formatBytes(plan.bytesPerHour)) per hour")
        }
        parts.append(settings.quality.title)
        let microphone = microphones.first { $0.id == settings.microphoneID }
        parts.append(microphone.map { "Microphone: \($0.name)" + ($0.bluetooth ? " (what you hear drops to call quality)" : "") } ?? "No microphone")
        if options.output == nil { parts.append("Saves to \(FileManager.default.displayName(atPath: settings.saveFolder.url.path))") }

        toolbar.update(
            caption: parts.joined(separator: "  ·  "),
            canRecord: model.mode != .window && selection != nil,
            settings: settings)
        for view in overlays { view.needsDisplay = true }
    }

    // MARK: Finishing

    /// Closes the picker without a choice.
    func cancel() {
        guard isChoosing else { return }
        isChoosing = false
        hide()
        onCancel()
    }

    /// Takes the picker off the screen for good and lets its windows go.
    func close() {
        isChoosing = false
        hide()
        for view in overlays { view.window?.close() }
    }

    /// The command-line options with the current settings written in.
    private var recordingOptions: Options {
        var result = options
        settings.configure(&result)
        return result
    }

    /// Closes the picker and hands the choice on. Does nothing while there is no selection.
    func start() {
        guard isChoosing, let selection = model.selection else { return }
        var picked = recordingOptions
        picked.select(selection.target)
        isChoosing = false
        // Stop listening for keys, so Enter and Esc are not caught while the recording runs.
        hide()
        onPick(picked)
    }
}
