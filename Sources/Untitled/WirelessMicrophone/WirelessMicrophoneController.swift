import AppKit
import Combine
import CryptoKit
import Foundation
import Network

@MainActor final class WirelessMicrophoneController: ObservableObject {
    static let pluginID = "com.untitled.wireless-microphone"
    nonisolated static let port: UInt16 = 48480
    static let serviceType = "_untitled-mic._tcp"

    enum Connection: Equatable {
        case stopped, opening, listening, connecting, paired(String)
    }

    @Published private(set) var connection: Connection = .stopped
    @Published private(set) var connectionIssue: String?
    @Published private(set) var peers: [SharingTransport.Peer] = []
    @Published private(set) var inputs: [SharingAudioDevice] = []
    @Published private(set) var inputUID: String
    @Published private(set) var virtualInputName: String?
    @Published private(set) var sendEnabled = false
    @Published private(set) var receiveEnabled = false
    @Published private(set) var isSending = false
    @Published private(set) var isReceiving = false
    @Published private(set) var sendIssue: String?
    @Published private(set) var receiveIssue: String?
    @Published private(set) var demandSent = false

    var isRunning: Bool { connection != .stopped }
    var isPaired: Bool {
        if case .paired = connection { return true }
        return false
    }
    var listeningPort: UInt16? { transport.port?.rawValue }
    var isAllowed: () -> Bool = { false }
    var requireMicrophone: () throws -> Void = { throw PluginError.invalid("请先启用无线麦。") }

    private let transport = SharingTransport(serviceType: WirelessMicrophoneController.serviceType,
                                             servicePort: WirelessMicrophoneController.port)
    private let audio: any WirelessMicrophoneAudio
    private let defaults: UserDefaults
    private let inputPreference: String
    private let keychainService: String
    private let credentials: CredentialBackend
    private let deviceID = UUID()
    private let deviceName = String((Host.current().localizedName ?? "Mac").prefix(80))
    private var lifecycle: [AnyCancellable] = []
    private var heartbeatTimer: Timer?
    private var captureTimer: Timer?
    private var lastHeartbeat: ContinuousClock.Instant?
    private var lastAudio: ContinuousClock.Instant?
    private var peerDemand = false
    private var peerSending = false

    init(pluginID: String, defaults: UserDefaults, audio: any WirelessMicrophoneAudio = CoreAudioWirelessMicrophone(),
         credentials: CredentialBackend = .system) {
        self.audio = audio
        self.defaults = defaults
        self.credentials = credentials
        keychainService = HostInfo.bundleIdentifier + ".wireless-microphone." + pluginID
        inputPreference = "wirelessMicrophone." + pluginID + ".inputUID"
        inputUID = defaults.string(forKey: inputPreference) ?? ""
        transport.listening = { [weak self] _ in
            guard let self, self.connection == .opening else { return }
            self.connection = .listening
        }
        transport.peersChanged = { [weak self] in self?.peers = Array($0.prefix(32)) }
        transport.connected = { [weak self] in self?.beginHandshake() }
        transport.received = { [weak self] in self?.receive($0) }
        transport.disconnected = { [weak self] issue in
            guard let self else { return }
            self.releasePeer()
            self.connection = self.listeningPort == nil ? .opening : .listening
            self.connectionIssue = issue
        }
        transport.failed = { [weak self] in self?.stop(reason: $0) }
    }

