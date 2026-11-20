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

/// A problem that ends one recording, or keeps it from starting.
///
/// Recording code throws it rather than exiting, because the app stays open between recordings: the command line
/// prints it and exits (`fail(_:)`), while the GUI shows it and goes back to waiting (`showError(_:)`).
struct ScrecError: Error, CustomStringConvertible, Equatable {
    enum Kind: Equatable {
        case failure
        /// The recording stopped before its first frame, so there is nothing to save. Not worth a dialog.
        case nothingRecorded
    }

    let description: String
    /// A System Settings pane that fixes the problem; dialogs offer to open it.
    var systemSettings: URL?
    var kind = Kind.failure

    init(_ description: String, systemSettings: URL? = nil, kind: Kind = .failure) {
        self.description = description
        self.systemSettings = systemSettings
        self.kind = kind
    }

    static let nothingRecorded = ScrecError("nothing was recorded: it stopped before the first frame arrived", kind: .nothingRecorded)
}

/// Prints `screc: <message>` to standard error and exits with status 1.
///
/// - Parameter systemSettings: A System Settings pane that fixes the problem; the dialog offers to open it.
@MainActor
func fail(_ message: String, systemSettings: URL? = nil) -> Never {
    say("screc: " + message)
    if showsFailuresInDialog { showErrorDialog(message, systemSettings: systemSettings, quits: true) }
    exit(1)
}

/// `fail(_:systemSettings:)` for a thrown error.
@MainActor
func fail(_ error: Error) -> Never {
    let screcError = error as? ScrecError
    fail(screcError?.description ?? "\(error)", systemSettings: screcError?.systemSettings)
}

/// Tells the user about an error and carries on: the GUI's counterpart of `fail(_:)`.
@MainActor
func showError(_ error: Error) {
    let screcError = error as? ScrecError
    let message = screcError?.description ?? "\(error)"
    say("screc: " + message)
    guard screcError?.kind != .nothingRecorded else { return }
    showErrorDialog(message, systemSettings: screcError?.systemSettings, quits: false)
}

@MainActor
private func showErrorDialog(_ message: String, systemSettings: URL?, quits: Bool) {
    GUISession.shared?.picker?.hide()  // The overlays sit above dialogs.
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = quits ? "screc cannot continue" : "screc could not record"
    alert.informativeText = message.prefix(1).uppercased() + message.dropFirst()
    if systemSettings != nil { alert.addButton(withTitle: "Open System Settings") }
    alert.addButton(withTitle: quits ? "Quit" : "OK")
    // An alert is a panel, and panels hide while their app is not active. screc, opened from Finder, is not always
    // allowed to become active, and the alert then waited invisibly while the app seemed stuck in the background.
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn, let systemSettings { NSWorkspace.shared.open(systemSettings) }
}
