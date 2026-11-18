import Foundation

/// The `--help` text.
let usage = """
    Usage: screc                          choose what to record on screen (GUI)
           screc [options] [output.mp4]   record as the options say (command line)

      Without an output file, the recording is saved as ./Recording-<date>.mp4.
      Stop with Ctrl+C on the command line, or with the Stop button that appears at the top of the screen in the GUI
      (the menu bar has one too).

    What to record
      --display N        a whole display (default 0; the numbers are in --list)
      --region X,Y,W,H   part of a display (points, from its top-left corner)
      --window NAME      one window (part of "App — Title", or an ID from --list)
      --mic              also record the microphone, mixed into the same audio track as the system audio.
                         Uses the default input, but the built-in microphone instead if that is a Bluetooth
                         device (a Bluetooth headset drops to call quality while its microphone is in use)
      --mic-device NAME  record this microphone (part of its name; implies --mic; see --list)
      --list             list the displays, windows and microphones, then exit

    Compression (the size of one hour of recording is estimated when a recording starts)
      --quality Q        high / medium / low (default medium; low also halves the resolution)
      --scale F          resolution multiplier, 0.1-1 (default 1; 0.5 for low)
      --bitrate MBPS     video bitrate in Mbps, instead of the one from --quality
      --fps N            frame rate (default 60)
      --hevc             save as HEVC instead of H.264 (about 40% smaller at the same quality; less widely supported)

    Other
      --duration SEC     stop automatically after this many seconds
      --gui              open the GUI with the other options as its starting point (e.g. screc --gui --hevc)
      -h, --help         show this help
    """

/// Why the command line could not be turned into `Options`.
enum UsageError: Error, Equatable {
    /// `-h` / `--help` was given: print the help text and exit successfully.
    case help
    /// An argument is wrong. The message says which one and why.
    case invalid(String)
}

/// Video quality presets.
enum Quality: String, CaseIterable {
    case high, medium, low

    /// Video bitrate per output pixel, in bits per second. Screen content compresses far better than camera footage.
    var bitsPerPixel: Double { self == .high ? 3.0 : 1.5 }
    /// Resolution multiplier applied unless `--scale` overrides it.
    var scale: Double { self == .low ? 0.5 : 1 }
    /// The name shown in the GUI.
    var title: String { ["high": "High", "medium": "Standard", "low": "Small (half resolution)"][rawValue]! }
}

/// Everything that decides what is recorded and how. Both the command line and the GUI produce one of these.
struct Options: Equatable {
    var output: URL?
    var mic = false
    /// Part of a microphone's name, or its ID. `nil` picks one automatically.
    var micDevice: String?
    /// Index of the display to record (see `--list`).
    var display = 0
    /// Part of the display to record, relative to its top-left corner, in points.
    var region: CGRect?
    /// A window to record instead of a display: part of "App — Title", or a window ID.
    var window: String?
    var quality = Quality.medium
    var scale: Double?
    /// Video bitrate in Mbps. Overrides the preset's bitrate.
    var bitrate: Double?
    var fps = 60
    var hevc = false
    /// Stop automatically after this many seconds.
    var duration: Double?
    var list = false
    var gui = false
}

extension Options {
    /// Parses the command line, without the program name. No arguments at all means "open the GUI".
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        options.gui = arguments.isEmpty
        var args = arguments[...]

        func value(for flag: String) throws -> String {
            guard let value = args.popFirst() else { throw UsageError.invalid("\(flag) needs a value") }
            return value
        }

        while let arg = args.popFirst() {
            switch arg {
            case "-h", "--help":
                throw UsageError.help
            case "--mic":
                options.mic = true
            case "--mic-device":
                options.micDevice = try value(for: arg)
                options.mic = true
            case "--hevc":
                options.hevc = true
            case "--list":
                options.list = true
            case "--gui":
                options.gui = true
            case "--display":
                guard let n = Int(try value(for: arg)), n >= 0 else { throw UsageError.invalid("--display takes a whole number, 0 or more") }
                options.display = n
            case "--region":
                let n = try value(for: arg).split(separator: ",").compactMap { Double($0) }
                guard n.count == 4, n[0] >= 0, n[1] >= 0, n[2] > 0, n[3] > 0 else {
                    throw UsageError.invalid("--region takes X,Y,W,H, for example 0,0,1280,720")
                }
                options.region = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
            case "--window":
                options.window = try value(for: arg)
            case "--quality":
                guard let quality = Quality(rawValue: try value(for: arg)) else {
                    throw UsageError.invalid("--quality is high, medium or low")
                }
                options.quality = quality
            case "--scale":
                guard let scale = Double(try value(for: arg)), (0.1...1).contains(scale) else {
                    throw UsageError.invalid("--scale takes a number from 0.1 to 1")
                }
                options.scale = scale
            case "--bitrate":
                guard let mbps = Double(try value(for: arg)), (0.1...200).contains(mbps) else {
                    throw UsageError.invalid("--bitrate takes a number of Mbps from 0.1 to 200")
                }
                options.bitrate = mbps
            case "--fps":
                guard let fps = Int(try value(for: arg)), (1...240).contains(fps) else {
                    throw UsageError.invalid("--fps takes a whole number from 1 to 240")
                }
                options.fps = fps
            case "--duration":
                guard let seconds = Double(try value(for: arg)), seconds > 0 else {
                    throw UsageError.invalid("--duration takes a positive number of seconds")
                }
                options.duration = seconds
            default:
                if arg.hasPrefix("-") { throw UsageError.invalid("unknown option: \(arg)\n\n\(usage)") }
                if options.output != nil { throw UsageError.invalid("give at most one output file") }
                options.output = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            }
        }
        if options.window != nil && options.region != nil { throw UsageError.invalid("--window and --region cannot be combined") }
        return options
    }
}
