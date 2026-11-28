import UntitledPluginSDK

@MainActor protocol WirelessMicrophoneAudio {
    var inputName: String? { get }
    var isRunning: Bool { get }
    var hasQueuedAudio: Bool { get }
    func start() throws
    func append(_ samples: [Int16]) throws
    func stop()
}

@MainActor final class CoreAudioWirelessMicrophone: WirelessMicrophoneAudio {
    private let sink = SharingMicrophoneSink(sampleRate: Double(XiaomiRemoteVoice.sampleRate))

    var inputName: String? {
        guard let input = SharingAudioDevices.device(SharingAudioDevices.inputUID),
              SharingAudioDevices.device(SharingAudioDevices.feedUID) != nil else { return nil }
        return input.name
    }

    var isRunning: Bool { sink.isRunning }
    var hasQueuedAudio: Bool { sink.hasQueuedAudio }
    func start() throws { try sink.start() }

    func append(_ samples: [Int16]) throws {
        guard sink.append(samples) else {
            throw PluginError.invalid("虚拟麦克风路线已断开。检查驱动后请再次按住语音键。")
        }
    }

    func stop() { sink.stop() }
}
