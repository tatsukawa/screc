import AVFoundation
import AppKit
import ScreenCaptureKit
import ScrecMedia

enum Event {
    case stopRequested
    /// The capture or the encoder failed, and the recording cannot go on.
    case failed(Error)
}

/// The handle through which one recording is observed and stopped.
///
/// The command line stops it with a signal (Ctrl+C) and the GUI with its stop button; both call `stop()`.
final class Control {
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    /// Called once the recording has actually started.
    var onStart: (() -> Void)?
    /// Called once the recording begins to stop, whatever stopped it, before the file is finished.
    var onStopping: (() -> Void)?
    /// The caller's own windows that must not appear in the recording. Only used when ScreenCaptureKit does not list
    /// screc as an application; normally all of screc's windows are left out (see `resolveTarget`).
    var excludedWindowIDs: [CGWindowID] = []
    /// How to stop, as told to the user when the recording starts.
    var stopHint = "Ctrl+C"

    init() {
        let stream = AsyncStream<Event>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    /// Asks the recording to stop. Safe to call from any thread.
    func stop() { continuation.yield(.stopRequested) }

    /// Delivers capture and encoder failures on the same stream as requests to stop.
    func reportFailure(_ error: Error) { continuation.yield(.failed(error)) }

    /// Schedules the duration limit. A manual stop or a failure cancels the task.
    func stop(after duration: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.stop()
        }
    }
}

/// What a recording captures.
private struct CaptureTarget {
    let filter: SCContentFilter
    /// The part of the display to record, in points; `nil` for the whole content.
    let sourceRect: CGRect?
    /// A one-line description for the log.
    let description: String
}

/// Records according to `options` until `control` is told to stop, and returns the file that was written.
///
/// Throws a `ScrecError` if recording cannot start or the file cannot be saved, and `ScrecError.nothingRecorded` if it
/// stopped before the first frame. Nothing is left behind in either case, except a finished recording that could not be
/// moved to its final name; the error says where it is.
@MainActor
func record(_ options: Options, control: Control = Control()) async throws -> URL {
    let content = try await shareableContent()
    let target = try resolveTarget(options, in: content, excluding: control.excludedWindowIDs)
    let plan = VideoPlan(
        points: target.sourceRect?.size ?? target.filter.contentRect.size,
        pixelScale: CGFloat(target.filter.pointPixelScale),
        options: options)
    let configuration = try makeConfiguration(options, plan: plan, sourceRect: target.sourceRect)

    let output = try prepareOutput(for: options)
    // Cleared once publishing has been tried: from then on, the staged recording is either saved or the only copy.
    var discardsStaging = true
    defer { if discardsStaging { output.discard() } }

    let movie: MovieWriter
    do {
        movie = try MovieWriter(url: output.recording, settings: plan.movieSettings(for: options))
    } catch {
        throw ScrecError("cannot create the recording: \(error.localizedDescription)")
    }
    movie.onFailure = control.reportFailure
    let stream = SCStream(filter: target.filter, configuration: configuration, delegate: movie)

    let signals = StopSignals(control: control) {
        say("\nscrec: aborted; the unfinished recording was discarded")
        output.discard()
        exit(130)
    }
    defer { signals.restore() }

    do {
        try stream.addStreamOutput(movie, type: .screen, sampleHandlerQueue: movie.queue)
        try stream.addStreamOutput(movie, type: .audio, sampleHandlerQueue: movie.queue)
        if options.mic { try stream.addStreamOutput(movie, type: .microphone, sampleHandlerQueue: movie.queue) }
        try await stream.startCapture()
    } catch {
        throw ScrecError("cannot start recording: \(error.localizedDescription)")
    }
    let began = Date()
    say("""
        ● Recording \(target.description)
          \(plan.width)x\(plan.height) \(options.fps)fps \(options.hevc ? "HEVC" : "H.264") \(plan.megabits)\
         (estimated \(formatBytes(plan.bytesPerHour)) per hour)
          → \(output.destination.path)
          Stop with: \(control.stopHint)
        """)
    control.onStart?()

    let durationTimer = options.duration.map { control.stop(after: .seconds($0)) }

    // Wait for the first event: either someone asks to stop, or the recording fails.
    for await event in control.events {
        if case .failed(let error) = event { say("screc: the recording was interrupted: \(error.localizedDescription)") }
        break
    }
    durationTimer?.cancel()
    control.onStopping?()
    say("■ Stopping… (press Ctrl+C again to abort without saving)")
    try? await stream.stopCapture()  // Throws if the stream has already stopped by itself, which is fine.
    let seconds = Date().timeIntervalSince(began)
    try await finishRecording(movie, at: output.recording)

    discardsStaging = false
    let saved = try publish(output, signals: signals)
    let bytes = Double((try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int) ?? 0)
    say("Saved: \(saved.path)")
    say("  \(formatBytes(bytes)) in \(formatClock(seconds)), about \(formatBytes(bytes / max(seconds, 1) * 3600)) per hour at this rate")
    return saved
}

