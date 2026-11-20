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
    var makePicker: (Options) async throws -> Picker
    /// Shows or brings forward a picker. Replaced in tests, which must not cover the screen.
    var present: (Picker) -> Void = { picker in
        if picker.overlays.isEmpty { picker.makeOverlays() }
        picker.show()
    }
    /// Records what was picked and does what the settings say with the file.
    var recordPicked: (Options) async throws -> Void
    /// Tells the user why a picker or a recording failed. Replaced in tests.
    var report: (Error) -> Void = showError
    /// Ends the program with an exit status. Replaced in tests.
    var quit: (Int32) -> Void = { exit($0) }
    /// Called once when the current recording has ended, saved or not. Quitting while recording waits for it.
    var onRecordingEnded: (() -> Void)?

    init(
        options: Options, staysOpen: Bool, makePicker: @escaping (Options) async throws -> Picker,
        recordPicked: @escaping (Options) async throws -> Void
    ) {
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
            Task { @MainActor in
                do {
                    open(try await makePicker(options))
                } catch {
                    state = .idle
                    report(error)
                    ended(failed: true)
                }
            }
        }
    }

    private func open(_ picker: Picker) {
        picker.onPick = { [weak self] picked in self?.beginRecording(picked) }
        picker.onCancel = { [weak self] in self?.cancelled() }
        self.picker = picker
        present(picker)
    }

    private func beginRecording(_ picked: Options) {
        // A reopen arriving before the task starts must not bring back the closed picker.
        state = .recording
        dismissPicker()
        Task {
            var failed = false
            do {
                try await recordPicked(picked)
            } catch {
                report(error)
                failed = (error as? ScrecError)?.kind != .nothingRecorded
            }
            state = .idle
            let recordingEnded = onRecordingEnded
            onRecordingEnded = nil
            recordingEnded?()
            ended(failed: failed)
        }
    }

    private func cancelled() {
        dismissPicker()
        state = .idle
        ended()
    }

    private func dismissPicker() {
        picker?.close()
        picker = nil
    }

    /// After a recording or a cancelled picker: an app stays open for the next one; from a terminal, screc is done.
    private func ended(failed: Bool = false) {
        if !staysOpen { quit(failed ? 1 : 0) }
    }
}
