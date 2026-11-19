import AppKit

/// One run of the GUI. It goes from choosing what to record, to recording, to waiting for the next recording.
///
/// Opened as an app, screc stays open between recordings, like any other app: the Dock icon, ⌘N or the Dock menu start
/// the next one, and ⌘Q quits. Run from a terminal, it is a command: it quits after one recording, or when the picker is
/// cancelled.
@MainActor
final class GUISession {
    enum State: Equatable { case idle, choosing, recording }

    /// The session of this process, reached by the app delegate.
    static var shared: GUISession?

    private(set) var state = State.idle
    /// Whether screc stays open after a recording or a cancelled picker.
    let staysOpen: Bool
    private(set) var picker: Picker?
    private let options: Options

    /// Builds a picker for what is on screen now. Replaced in tests.
    var makePicker: (Options) async -> Picker
    /// Shows or brings forward a picker. Replaced in tests, which must not cover the screen.
    var present: (Picker) -> Void = { picker in
        if picker.overlays.isEmpty { picker.makeOverlays() }
        picker.show()
    }
    /// Records what was picked and does what the settings say with the file.
    var recordPicked: (Options) async -> Void
    /// Ends the program. Replaced in tests.
    var quit: () -> Void = { exit(0) }

    init(options: Options, staysOpen: Bool, makePicker: @escaping (Options) async -> Picker, recordPicked: @escaping (Options) async -> Void) {
        self.options = options
        self.staysOpen = staysOpen
        self.makePicker = makePicker
        self.recordPicked = recordPicked
    }

    /// Starts choosing the next recording. While choosing or recording, it brings that to the front instead, so there
    /// is never more than one of either.
    func newRecording() {
        switch state {
        case .choosing:
            if let picker { present(picker) }
        case .recording:
            RecordingIndicator.current?.panel.orderFrontRegardless()
        case .idle:
            state = .choosing
            Task { @MainActor in open(await makePicker(options)) }
        }
    }

    private func open(_ picker: Picker) {
        picker.onPick = { [weak self] picked in Task { @MainActor in await self?.record(picked) } }
        picker.onCancel = { [weak self] in self?.cancelled() }
        self.picker = picker
        Picker.current = picker
        present(picker)
    }

    private func record(_ picked: Options) async {
        dismissPicker()
        state = .recording
        await recordPicked(picked)
        state = .idle
        ended()
    }

    private func cancelled() {
        dismissPicker()
        state = .idle
        ended()
    }

    private func dismissPicker() {
        picker?.close()
        picker = nil
        Picker.current = nil
    }

    /// After a recording or a cancelled picker: an app stays open for the next one; from a terminal, screc is done.
    private func ended() {
        if !staysOpen { quit() }
    }
}
