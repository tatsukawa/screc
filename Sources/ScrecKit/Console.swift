import AppKit

/// Writes a line to standard error. Standard output is reserved for data such as the `--list` output.
func say(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Whether screc was opened as an app (from Finder, the Dock, Spotlight: its parent is launchd), rather than run from a
/// terminal. Even the binary inside the app counts as run from a terminal when a terminal started it.
var openedAsApp: Bool { Bundle.main.bundleURL.pathExtension == "app" && getppid() == 1 }

/// Whether failures are shown in a dialog as well. Set by the GUI: an app opened from Finder has no terminal, and
/// without a dialog it would just vanish.
var showsFailuresInDialog = false

/// Prints `screc: <message>` to standard error and exits with status 1.
///
/// - Parameter systemSettings: A System Settings pane that fixes the problem; the dialog offers to open it.
func fail(_ message: String, systemSettings: URL? = nil) -> Never {
    say("screc: " + message)
    if showsFailuresInDialog && Thread.isMainThread {
        MainActor.assumeIsolated { showFailureDialog(message, systemSettings: systemSettings) }
    }
    exit(1)
}

@MainActor
private func showFailureDialog(_ message: String, systemSettings: URL?) {
    GUISession.shared?.picker?.hide()  // The overlays sit above dialogs.
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "screc cannot continue"
    alert.informativeText = message.prefix(1).uppercased() + message.dropFirst()
    if systemSettings != nil { alert.addButton(withTitle: "Open System Settings") }
    alert.addButton(withTitle: "Quit")
    // An alert is a panel, and panels hide while their app is not active. screc, opened from Finder, is not always
    // allowed to become active, and the alert then waited invisibly while the app seemed stuck in the background.
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn, let systemSettings { NSWorkspace.shared.open(systemSettings) }
}
