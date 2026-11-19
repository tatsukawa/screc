import AVFoundation

func isBluetooth(_ device: AVCaptureDevice) -> Bool {
    [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(UInt32(bitPattern: device.transportType))
}

/// The available microphones. Devices that show up twice under the same name (an iPhone's, for example) are merged.
func microphones() -> [AVCaptureDevice] {
    var seen = Set<String>()
    return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        .devices.filter { seen.insert($0.localizedName).inserted }
}

/// Chooses the microphone to record with.
///
/// `query` is part of a name, or an ID. Without one, the system's default input is used, unless that is a Bluetooth
/// device and a built-in microphone exists. Using a Bluetooth headset's microphone switches the headset to its low-quality
/// call mode, which makes everything the user hears sound bad for as long as the recording runs.
@MainActor
func chooseMicrophone(_ query: String?) -> AVCaptureDevice? {
    let all = microphones()
    if let query {
        guard let match = all.first(where: { $0.uniqueID == query }) ?? all.first(where: { $0.localizedName.localizedCaseInsensitiveContains(query) }) else {
            fail("no microphone matches \"\(query)\" (see --list)")
        }
        return match
    }
    let current = AVCaptureDevice.default(for: .audio)
    if let current, isBluetooth(current),
        let builtIn = all.first(where: { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn })
    {
        return builtIn
    }
    return current
}