/// Allocates staging only after checking that the destination directory exists.
@MainActor
private func prepareOutput(for options: Options) throws -> OutputFile {
    let destination = destinationURL(for: options)
    let directory = destination.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ScrecError("the folder \(directory.path) does not exist")
    }
    do {
        // A name screc made up may be taken by a recording made in the same second; one the user gave is refused.
        return try OutputFile(destination: destination, takingNextFreeName: options.output == nil)
    } catch {
        throw ScrecError("\(error)")
    }
}

/// Closes the staged file and mixes its audio. A failed mix still leaves a complete recording to publish.
@MainActor
private func finishRecording(_ movie: MovieWriter, at recording: URL) async throws {
    do {
        try await movie.finish()
    } catch MovieWriterError.noFrames {
        throw ScrecError.nothingRecorded
    } catch {
        throw ScrecError("cannot save the recording: \(error.localizedDescription)")
    }
    do {
        try await mixAudioTracks(of: recording)
    } catch {
        say("screc: mixing the audio tracks failed, so the microphone stays on a separate track: \(error.localizedDescription)")
    }
}

/// Moves the finished recording to its final name. If that fails, the recording is kept where it is.
@MainActor
private func publish(_ output: OutputFile, signals: StopSignals) throws -> URL {
    let saved: URL
    do {
        saved = try signals.finish { try output.publish() }
    } catch {
        throw ScrecError("cannot save the recording as \(output.destination.path): \(error). It is still at \(output.recording.path)")
    }
    if saved != output.destination {
        say("screc: \(output.destination.lastPathComponent) appeared while recording, so this recording got another name")
    }
    return saved
}

/// Works out what to capture: one window, part of a display, or a whole display.
@MainActor
private func resolveTarget(_ options: Options, in content: SCShareableContent, excluding hidden: [CGWindowID]) throws -> CaptureTarget {
    if let id = options.windowID {
        guard let window = ordinaryWindows(content).first(where: { $0.windowID == id }) else { throw ScrecError("the window you picked is no longer on screen") }
        return windowTarget(window)
    }
    if let query = options.window {
        return windowTarget(try findWindow(query, in: ordinaryWindows(content)))
    }

    let display: SCDisplay
    if let id = options.displayID {
        guard let picked = content.displays.first(where: { $0.displayID == id }) else { throw ScrecError("the display you picked is no longer connected") }
        display = picked
    } else {
        guard content.displays.indices.contains(options.display) else {
            throw ScrecError("there is no display \(options.display); \(content.displays.count) connected (see --list)")
        }
        display = content.displays[options.display]
    }

    let filter: SCContentFilter
    if let screc = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) {
        // Leave out every window of screc itself: the stop panel, and picker overlays that may still be on screen.
        filter = SCContentFilter(display: display, excludingApplications: [screc], exceptingWindows: [])
    } else {
        filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { hidden.contains($0.windowID) })
    }

    let index = content.displays.firstIndex(of: display) ?? options.display
    var description = "display \(index) (\(display.width)x\(display.height) pt)"
    var sourceRect: CGRect?
    if let region = options.region {
        guard let clipped = recordableRegion(region, in: CGSize(width: display.width, height: display.height)) else {
            throw ScrecError("--region lies outside the display (\(display.width)x\(display.height) pt) or is too small")
        }
        sourceRect = clipped
        description += ", region \(Int(clipped.minX)),\(Int(clipped.minY)),\(Int(clipped.width)),\(Int(clipped.height))"
    }
    return CaptureTarget(filter: filter, sourceRect: sourceRect, description: description)
}

