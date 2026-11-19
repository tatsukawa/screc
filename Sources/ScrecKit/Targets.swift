import ScreenCaptureKit

/// Asks the system what can be recorded. Exits with instructions if the screen recording permission is missing.
@MainActor
func shareableContent() async -> SCShareableContent {
    do {
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    } catch {
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        // The permission belongs to the app when it was opened as one, and to the terminal whenever screc runs from a
        // terminal, even the binary inside the app.
        if openedAsApp {
            fail("""
                screen recording is not permitted (\(error.localizedDescription)).
                Allow screc in System Settings > Privacy & Security > "Screen & System Audio Recording", then open screc again.
                """, systemSettings: pane)
        }
        fail("""
            screen recording is not permitted (\(error.localizedDescription)).
            Allow the terminal app that runs screc in System Settings > Privacy & Security >
            "Screen & System Audio Recording", then restart the terminal.
            """, systemSettings: pane)
    }
}

/// Clips a region to its display. The capture needs at least 16 points on each axis.
func recordableRegion(_ region: CGRect, in displaySize: CGSize) -> CGRect? {
    let clipped = region.intersection(CGRect(origin: .zero, size: displaySize))
    guard !clipped.isNull, clipped.width >= 16, clipped.height >= 16 else { return nil }
    return clipped
}

/// "App — Title", the name under which a window is listed and can be matched with `--window`.
func label(_ window: SCWindow) -> String {
    [window.owningApplication?.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
}

/// `text` made safe to print to a terminal. Window titles and device names come from other programs, and a control
/// character in one could rewrite what the terminal shows, for example to fake a line of `--list` output.
func printable(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : $0 }))
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

/// Finds the window that `--window` names.
///
/// A number is a window ID and must match exactly. Anything else must occur in exactly one window's "App — Title":
/// when it matches several, recording the front-most one could capture a window the user did not mean, and that window
/// may show something private, so it is an error that lists the candidates instead.
@MainActor
func findWindow(_ query: String, in windows: [SCWindow]) -> SCWindow {
    if let id = CGWindowID(query) {
        guard let window = windows.first(where: { $0.windowID == id }) else { fail("there is no window with the ID \(id) (see --list)") }
        return window
    }
    let matches = windows.filter { label($0).localizedCaseInsensitiveContains(query) }
    guard let first = matches.first else { fail("no window matches \"\(printable(query))\" (see --list)") }
    guard matches.count == 1 else {
        let candidates = matches.map { "  \($0.windowID): \(printable(label($0)))" }.joined(separator: "\n")
        fail("\(matches.count) windows match \"\(printable(query))\". Give the ID of the one to record:\n\(candidates)")
    }
    return first
}

/// Implements `--list`.
@MainActor
func listTargets() async {
    let content = await shareableContent()
    print("Displays (--display):")
    for (index, display) in content.displays.enumerated() { print("  \(index): \(display.width)x\(display.height) pt") }
    print("Windows (--window):")
    for window in ordinaryWindows(content) {
        print("  \(window.windowID): \(printable(label(window)))  [\(Int(window.frame.width))x\(Int(window.frame.height)) pt]")
    }
    print("Microphones (--mic-device):")
    let automatic = chooseMicrophone(nil)
    for microphone in microphones() {
        print("  \(printable(microphone.localizedName))" + (isBluetooth(microphone) ? "  [Bluetooth]" : "")
            + (microphone.uniqueID == automatic?.uniqueID ? "  <- used when only --mic is given" : ""))
    }
}
