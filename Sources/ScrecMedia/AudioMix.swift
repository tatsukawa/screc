import AVFoundation

/// Mixes all audio tracks of an .mp4 file into one, in place.
///
/// The microphone is recorded as a second audio track next to the system audio, and many players only play the first
/// track. The video is copied without re-encoding; only the audio is mixed down and re-encoded. A file with fewer than
/// two audio tracks is left untouched. If mixing fails, the file is left as it was.
public func mixAudioTracks(of url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }

    // A fresh name next to the file: nothing that exists is replaced, and the final swap stays on one volume.
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mixing.mp4")
    var keepTemporary = false
    defer { if !keepTemporary { try? FileManager.default.removeItem(at: temporary) } }

    let reader = try AVAssetReader(asset: asset)
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)  // nil: pass the encoded frames through
    let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(videoOutput)
    reader.add(audioOutput)

    let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
    let videoInput = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil,
        sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: MovieSettings.audioBitrate,
    ])
    writer.add(videoInput)
    writer.add(audioInput)

    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    await pump([(videoOutput, videoInput), (audioOutput, audioInput)])

    guard writer.status == .writing, reader.status == .completed else {
        reader.cancelReading()
        writer.cancelWriting()
        throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    keepTemporary = true  // It has become `url`.
}

/// Copies every sample of each output to its input, all at the same time (the writer needs the tracks interleaved).
///
/// Returns once every track has been copied, or as soon as an append fails. An append fails when the writer has failed,
/// and then an input that is waiting to become ready is never called again, so waiting for it would hang.
private func pump(_ pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)]) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let completion = PumpCompletion(count: pairs.count, done: done)
        for (index, pair) in pairs.enumerated() {
            var finished = false  // Only touched on this pair's queue.
            pair.input.requestMediaDataWhenReady(on: DispatchQueue(label: "screc.mix.\(index)")) {
                guard !finished else { return }
                while pair.input.isReadyForMoreMediaData {
                    guard let sample = pair.output.copyNextSampleBuffer() else {  // The end of this track.
                        finished = true
                        pair.input.markAsFinished()
                        completion.trackFinished()
                        return
                    }
                    guard pair.input.append(sample) else {  // The writer has failed.
                        finished = true
                        completion.failed()
                        return
                    }
                }
            }
        }
    }
}

/// Resumes the waiting `pump` exactly once: when every track is done, or at the first failure.
private final class PumpCompletion {
    private let lock = NSLock()
    private var remaining: Int
    private var done: CheckedContinuation<Void, Never>?

    init(count: Int, done: CheckedContinuation<Void, Never>) {
        remaining = count
        self.done = done
    }

    func trackFinished() {
        lock.withLock {
            remaining -= 1
            if remaining == 0 { resume() }
        }
    }

    func failed() {
        lock.withLock { resume() }
    }

    /// Call with the lock held.
    private func resume() {
        done?.resume()
        done = nil
    }
}