    func pairingKey() throws -> String? {
        try AppCredentials.read(service: keychainService, account: "pairing-v1", backend: credentials)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func savePairingKey(_ value: String) throws {
        guard isAllowed(), !isRunning else { throw PluginError.invalid("请启用无线麦并停止连接，再更换配对码。") }
        _ = try SharingPairingKey.decode(value)
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try AppCredentials.save(Data(key.utf8), service: keychainService, account: "pairing-v1", backend: credentials)
    }

    func forgetPairing() throws {
        stop()
        try AppCredentials.delete(service: keychainService, account: "pairing-v1", backend: credentials)
    }

    // Domain separation also rejects cross-service connections when the user reuses a pairing code.
    nonisolated static func transportKey(for code: String) throws -> Data {
        let secret = try SharingPairingKey.decode(code)
        return Data(HMAC<SHA256>.authenticationCode(for: Data("Untitled Wireless Microphone v1".utf8),
                                                    using: SymmetricKey(data: secret)))
    }

    func start(localOnly: Bool = false) throws {
        guard isAllowed() else { throw PluginError.invalid("请先安装并启用无线麦。") }
        guard !isRunning else { return }
        guard let code = try pairingKey() else { throw PluginError.invalid("请在两台 Mac 的「配对设备」中保存同一配对码。") }
        let key = try Self.transportKey(for: code)
        do {
            try transport.start(key: key, name: "\(deviceName) · \(deviceID.uuidString.prefix(6))", localOnly: localOnly)
        } catch {
            transport.stop()
            throw error
        }
        connectionIssue = nil
        connection = .opening
        observeSessionEnd()
    }

    func connect(host: String, port: UInt16 = WirelessMicrophoneController.port) throws {
        try connect(SharingManualEndpoint.parse(host: host, port: String(port)))
    }

    func connect(_ endpoint: NWEndpoint) throws {
        guard isAllowed(), connection == .listening else { throw PluginError.invalid("请先启动无线麦并等待连接就绪。") }
        try transport.connect(endpoint)
        connectionIssue = nil
        connection = .connecting
    }

    func disconnect() { transport.disconnect() }

    func stop(reason: String? = nil) {
        releasePeer()
        lifecycle.removeAll()
        transport.stop()
        connection = .stopped
        connectionIssue = reason
    }

    func refreshDevices() {
        inputs = audio.listInputs()
        if receiveEnabled { updateReceiveDemand() }
        else { _ = currentVirtualInput() }
    }

    func selectInput(_ uid: String) {
        guard uid != inputUID, uid.isEmpty || inputs.contains(where: { $0.id == uid }) else { return }
        // Require a fresh send action before switching a live physical input.
        setSending(false)
        inputUID = uid
        defaults.set(uid, forKey: inputPreference)
    }

    func setSending(_ enabled: Bool) {
        guard !enabled || (isPaired && canUsePeer()) else { return }
        sendIssue = nil
        sendEnabled = enabled
        updateCapture()
    }

    func setReceiving(_ enabled: Bool) {
        guard !enabled || (isPaired && canUsePeer()) else { return }
        receiveIssue = nil
        receiveEnabled = enabled
        if enabled { updateReceiveDemand() }
        else { setDemand(false) }
    }

    private func observeSessionEnd() {
        let workspace = NSWorkspace.shared.notificationCenter
        let notifications = [workspace.publisher(for: NSWorkspace.willSleepNotification),
                             workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification),
                             DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))]
        lifecycle = notifications.map { publisher in
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(reason: "Mac 已睡眠或锁定。请手动重新启动无线麦。") }
            }
        }
    }

    private func beginHandshake() {
        guard isRunning, isAllowed() else { stop(); return }
        connection = .connecting
        lastHeartbeat = ContinuousClock.now
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        transport.send(.init(kind: .hello, version: 1, deviceID: deviceID.uuidString, name: deviceName))
    }

    private func releasePeer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lastHeartbeat = nil
        stopCapture(announce: false)
        stopOutput()
        sendEnabled = false
        receiveEnabled = false
        sendIssue = nil
        receiveIssue = nil
        demandSent = false
        peerDemand = false
        peerSending = false
    }

    private func canUsePeer() -> Bool {
        guard isAllowed() else { stop(); return false }
        guard let lastHeartbeat else { return false }
        guard ContinuousClock.now - lastHeartbeat < .seconds(5) else {
            rejectPeer("对端连接超时。请重新连接。")
            return false
        }
        return true
    }

    private func rejectPeer(_ reason: String) {
        transport.disconnect()
        connectionIssue = reason
    }

    private func receive(_ message: SharingMessage) {
        guard canUsePeer() else { return }
        if !isPaired {
            guard message.kind == .hello, message.deviceID != deviceID.uuidString, let name = message.name else {
                rejectPeer("对端身份无效或尚未完成无线麦握手。")
                return
            }
            lastHeartbeat = ContinuousClock.now
            connection = .paired(name)
            return
        }
        switch message.kind {
        case .ping:
            lastHeartbeat = ContinuousClock.now
        case .micDemand:
            peerDemand = message.enabled == true
            updateCapture()
        case .micState:
            peerSending = message.enabled == true
            if !peerSending { stopOutput() }
        case .audio:
            guard receiveEnabled, demandSent, peerSending, let data = message.audio else { return }
            playReceivedAudio(data)
        default:
            rejectPeer("对端发送了无线麦不支持的消息，已断开。")
        }
    }

    private func heartbeat() {
        guard canUsePeer(), isPaired, transport.send(.init(kind: .ping)) else { return }
        if isSending && !audio.captureIsHealthy {
            failCapture("麦克风权限或设备已不可用。检查后请重新开启发送。")
        }
        if receiveEnabled { updateReceiveDemand() }
    }

    private func updateCapture() {
        guard sendEnabled, peerDemand else { stopCapture(); return }
        guard !isSending, canUsePeer() else { return }
        do {
            try requireMicrophone()
            try audio.startCapture(uid: inputUID)
        } catch {
            failCapture(error.localizedDescription)
            return
        }
        isSending = true
        lastAudio = ContinuousClock.now
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendAudio() }
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        transport.send(.init(kind: .micState, enabled: true))
    }

    private func sendAudio() {
        guard isSending, canUsePeer() else { return }
        let packets = audio.drainCapture()
        if !packets.isEmpty { lastAudio = ContinuousClock.now }
        if let lastAudio, ContinuousClock.now - lastAudio >= .seconds(2) {
            failCapture("麦克风未返回音频。检查设备后请重新开启发送。")
            return
        }
        for packet in packets {
            guard isSending else { break }
            transport.send(.init(kind: .audio, audio: packet), ifAllowed: { self.isSending && self.canUsePeer() })
        }
    }

    private func failCapture(_ issue: String) {
        sendEnabled = false
        sendIssue = issue
        stopCapture()
    }

    private func stopCapture(announce: Bool = true) {
        guard isSending else { return }
        isSending = false
        captureTimer?.invalidate()
        captureTimer = nil
        lastAudio = nil
        audio.stopCapture()
        if announce { transport.send(.init(kind: .micState, enabled: false)) }
    }

    private func currentVirtualInput() -> WirelessMicrophoneVirtualInput? {
        let input = audio.virtualInput()
        if virtualInputName != input?.name { virtualInputName = input?.name }
        return input
    }

    private func updateReceiveDemand() {
        guard let input = currentVirtualInput() else {
            failOutput("接收端需要先安装虚拟麦克风。")
            return
        }
        if isReceiving && !audio.outputIsHealthy {
            failOutput("虚拟麦克风路由已变化。检查后请重新开启接收。")
            return
        }
        setDemand(input.isInUse)
    }

    private func setDemand(_ demand: Bool) {
        guard demandSent != demand else { return }
        demandSent = demand
        if !demand { stopOutput() }
        transport.send(.init(kind: .micDemand, enabled: demand))
    }

    private func playReceivedAudio(_ data: Data) {
        if !isReceiving {
            do { try audio.startOutput() }
            catch { failOutput(error.localizedDescription); return }
            isReceiving = true
        }
        audio.appendOutput(data)
    }

    private func failOutput(_ issue: String) {
        receiveEnabled = false
        receiveIssue = issue
        setDemand(false)
    }

    private func stopOutput() {
        guard isReceiving else { return }
        isReceiving = false
        audio.stopOutput()
    }
}
