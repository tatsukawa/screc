import ScreenCaptureKit

/// Asks the system what can be recorded. Exits with instructions if the screen recording permission is missing.
func shareableContent() async -> SCShareableContent {
    do {
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    } catch {
        fail("""
            screen recording is not permitted (\(error.localizedDescription)).
            Allow the terminal app that runs screc in System Settings > Privacy & Security >
            "Screen & System Audio Recording", then restart the terminal.
            """)
    }
}

/// "App — Title", the name under which a window is listed and can be matched with `--window`.
func label(_ window: SCWindow) -> String {
    [window.owningApplication?.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
}

/// Normal application windows, front-most first. Menu bar items, the Dock and similar are left out.
func ordinaryWindows(_ content: SCShareableContent) -> [SCWindow] {
    let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var rank: [CGWindowID: Int] = [:]  // Position in the system's front-to-back list.
    for (position, info) in onScreen.enumerated() {
        if let id = info[kCGWindowNumber as String] as? CGWindowID { rank[id] = position }
    }
    return content.windows
        .filter { $0.windowLayer == 0 && $0.frame.width >= 50 && $0.frame.height >= 50 && !label($0).isEmpty }
        .sorted { rank[$0.windowID, default: .max] < rank[$1.windowID, default: .max] }
}

/// Finds the window that `--window` refers to, by ID or by part of its name. The front-most match wins.
func findWindow(_ query: String, in windows: [SCWindow]) -> SCWindow {
    if let id = CGWindowID(query), let window = windows.first(where: { $0.windowID == id }) { return window }
    let matches = windows.filter { label($0).localizedCaseInsensitiveContains(query) }
    guard let first = matches.first else { fail("no window matches \"\(query)\" (see --list)") }
    if matches.count > 1 {
        say("screc: \(matches.count) windows match. Recording the front-most one, \"\(label(first))\" (ID \(first.windowID)). Give an ID from --list to pick another.")
    }
    return first
}

/// Implements `--list`.
func listTargets() async {
    let content = await shareableContent()
    print("Displays (--display):")
    for (index, display) in content.displays.enumerated() { print("  \(index): \(display.width)x\(display.height) pt") }
    print("Windows (--window):")
    for window in ordinaryWindows(content) {
        print("  \(window.windowID): \(label(window))  [\(Int(window.frame.width))x\(Int(window.frame.height)) pt]")
    }
    print("Microphones (--mic-device):")
    let automatic = chooseMicrophone(nil)
    for microphone in microphones() {
        print("  \(microphone.localizedName)" + (isBluetooth(microphone) ? "  [Bluetooth]" : "")
            + (microphone.uniqueID == automatic?.uniqueID ? "  <- used when only --mic is given" : ""))
    }
}