private func windowTarget(_ window: SCWindow) -> CaptureTarget {
    CaptureTarget(filter: SCContentFilter(desktopIndependentWindow: window), sourceRect: nil, description: "window \"\(printable(label(window)))\"")
}

/// The file to save to: the one given on the command line, or `Recording-<date>.mp4` in the output directory (the
/// current directory unless one was given).
func destinationURL(for options: Options, now: Date = Date()) -> URL {
    if let output = options.output { return output }
    // A fixed locale and calendar: with the user's, "yyyy" is the year of their calendar, such as 8 in the Japanese
    // one, and names would no longer sort by date.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let name = "Recording-\(formatter.string(from: now)).mp4"
    if let directory = options.outputDirectory { return directory.appendingPathComponent(name) }
    return URL(fileURLWithPath: name).absoluteURL
}

@MainActor
private func makeConfiguration(_ options: Options, plan: VideoPlan, sourceRect: CGRect?) throws -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = plan.width
    configuration.height = plan.height
    if let sourceRect { configuration.sourceRect = sourceRect }
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
    configuration.showsCursor = options.showsCursor
    configuration.capturesAudio = true  // This one switch records the system audio; no virtual audio device is needed.
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    configuration.captureMicrophone = options.mic
    if options.mic, let microphone = try chooseRecordingMicrophone(options) {
        configuration.microphoneCaptureDeviceID = microphone.uniqueID
        say("Microphone: \(printable(microphone.localizedName))" + (isBluetooth(microphone) ? " (Bluetooth: what you hear drops to call quality while recording)" : ""))
    }
    return configuration
}

/// The microphone `options` ask for. One picked in the Options menu may have been unplugged since; that is reported in
/// the GUI's own words, rather than as a search for the device's internal ID.
@MainActor
private func chooseRecordingMicrophone(_ options: Options) throws -> AVCaptureDevice? {
    do {
        return try chooseMicrophone(options.micDevice)
    } catch where !options.given.contains("--mic-device") {
        throw ScrecError("the microphone you picked is no longer connected; choose another in Options > Microphone")
    }
}

/// Ctrl+C and `kill` while recording.
///
/// The first one stops the recording gracefully, so the file is closed properly instead of being cut off. A second one
/// aborts at once, for when saving hangs. The handlers run on their own queue, so they still work while the main thread
/// is busy. The previous signal handlers are restored when saving ends.
final class StopSignals {
    private let queue = DispatchQueue(label: "screc.signals")
    // The queue orders signal handling against publication, which is the last point at which a signal can discard a file.
    private var sources: [Int32: (source: DispatchSourceSignal, previous: sig_t?)] = [:]
    private var stopRequested = false

    init(control: Control, numbers: [Int32] = [SIGINT, SIGTERM], abort: @escaping () -> Void) {
        queue.sync {
            for number in numbers {
                let previous = signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                sources[number] = (source, previous)
                source.setEventHandler { [weak self] in
                    guard let self, let source = sources[number]?.source else { return }
                    if stopRequested || source.data > 1 { abort() }
                    stopRequested = true
                    control.stop()
                }
                source.resume()
            }
        }
    }

    /// Publishes before restoring the handlers, without letting an abort run between the two.
    func finish<T>(_ publish: () throws -> T) rethrows -> T {
        try queue.sync {
            defer { restoreHandlers() }
            return try publish()
        }
    }

    func restore() {
        queue.sync { restoreHandlers() }
    }

    private func restoreHandlers() {
        for (number, entry) in sources {
            entry.source.cancel()
            signal(number, entry.previous)
        }
        sources.removeAll()
    }
}
