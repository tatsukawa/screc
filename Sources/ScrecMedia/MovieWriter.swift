import AVFoundation
import ScreenCaptureKit

/// Receives the video and audio that an `SCStream` produces and encodes them into an .mp4 file at the requested bitrate.
public final class MovieWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    /// The queue to pass as `sampleHandlerQueue` when adding this object as a stream output.
    public let queue = DispatchQueue(label: "screc.writer")
    /// Called when the stream stops on its own, for example because a display was disconnected.
    public var onStreamError: ((Error) -> Void)?

    private let writer: AVAssetWriter
    private var inputs: [SCStreamOutputType: AVAssetWriterInput] = [:]
    private var started = false

    public init(url: URL, settings: MovieSettings) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        super.init()

        inputs[.screen] = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
            ],
        ])
        // Microphones differ in format; the input converts whatever arrives to 48 kHz stereo AAC.
        for type in settings.microphone ? [SCStreamOutputType.audio, .microphone] : [.audio] {
            inputs[type] = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: MovieSettings.audioBitrate,
            ])
        }
        for input in inputs.values {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, let input = inputs[type] else { return }
        if type == .screen {
            guard hasNewFrame(sample) else { return }  // While the screen is unchanged, only empty notifications arrive.
            if !started {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: sample.presentationTimeStamp)
                started = true
            }
        }
        // Audio that arrives before the first video frame is dropped.
        guard started, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    private func hasNewFrame(_ sample: CMSampleBuffer) -> Bool {
        guard sample.imageBuffer != nil,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete || status == .started
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) { onStreamError?(error) }

    /// Closes the file. Call it after the stream has stopped.
    public func finish() async throws {
        let writing = queue.sync { () -> Bool in
            guard started, writer.status == .writing else { return false }
            inputs.values.forEach { $0.markAsFinished() }
            return true
        }
        guard writing else {
            throw writer.error ?? NSError(domain: "screc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a single video frame arrived"])
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
