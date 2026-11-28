import AppKit
import Combine
import Foundation

@MainActor final class WirelessMicrophoneController: ObservableObject {
    static let pluginID = "com.untitled.wireless-microphone"

    enum Connection: Equatable {
        case idle, discovering, choosing, pairing(String), connecting(String), connected(String)
    }

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var devices: [XiaomiVoiceRemote] = []
    @Published private(set) var pairingCode: XiaomiRemotePairingCode?
    @Published private(set) var issue: String?
    @Published private(set) var outputIssue: String?
    @Published private(set) var inputName: String?
    @Published private(set) var isTalking = false
    @Published private(set) var level: Double = 0

    var isRunning: Bool { connection != .idle }
    var isAllowed: () -> Bool = { false }
    var requireBluetooth: () throws -> Void = { throw PluginError.invalid("请先启用无线麦。") }

    private let link: any XiaomiRemoteLink
    private let output: any WirelessMicrophoneAudio
    private var connectionDeadline: Task<Void, Never>?
    private var voiceWatchdog: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var lifecycle: [AnyCancellable] = []
    private var frameBytes: Int?
    private var streamID: UInt8?
    private var decoder: XiaomiVoiceDecoder?
    private var initialSync: (predictor: Int16, step: Int, time: ContinuousClock.Instant)?
    private var lastPacket: ContinuousClock.Instant?
    private var lastLevel: ContinuousClock.Instant?
    private var peak = 0
    private var shouldFeed = false

    init(link: any XiaomiRemoteLink = XiaomiRemoteBluetooth(), output: any WirelessMicrophoneAudio = CoreAudioWirelessMicrophone()) {
        self.link = link
        self.output = output
        link.onEvent = { [weak self] event in self?.receive(event) }
    }

    func discover() throws {
        guard isAllowed() else { throw PluginError.invalid("请先安装并启用无线麦。") }
        guard connection == .idle || connection == .choosing else { return }
        try requireBluetooth()
        issue = nil
        connection = .discovering
        if lifecycle.isEmpty { observeSessionEnd() }
        scheduleConnectionDeadline(after: .seconds(20)) { controller in
            controller.link.stopDiscovery()
            controller.connection = .choosing
        }
        link.discover()
    }

    func connect(_ id: UUID) throws {
        guard isAllowed(), connection == .discovering || connection == .choosing,
              let device = devices.first(where: { $0.id == id }) else { return }
        try requireBluetooth()
        issue = nil
        if device.needsPairing {
            connection = .pairing(device.name)
            scheduleConnectionDeadline(after: .seconds(35)) { controller in
                controller.stop(reason: "配对超时。请让遥控器重新进入配对模式再重试。")
            }
        } else {
            connectVoice(named: device.name)
        }
        do { try link.connect(id) }
        catch { stop(); throw error }
    }

    func confirmPairingCode(_ confirmed: Bool) throws {
        guard isAllowed(), case .pairing = connection, case .compare = pairingCode else { return }
        try requireBluetooth()
        link.confirmPairingCode(confirmed)
        pairingCode = nil
        if !confirmed { stop() }
    }

    private func connectVoice(named name: String) {
        pairingCode = nil
        connection = .connecting(name)
        scheduleConnectionDeadline(after: .seconds(20)) { controller in
            controller.stop(reason: "连接或语音协商超时。请唤醒遥控器后重新查找。")
        }
    }

    func stop(reason: String? = nil) {
        connectionDeadline?.cancel()
        connectionDeadline = nil
        closeRemoteStream()
        endVoice(drain: false)
        link.stop()
        lifecycle.removeAll()
        frameBytes = nil
        devices = []
        pairingCode = nil
        connection = .idle
        issue = reason
        outputIssue = nil
    }

    func refreshAudioDevice() {
        let name = output.inputName
        if inputName != name { inputName = name }
        outputIssue = nil
    }

    private func receive(_ event: XiaomiRemoteLinkEvent) {
        guard isRunning else { return }
        guard isAllowed() else { stop(); return }
        switch event {
        case .devices(let devices):
            if connection == .discovering { self.devices = devices }
        case .pairingCode(let code):
            if case .pairing = connection { pairingCode = code }
        case .connectingVoice:
            if case .pairing(let name) = connection { connectVoice(named: name) }
        case .choosePairedRemote(let devices, let message):
            guard case .pairing = connection else { return }
            connectionDeadline?.cancel()
            connectionDeadline = nil
            pairingCode = nil
            self.devices = devices
            issue = message
            connection = .choosing
        case .subscribed:
            guard case .connecting = connection else { return }
            do { try link.send(XiaomiRemoteVoice.getCapabilities) }
            catch { stop(reason: error.localizedDescription) }
        case .control(let data):
            guard let control = XiaomiRemoteVoice.control(data) else { return }
            handleControl(control)
        case .audio(let data):
            receiveAudio(data)
        case .failed(let message):
            stop(reason: message)
        }
    }

