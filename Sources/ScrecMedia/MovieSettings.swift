import AVFoundation

/// How a recording is encoded.
public struct MovieSettings: Sendable, Equatable {
    /// AAC bitrate of the audio tracks, in bits per second.
    public static let audioBitrate = 160_000

    /// Both the initial tracks and the mix use the same AAC format.
    static let aacOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: audioBitrate,
    ]

    public var width: Int
    public var height: Int
    /// Average video bitrate, in bits per second.
    public var videoBitrate: Int
    public var frameRate: Int
    /// HEVC instead of H.264.
    public var hevc: Bool
    /// Whether a second audio track with the microphone is expected.
    public var microphone: Bool

    public init(width: Int, height: Int, videoBitrate: Int, frameRate: Int, hevc: Bool, microphone: Bool) {
        self.width = width
        self.height = height
        self.videoBitrate = videoBitrate
        self.frameRate = frameRate
        self.hevc = hevc
        self.microphone = microphone
    }
}
