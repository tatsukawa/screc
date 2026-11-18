import AVFoundation

/// Mixes all audio tracks of an .mp4 file into one, in place.
///
/// The microphone is recorded as a second audio track next to the system audio, and many players only play the first
/// track. The video is copied without re-encoding; only the audio is mixed down and re-encoded. A file with fewer than
/// two audio tracks is left untouched.
public func mixAudioTracks(of url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }

    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).mixing.mp4")
    try? FileManager.default.removeItem(at: temporary)

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

    async let video: Void = pump(videoOutput, into: videoInput)
    async let audio: Void = pump(audioOutput, into: audioInput)
    _ = await (video, audio)
    await writer.finishWriting()

    guard reader.status == .completed, writer.status == .completed else {
        try? FileManager.default.removeItem(at: temporary)
        throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown)
    }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
}

/// Copies every sample from `output` to `input`, then closes the input.
private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "screc.pump")) {
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                    input.markAsFinished()
                    done.resume()
                    return
                }
            }
        }
    }
}