    private func handleControl(_ event: XiaomiRemoteVoice.Event) {
        switch event {
        case .capabilities(let size):
            guard case .connecting(let name) = connection else { return }
            connectionDeadline?.cancel()
            connectionDeadline = nil
            frameBytes = size
            connection = .connected(name)
            refreshAudioDevice()
        case .incompatibleCapabilities:
            if case .connecting = connection { stop(reason: "遥控器语音格式不兼容。请使用小米蓝牙遥控器 2 或 2 Pro。") }
        case .start(let reason, let codec, let stream):
            guard case .connected = connection, let frameBytes, streamID != stream else { return }
            // A remote-initiated hold starts with reason 0x03. Never open the mic from the Mac.
            guard reason == 0x03, codec == XiaomiRemoteVoice.codec16k, (1...0x80).contains(stream) else {
                try? link.send(XiaomiRemoteVoice.close(stream: stream))
                endVoice(drain: false)
                issue = "遥控器未进入按住说话模式。请重新连接后再试。"
                return
            }
            beginVoice(stream: stream, frameBytes: frameBytes)
        case .stop:
            endVoice(drain: true)
        case .sync(let codec, let predictor, let step):
            guard case .connected = connection else { return }
            guard codec == XiaomiRemoteVoice.codec16k else {
                if streamID != nil { interruptVoice("遥控器更改了音频格式。请松开并重新按住语音键。") }
                return
            }
            if streamID != nil {
                decoder?.synchronize(predictor: predictor, step: step)
            } else {
                initialSync = (predictor, step, .now)
            }
        }
    }

    private func beginVoice(stream: UInt8, frameBytes: Int) {
        let sync = initialSync
        endVoice(drain: true)
        drainTask?.cancel()
        drainTask = nil
        let now = ContinuousClock.now
        var decoder = XiaomiVoiceDecoder(frameBytes: frameBytes)
        if let sync, now - sync.time < .seconds(1) {
            decoder.synchronize(predictor: sync.predictor, step: sync.step)
        }
        self.decoder = decoder
        streamID = stream
        lastPacket = now
        lastLevel = nil
        issue = nil
        refreshAudioDevice()
        shouldFeed = inputName != nil
        if !shouldFeed { output.stop() }
        isTalking = true

        voiceWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self, let lastPacket = self.lastPacket else { return }
                let tick = ContinuousClock.now
                if tick - lastPacket >= .seconds(2) || tick - now >= .seconds(65) {
                    self.interruptVoice("语音已停止。请松开并重新按住遥控器语音键。")
                    return
                }
            }
        }
    }

    private func receiveAudio(_ data: Data) {
        guard streamID != nil, !data.isEmpty, data.count <= 512 else { return }
        lastPacket = .now
        guard let samples = decoder?.append(data), !samples.isEmpty else { return }
        for sample in samples { peak = max(peak, abs(Int(sample))) }
        let now = ContinuousClock.now
        if lastLevel.map({ now - $0 >= .milliseconds(100) }) ?? true {
            level = Double(peak) / 32_768
            peak = 0
            lastLevel = now
        }
        guard shouldFeed else { return }
        do {
            if !output.isRunning { try output.start() }
            try output.append(samples)
        } catch {
            shouldFeed = false
            output.stop()
            outputIssue = error.localizedDescription
        }
    }

    private func interruptVoice(_ message: String) {
        closeRemoteStream()
        endVoice(drain: false)
        issue = message
    }

    private func closeRemoteStream() {
        if let streamID { try? link.send(XiaomiRemoteVoice.close(stream: streamID)) }
    }

    private func endVoice(drain: Bool) {
        let wasTalking = streamID != nil
        voiceWatchdog?.cancel()
        voiceWatchdog = nil
        streamID = nil
        decoder = nil
        initialSync = nil
        lastPacket = nil
        lastLevel = nil
        peak = 0
        shouldFeed = false
        if wasTalking {
            isTalking = false
            level = 0
        }
        if drain, output.hasQueuedAudio {
            // A short utterance can still have its entire PCM payload in the playback queue at release.
            guard drainTask == nil else { return }
            drainTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(260)) }
                catch { return }
                self?.output.stop()
                self?.drainTask = nil
            }
        } else {
            drainTask?.cancel()
            drainTask = nil
            output.stop()
        }
    }

    private func scheduleConnectionDeadline(after duration: Duration, action: @escaping (WirelessMicrophoneController) -> Void) {
        connectionDeadline?.cancel()
        connectionDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) }
            catch { return }
            guard let self else { return }
            self.connectionDeadline = nil
            action(self)
        }
    }

    private func observeSessionEnd() {
        let center = NSWorkspace.shared.notificationCenter
        let notifications = [center.publisher(for: NSWorkspace.willSleepNotification),
                             center.publisher(for: NSWorkspace.sessionDidResignActiveNotification),
                             DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))]
        lifecycle = notifications.map { publisher in
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(reason: "Mac 已睡眠或锁定。解锁后请重新连接遥控器。") }
            }
        }
    }
}
