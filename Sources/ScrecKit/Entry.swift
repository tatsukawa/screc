// screc records the screen together with the system audio, using only ScreenCaptureKit, so no virtual audio device
// (BlackHole and the like), driver or background process is needed. It requires macOS 15 or later.
//
// There are two ways in, and both end up in `record(_:control:)`:
//
//   screc            opens the GUI, where a display, window or region is chosen on screen (GUI/)
//   screc --display  records what the options say and stops on Ctrl+C (the command-line interface)
//
// The GUI only builds an `Options` value; it never records anything itself.

import AppKit

/// Runs screc with the process's command-line arguments. Does not return.
@MainActor
public func runScrec() -> Never {
    let options: Options
    do {
        options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    } catch UsageError.help {
        print(usage)
        exit(0)
    } catch UsageError.invalid(let message) {
        fail(message)
    } catch {
        fail("\(error)")
    }

    if options.gui { runGUI(options) }

    Task { @MainActor in
        if options.list { await listTargets() } else { _ = await record(options) }
        exit(0)
    }
    dispatchMain()
}
