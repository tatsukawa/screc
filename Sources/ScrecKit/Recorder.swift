import AppKit
import ScreenCaptureKit
import ScrecMedia

enum Event {
    case stopRequested
    case streamFailed(Error)
}

/// The handle through which one recording is observed and stopped.
///
/// The command line stops it with a signal (Ctrl+C) and the GUI with its stop button; both call `stop()`.
final class Control {
    let events: AsyncStream<Event>
    let continuation: AsyncStream<Event>.Continuation
    /// Called once the recording has actually started.
    var onStart: (() -> Void)?
    /// The caller's own windows (the stop panel, for example) that must not appear in the recording.
    var excludedWindowIDs: [CGWindowID] = []
    /// How to stop, as told to the user when the recording starts.
    var stopHint = "Ctrl+C"

    init() {
        let stream = AsyncStream<Event>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

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
    let output = outputURL(for: options)
    let plan = VideoPlan(
        points: target.sourceRect?.size ?? target.filter.contentRect.size,
        pixelScale: CGFloat(target.filter.pointPixelScale),
        options: options)

    let movie: MovieWriter
    do {
        movie = try MovieWriter(url: output, settings: plan.movieSettings(for: options))
    } catch {
        fail("cannot write to \(output.path): \(error.localizedDescription)")
    }
    movie.onStreamError = { control.continuation.yield(.streamFailed($0)) }
    let stream = SCStream(filter: target.filter, configuration: makeConfiguration(options, plan: plan, sourceRect: target.sourceRect), delegate: movie)

    let signals = trapStopSignals(control)
    defer { signals.forEach { $0.cancel() } }

    do {
        try stream.addStreamOutput(movie, type: .screen, sampleHandlerQueue: movie.queue)
        try stream.addStreamOutput(movie, type: .audio, sampleHandlerQueue: movie.queue)
        if options.mic { try stream.addStreamOutput(movie, type: .microphone, sampleHandlerQueue: movie.queue) }
        try await stream.startCapture()
    } catch {
        try? FileManager.default.removeItem(at: output)
        fail("cannot start recording: \(error.localizedDescription)")
    }
    let began = Date()
    say("""
        ● Recording \(target.description)
          \(plan.width)x\(plan.height) \(options.fps)fps \(options.hevc ? "HEVC" : "H.264") \(plan.megabits)\
         (up to about \(formatBytes(plan.bytesPerHour)) per hour)
          → \(output.path)
          Stop with: \(control.stopHint)
        """)
    control.onStart?()

    if let duration = options.duration {
        Task {
            try? await Task.sleep(for: .seconds(duration))
            control.stop()
        }
    }

    // Wait for the first event: either someone asks to stop, or the stream fails.
    var streamAlive = true
    for await event in control.events {
        if case .streamFailed(let error) = event {
            say("screc: the recording was interrupted: \(error.localizedDescription)")
            streamAlive = false
        }
        break
    }
    say("■ Stopping…")
    if streamAlive { try? await stream.stopCapture() }
    let seconds = Date().timeIntervalSince(began)

    do {
        try await movie.finish()
    } catch {
        fail("cannot save the recording: \(error.localizedDescription)")
    }
    do {
        try await mixAudioTracks(of: output)
    } catch {
        say("screc: mixing the audio tracks failed, so the microphone stays on a separate track: \(error.localizedDescription)")
    }

    let bytes = Double((try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0)
    say("Saved: \(output.path)")
    say("  \(formatBytes(bytes)) in \(formatClock(seconds)), about \(formatBytes(bytes / max(seconds, 1) * 3600)) per hour at this rate")
    return output
}

/// Works out what to capture: one window, part of a display, or a whole display.
private func resolveTarget(_ options: Options, in content: SCShareableContent, excluding hidden: [CGWindowID]) -> CaptureTarget {
    if let query = options.window {
        let window = findWindow(query, in: ordinaryWindows(content))
        return CaptureTarget(filter: SCContentFilter(desktopIndependentWindow: window), sourceRect: nil, description: "window \"\(label(window))\"")
    }

    guard content.displays.indices.contains(options.display) else {
        fail("there is no display \(options.display); \(content.displays.count) connected (see --list)")
    }
    let display = content.displays[options.display]
    let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { hidden.contains($0.windowID) })
    var description = "display \(options.display) (\(display.width)x\(display.height) pt)"
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

/// The output file: the one given on the command line, or `Recording-<date>.mp4` in the current directory.
/// Exits if it already exists, so a recording never overwrites anything.
private func outputURL(for options: Options) -> URL {
    let url = options.output ?? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return URL(fileURLWithPath: "Recording-\(formatter.string(from: Date())).mp4").absoluteURL
    }()
    if FileManager.default.fileExists(atPath: url.path) { fail("\(url.path) already exists") }
    return url
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
        say("Microphone: \(microphone.localizedName)" + (isBluetooth(microphone) ? " (Bluetooth: what you hear drops to call quality while recording)" : ""))
    }
    return configuration
}

/// Makes Ctrl+C and `kill` stop the recording gracefully, so the file is closed properly instead of being cut off.
/// Keep the returned sources alive for as long as the recording runs.
private func trapStopSignals(_ control: Control) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { control.stop() }
        source.resume()
        return source
    }
}
