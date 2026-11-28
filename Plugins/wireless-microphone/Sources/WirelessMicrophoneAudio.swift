import AVFoundation
import CoreAudio
import Foundation

struct WirelessMicrophoneVirtualInput {
    let name: String
    let isInUse: Bool
}

/// The audio boundary keeps session tests independent of TCC, physical input and HAL drivers.
@MainActor protocol WirelessMicrophoneAudio {
    func listInputs() -> [SharingAudioDevice]
    func virtualInput() -> WirelessMicrophoneVirtualInput?
    var captureIsHealthy: Bool { get }
    func startCapture(uid: String) throws
    func drainCapture() -> [Data]
    func stopCapture()
    var outputIsHealthy: Bool { get }
    func startOutput() throws
    func appendOutput(_ data: Data)
    func stopOutput()
}

@MainActor final class CoreAudioWirelessMicrophone: WirelessMicrophoneAudio {
    private let capture = SharingMicrophoneCapture()
    private let output = SharingMicrophoneSink()

    func listInputs() -> [SharingAudioDevice] { SharingAudioDevices.hardwareInputs() }

    func virtualInput() -> WirelessMicrophoneVirtualInput? {
        guard let input = SharingAudioDevices.device(SharingAudioDevices.inputUID),
              SharingAudioDevices.device(SharingAudioDevices.feedUID) != nil else { return nil }
        return .init(name: input.name, isInUse: SharingAudioDevices.number(
            input.objectID, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)
    }

    var captureIsHealthy: Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              capture.isRunning, let uid = capture.deviceUID else { return false }
        return SharingAudioDevices.device(uid) != nil
    }

    func startCapture(uid: String) throws { try capture.start(uid: uid) }
    func drainCapture() -> [Data] { capture.mailbox.drain() }
    func stopCapture() { capture.stop() }

    var outputIsHealthy: Bool { output.isRunning && output.isRoutingToFeed }
    func startOutput() throws { try output.start() }
    func appendOutput(_ data: Data) { output.append(data) }
    func stopOutput() { output.stop() }
}
