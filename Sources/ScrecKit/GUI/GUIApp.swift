import AppKit
import ScreenCaptureKit

/// Runs the GUI: lets the user choose what to record, records it, and then reveals the file in Finder. Does not return.
@MainActor
func runGUI(_ options: Options) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // No Dock icon.
    Task { @MainActor in
        let picker = await makePicker(options)
        picker.onPick = { picked in Task { @MainActor in await recordAndReveal(picked) } }
        Picker.current = picker
        picker.makeOverlays()
        picker.show()
    }
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
    if options.mic { options.micDevice = chooseMicrophone(options.micDevice)?.uniqueID }  // The menu's initial choice.
    return Picker(options: options, displays: displays, windows: windows, microphones: microphones, pointer: pointer)
}

/// Records what was picked while showing the stop panel, then reveals the file in Finder and exits.
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

    // Showing the file in Finder is a convenience: do not wait for it. `open -R` rather than NSWorkspace, which logs a
    // pasteboard warning to the terminal.
    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-R", output.path])
    try? await Task.sleep(for: .milliseconds(1500))  // Show "Saved" for a moment before quitting.
    exit(0)
}
