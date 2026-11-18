import CoreGraphics
import ScrecMedia

/// The output resolution and video bitrate that follow from the size of the recorded area and the chosen options.
struct VideoPlan: Equatable {
    let width: Int
    let height: Int
    /// Video bitrate in bits per second.
    let bitrate: Int

    /// - Parameters:
    ///   - points: Size of the recorded area, in points.
    ///   - pixelScale: Backing scale factor of the screen (2 on Retina).
    init(points: CGSize, pixelScale: CGFloat, options: Options) {
        let scale = pixelScale * CGFloat(options.scale ?? options.quality.scale)
        func pixels(_ length: CGFloat) -> Int { max(16, Int((length * scale).rounded()) & ~1) }  // Even sizes, for the encoder.
        width = pixels(points.width)
        height = pixels(points.height)
        // The floor only applies to the computed bitrate: an explicit --bitrate is taken as given.
        let automatic = Double(width * height) * options.quality.bitsPerPixel * (options.hevc ? 0.6 : 1)
        bitrate = options.bitrate.map { Int($0 * 1_000_000) } ?? max(300_000, Int(automatic))
    }

    /// The size of one hour of recording, as an upper bound. The encoder uses less than the target bitrate while the
    /// screen barely changes, so the real size is usually smaller.
    var bytesPerHour: Double { Double(bitrate + MovieSettings.audioBitrate) / 8 * 3600 }

    /// The video bitrate for display, for example "12.6 Mbps".
    var megabits: String { String(format: "%.1f Mbps", Double(bitrate) / 1_000_000) }

    func movieSettings(for options: Options) -> MovieSettings {
        MovieSettings(width: width, height: height, videoBitrate: bitrate, frameRate: options.fps, hevc: options.hevc, microphone: options.mic)
    }
}
