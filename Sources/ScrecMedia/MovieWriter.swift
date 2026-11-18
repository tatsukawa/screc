import AVFoundation
import ScreenCaptureKit

/// Receives the video and audio that an `SCStream` produces and encodes them into an .mp4 file at the requested bitrate.
public final class MovieWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    /// The queue to pass as `sampleHandlerQueue` when adding this object as a stream output. All state below is only
    /// touched on it.
    public let queue = DispatchQueue(label: "screc.writer")

    /// Called once, from any thread, when the recording cannot go on: the stream stopped by itself, or the encoder
    /// failed (for example because the disk is full). Set it before the stream starts.
    public var onFailure: ((Error) -> Void)?

    private let writer: AVAssetWriter
    private var inputs: [SCStreamOutputType: AVAssetWriterInput] = [:]
    private var started = false
    /// Set when no more samples are to be written: after a failure, or once `finish()` has begun.
    private var closed = false
    /// The last new picture. It is written again when the recording stops, so that the video lasts until the stop even
    /// when nothing changed on screen at the end; otherwise it would end at the last change, leaving a silent tail.
    private var lastFrame: CMSampleBuffer?
    /// The latest moment any sample, video or audio, has reached.
    private var latest = CMTime.invalid

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
        guard !closed, sample.isValid, let input = inputs[type] else { return }
        advance(to: sample.presentationTimeStamp + (sample.duration.isValid ? sample.duration : .zero))
        if type == .screen {
            guard hasNewFrame(sample) else { return }  // While the screen is unchanged, only empty notifications arrive.
            if !started {
                guard writer.startWriting() else { return fail(writer.error) }
                writer.startSession(atSourceTime: sample.presentationTimeStamp)
                started = true
            }
            lastFrame = sample
        }
        // Audio that arrives before the first video frame is dropped.
        guard started else { return }
        guard writer.status == .writing else { return fail(writer.error) }
        // A real-time input that is not ready drops the sample rather than holding up the capture.
        guard input.isReadyForMoreMediaData else { return }
        if !input.append(sample) { fail(writer.error) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error) }
    }

    /// Closes the file. Call it after the stream has stopped. Throws if nothing could be written or the encoder failed.
    public func finish() async throws {
        let writing = queue.sync { () -> Bool in
            closed = true  // Samples still in flight are ignored from here on.
            guard started, writer.status == .writing else { return false }
            repeatLastFrame()
            inputs.values.forEach { $0.markAsFinished() }
            return true
        }
        guard writing else {
            throw writer.error ?? NSError(domain: "screc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a single video frame arrived"])
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    // MARK: Private, on `queue`

    private func hasNewFrame(_ sample: CMSampleBuffer) -> Bool {
        guard sample.imageBuffer != nil,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete || status == .started
    }

    private func advance(to time: CMTime) {
        if time.isValid && (!latest.isValid || time > latest) { latest = time }
    }

    /// Writes the last picture again at the latest moment reached, so the video track does not end early.
    private func repeatLastFrame() {
        guard let lastFrame, let input = inputs[.screen], latest.isValid, latest > lastFrame.presentationTimeStamp,
            input.isReadyForMoreMediaData
        else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: latest, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: lastFrame, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
            let copy
        else { return }
        input.append(copy)
    }

    /// Stops accepting samples and reports the failure, once.
    private func fail(_ error: Error?) {
        guard !closed else { return }
        closed = true
        onFailure?(error ?? CocoaError(.fileWriteUnknown))
    }
}
