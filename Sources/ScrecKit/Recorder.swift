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
    let continuation: AsyncStream<Event>.Continuation
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
/// Prints a message and exits if recording cannot start or the file cannot be saved.
@MainActor
func record(_ options: Options, control: Control = Control()) async -> URL {
    let content = await shareableContent()
    let target = resolveTarget(options, in: content, excluding: control.excludedWindowIDs)
    let plan = VideoPlan(
        points: target.sourceRect?.size ?? target.filter.contentRect.size,
        pixelScale: CGFloat(target.filter.pointPixelScale),
        options: options)
    let configuration = makeConfiguration(options, plan: plan, sourceRect: target.sourceRect)

    let output: OutputFile
    do {
        output = try OutputFile(destination: destinationURL(for: options))
    } catch {
        fail("\(error)")
    }
    let movie: MovieWriter
    do {
        movie = try MovieWriter(url: output.recording, settings: plan.movieSettings(for: options))
    } catch {
        output.discard()
        fail("cannot create the recording: \(error.localizedDescription)")
    }
    movie.onFailure = { control.continuation.yield(.failed($0)) }
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
        output.discard()
        fail("cannot start recording: \(error.localizedDescription)")
    }
    let began = Date()
    say("""
        ● Recording \(target.description)
          \(plan.width)x\(plan.height) \(options.fps)fps \(options.hevc ? "HEVC" : "H.264") \(plan.megabits)\
         (up to about \(formatBytes(plan.bytesPerHour)) per hour)
          → \(output.destination.path)
          Stop with: \(control.stopHint)
        """)
    control.onStart?()

    if let duration = options.duration {
        Task {
            try? await Task.sleep(for: .seconds(duration))
            control.stop()
        }
    }

    // Wait for the first event: either someone asks to stop, or the recording fails.
    for await event in control.events {
        if case .failed(let error) = event { say("screc: the recording was interrupted: \(error.localizedDescription)") }
        break
    }
    control.onStopping?()
    say("■ Stopping… (press Ctrl+C again to abort without saving)")
    try? await stream.stopCapture()  // Throws if the stream has already stopped by itself, which is fine.
    let seconds = Date().timeIntervalSince(began)

    do {
        try await movie.finish()
    } catch {
        output.discard()
        fail("cannot save the recording: \(error.localizedDescription)")
    }
    do {
        try await mixAudioTracks(of: output.recording)
    } catch {
        say("screc: mixing the audio tracks failed, so the microphone stays on a separate track: \(error.localizedDescription)")
    }

    let saved: URL
    do {
        saved = try output.publish()
    } catch {
        fail("cannot save the recording as \(output.destination.path): \(error). It is still at \(output.recording.path)")
    }
    if saved != output.destination {
        say("screc: \(output.destination.lastPathComponent) appeared while recording, so this recording got another name")
    }
    let bytes = Double((try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int) ?? 0)
    say("Saved: \(saved.path)")
    say("  \(formatBytes(bytes)) in \(formatClock(seconds)), about \(formatBytes(bytes / max(seconds, 1) * 3600)) per hour at this rate")
    return saved
}

/// Works out what to capture: one window, part of a display, or a whole display.
private func resolveTarget(_ options: Options, in content: SCShareableContent, excluding hidden: [CGWindowID]) -> CaptureTarget {
    if let id = options.windowID {
        guard let window = ordinaryWindows(content).first(where: { $0.windowID == id }) else { fail("the window you picked is no longer on screen") }
        return windowTarget(window)
    }
    if let query = options.window {
        return windowTarget(findWindow(query, in: ordinaryWindows(content)))
    }

    let display: SCDisplay
    if let id = options.displayID {
        guard let picked = content.displays.first(where: { $0.displayID == id }) else { fail("the display you picked is no longer connected") }
        display = picked
    } else {
        guard content.displays.indices.contains(options.display) else {
            fail("there is no display \(options.display); \(content.displays.count) connected (see --list)")
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
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))
        guard !clipped.isNull, clipped.width >= 16, clipped.height >= 16 else {
            fail("--region lies outside the display (\(display.width)x\(display.height) pt) or is too small")
        }
        sourceRect = clipped
        description += ", region \(Int(clipped.minX)),\(Int(clipped.minY)),\(Int(clipped.width)),\(Int(clipped.height))"
    }
    return CaptureTarget(filter: filter, sourceRect: sourceRect, description: description)
}

private func windowTarget(_ window: SCWindow) -> CaptureTarget {
    CaptureTarget(filter: SCContentFilter(desktopIndependentWindow: window), sourceRect: nil, description: "window \"\(printable(label(window)))\"")
}

/// The file to save to: the one given on the command line, or `Recording-<date>.mp4` in the current directory.
private func destinationURL(for options: Options) -> URL {
    options.output ?? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return URL(fileURLWithPath: "Recording-\(formatter.string(from: Date())).mp4").absoluteURL
    }()
}

private func makeConfiguration(_ options: Options, plan: VideoPlan, sourceRect: CGRect?) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = plan.width
    configuration.height = plan.height
    if let sourceRect { configuration.sourceRect = sourceRect }
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
    configuration.showsCursor = true
    configuration.capturesAudio = true  // This one switch records the system audio; no virtual audio device is needed.
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    configuration.captureMicrophone = options.mic
    if options.mic, let microphone = chooseMicrophone(options.micDevice) {
        configuration.microphoneCaptureDeviceID = microphone.uniqueID
        say("Microphone: \(printable(microphone.localizedName))" + (isBluetooth(microphone) ? " (Bluetooth: what you hear drops to call quality while recording)" : ""))
    }
    return configuration
}

/// Ctrl+C and `kill` while recording.
///
/// The first one stops the recording gracefully, so the file is closed properly instead of being cut off. A second one
/// aborts at once, for when saving hangs. The handlers run on their own queue, so they still work while the main thread
/// is busy. The default behaviour is restored afterwards.
private final class StopSignals {
    private let queue = DispatchQueue(label: "screc.signals")
    private var sources: [DispatchSourceSignal] = []
    private var count = 0  // Only touched on `queue`.

    init(control: Control, abort: @escaping () -> Void) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [unowned self] in
                count += 1
                if count == 1 { control.stop() } else { abort() }
            }
            source.resume()
            sources.append(source)
        }
    }

    func restore() {
        sources.forEach { $0.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
