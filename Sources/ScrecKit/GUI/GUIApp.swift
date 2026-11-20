import AppKit
import ScreenCaptureKit

/// Runs the GUI: lets the user choose what to record, records it, and does what the settings say with the file (by
/// default, shows it in Finder). Opened as an app, screc then waits for the next recording; run from a terminal, it
/// quits. Does not return.
@MainActor
func runGUI(_ options: Options) -> Never {
    let app = NSApplication.shared
    // Opened as an app, screc behaves like one: a Dock icon and a menu bar while it runs, so it can be found, brought
    // back and quit. Run from a terminal, the terminal shows what is going on, and no Dock icon is needed.
    if openedAsApp {
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
    } else {
        app.setActivationPolicy(.accessory)
    }
    app.delegate = ScrecAppDelegate.shared
    showsFailuresInDialog = true  // The app may have been opened from Finder, with no terminal to print to.
    let session = GUISession(options: options, staysOpen: openedAsApp, makePicker: makePicker, recordPicked: recordAndReveal)
    GUISession.shared = session
    session.newRecording()
    app.run()
    exit(0)
}

/// Looks up the displays, windows and microphones and builds a picker for them.
@MainActor
private func makePicker(_ options: Options) async -> Picker {
    let content = await shareableContent()
    let displays = content.displays.enumerated().compactMap { index, display -> PickDisplay? in
        let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display.displayID }
        return screen.map { PickDisplay(index: index, id: display.displayID, frame: display.frame, screenFrame: $0.frame, scale: $0.backingScaleFactor) }
    }
    guard !displays.isEmpty else { fail("no display to record") }
    let windows = ordinaryWindows(content).map { PickWindow(id: $0.windowID, frame: $0.frame) }

    // The mouse location is bottom-left-based, so flip it to match the displays.
    let mouse = NSEvent.mouseLocation
    let pointer = CGPoint(x: mouse.x, y: NSScreen.screens[0].frame.height - mouse.y)

    let microphones = microphones().map { PickMicrophone(id: $0.uniqueID, name: $0.localizedName, bluetooth: isBluetooth($0)) }
    var options = options
    if !options.given.isDisjoint(with: ["--mic", "--mic-device"]) {
        // Asked for on the command line: resolve it as the command line would, failing if it does not exist.
        options.micDevice = chooseMicrophone(options.micDevice)?.uniqueID
    }
    return Picker(
        options: options, displays: displays, windows: windows, microphones: microphones, pointer: pointer, store: Preferences.store)
}

/// The menu bar of the app: the application menu, and File with New Recording.
@MainActor
private func makeMainMenu() -> NSMenu {
    let appMenu = NSMenu(title: "screc")
    appMenu.addItem(withTitle: "About screc", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit screc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let fileMenu = NSMenu(title: "File")
    let newRecording = fileMenu.addItem(
        withTitle: "New Recording", action: #selector(ScrecAppDelegate.newRecording(_:)), keyEquivalent: "n")
    newRecording.target = ScrecAppDelegate.shared
    let menu = NSMenu()
    for submenu in [appMenu, fileMenu] {
        let item = NSMenuItem()
        item.submenu = submenu
        menu.addItem(item)
    }
    return menu
}

/// What the app does when the user reaches it from outside the picker: opening it again, its Dock menu, quitting.
@MainActor
final class ScrecAppDelegate: NSObject, NSApplicationDelegate {
    static let shared = ScrecAppDelegate()  // NSApplication holds its delegate weakly.

    /// Opening screc again while it runs (clicking its Dock icon, say) brings back what it is showing, or starts the next
    /// recording when it is waiting. Without this, nothing visible happened, and screc looked stuck in the background.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if let dialog = NSApp.modalWindow {
            dialog.orderFrontRegardless()
        } else {
            GUISession.shared?.newRecording()
        }
        return false
    }

    /// The Dock icon's menu: Stop Recording while recording, New Recording while waiting.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if RecordingIndicator.current?.phase == .recording {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "").target = self
        } else if GUISession.shared?.state == .idle {
            menu.addItem(withTitle: "New Recording", action: #selector(newRecording(_:)), keyEquivalent: "").target = self
        } else {
            return nil
        }
        return menu
    }

    @objc func newRecording(_ sender: Any?) { GUISession.shared?.newRecording() }

    @objc private func stopRecording() { RecordingIndicator.current?.requestStop() }

    /// Quitting while recording saves the recording instead of throwing it away. The quit is cancelled; the user quits
    /// again once it is saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch RecordingIndicator.current?.phase {
        case .recording:
            RecordingIndicator.current?.requestStop()
            return .terminateCancel
        case .saving:
            return .terminateCancel
        default:
            return .terminateNow
        }
    }
}

/// Records what was picked while showing the stop panel, then does what the settings say with the file.
@MainActor
private func recordAndReveal(_ options: Options) async {
    let control = Control()
    control.stopHint = "the Stop button at the top of the screen, or Ctrl+C here"
    let indicator = RecordingIndicator(stop: control.stop)
    indicator.prepare()
    control.excludedWindowIDs = [indicator.windowID]  // Keep the stop panel out of the video.
    control.onStart = indicator.started
    control.onStopping = indicator.stopping
    try? await Task.sleep(for: .milliseconds(250))  // Let the picker's overlays disappear from the screen first.

    let output = await record(options, control: control)
    indicator.saved()

    // A convenience, so it is not waited for. `open` rather than NSWorkspace, which logs a pasteboard warning to the
    // terminal.
    switch Preferences.load().afterSaving {
    case .showInFinder: _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-R", output.path])
    case .open: _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [output.path])
    case .nothing: break
    }
    try? await Task.sleep(for: .milliseconds(1500))  // Show "Saved" for a moment.
    indicator.dismiss()
}
