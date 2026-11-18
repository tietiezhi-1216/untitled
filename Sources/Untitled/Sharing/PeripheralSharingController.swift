import AppKit
import AVFoundation
import Carbon
import Combine
import Foundation
import Network
@preconcurrency import ApplicationServices

/// Independent retry budgets for the tap and transport, driven by the existing
/// session timer. One outstanding attempt; outages never exhaust user intent.
private struct SharingRetry {
    private static let delays: [TimeInterval] = [0.5, 1, 2, 4, 5]
    private var step = 0
    private(set) var next = -Double.infinity
    mutating func deferAfterAttempt(at now: TimeInterval) {
        next = now + Self.delays[step]
        step = min(step + 1, Self.delays.count - 1)
    }
}

@MainActor final class PeripheralSharingController: ObservableObject {
    static let pluginID = "com.untitled.peripheral-sharing"
    enum ControlState: String { case local = "本机", requesting = "等待对端", preparing = "准备接收", returning = "正在归还", controlling = "控制远端", receiving = "由远端控制" }
    @Published private(set) var isRunning = false
    @Published private(set) var peers: [SharingTransport.Peer] = []
    @Published private(set) var peerName: String?
    @Published private(set) var rememberedPeerName: String?
    @Published private(set) var peerSupportsLayoutSync = false
    @Published private(set) var peerSupportsFreeLayout = false
    @Published private(set) var layoutReady = false
    @Published private(set) var layoutOffset: SharingLayoutPoint
    @Published private(set) var layoutStamp: SharingLayoutStamp
    @Published private(set) var localAspect: Double
    @Published private(set) var peerAspect: Double
    @Published private(set) var localPixels: SharingScreenPixels?
    @Published private(set) var peerPixels: SharingScreenPixels?
    private var legacyLayoutOffset: SharingLayoutPoint?
    @Published private(set) var control: ControlState = .local
    @Published private(set) var keyboardMouseEnabled = false
    @Published private(set) var inputRecovering = false
    @Published private(set) var peerKeyboardMouseEnabled: Bool?
    @Published private(set) var clipboardStatus: SharingClipboard.Status = .disconnected
    @Published private(set) var peerSupportsClipboardImages = false
    @Published private(set) var clipboardImageStatus: SharingClipboardImageStatus = .inactive
    @Published private(set) var inputStatus: String?
    @Published private(set) var isCursorDiagnostic = false
    private var diagnosticTimer: Timer?
    private var diagnosticDeadline: UInt64?
    private var diagnosticReportDirectory: URL?
    private var diagnosticForwardAttempts = 0
    @Published private(set) var microphoneOffered = false
    @Published private(set) var wantsRemoteMicrophone = false
    @Published private(set) var isSendingMicrophone = false
    @Published private(set) var isReceivingMicrophone = false
    @Published private(set) var remoteMicrophoneAvailable = false
    @Published private(set) var audioDevices: [SharingAudioDevice] = []
    @Published var status = "未启动；安装或启用插件不会自动监听网络。"
    @Published var microphoneStatus = "麦克风共享已关闭"
    @Published var edge: SharingEdge { didSet { defaults.set(edge.rawValue, forKey: "sharing.edge"); input.edge = edge } }
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "sharing.microphoneUID"); stopCapture(); captureAttempted = false } }
    var requirePermissions: (Set<HostPermissionID>) throws -> Void = { _ in throw PluginError.invalid("请先启用外设共享插件。") }
    var isAllowed: () -> Bool = { false }
    var reportError: (Error) -> Void = { _ in }
    let transport = SharingTransport()
    #if DEBUG
    var acceptanceAllowsInput: (() -> Bool)?
    var acceptanceMicrophoneStatistics: [String: Any] { capture.mailbox.statistics() }
    var acceptanceInputStatistics: [String: Any] {
        ["appliedPackets": input.appliedPacketCount, "replayedEvents": input.replayedEventCount,
         "postEventAccess": CGPreflightPostEventAccess()]
    }
    #endif
    private(set) var sentAudioFrames = 0
    private(set) var receivedAudioFrames = 0
    private(set) var sentInputPackets = 0
    private(set) var receivedInputPackets = 0
    private struct ReconnectTarget {
        var endpoint: NWEndpoint
        var expectedPeer: UUID?
        var startupDeadline: TimeInterval?
        var explicitlySelected = false
    }
    private var userSessionStarted = false // Diagnostics can listen without starting user sharing.
    private var reconnectTarget: ReconnectTarget?
    private var reconnectRetry = SharingRetry()
    private var dialIsAutomatic: Bool? // nil = inbound, false = explicit selection, true = background retry
    private var disconnectHold = false
    private var deferredIncomingHello = false
    @Published private(set) var reconnecting = false
    private var runtimeReporting = false
    private let loadPairingKey: @MainActor () -> String?
    private let inputAccessAvailable: @MainActor () -> Bool
    private let monotonicNow: @MainActor () -> TimeInterval
    private var inputRetry = SharingRetry()
    private var repairRequiresTap = false
    private var keyboardReady: Bool { keyboardMouseEnabled && !inputRecovering }
    private var peerDeviceID: String?
    private var peerSupportsCursorParking = false
    private var peerSupportsContinuousReturn = false
    private var peerSupportsDirectHandoff = false
    private var activeHandoffID: String?
    private var pendingDirectEntry: SharingMessage?
    private var sentHandoffMotion = SharingReturnMotion()
    private var receivedHandoffInputs: UInt64 = 0
    private let input: SharingInput
    private let clipboard: SharingClipboard
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private let capture = SharingMicrophoneCapture()
    private let sink = SharingMicrophoneSink()
    private let defaults: UserDefaults
    private let deviceID: String
    private var timer: Timer?
    private var observers: [AnyCancellable] = []
    private var lastReceived: TimeInterval?
    private var lastTick: TimeInterval = -.infinity
    private var previousTick: TimeInterval?
    private var maximumTickGap: TimeInterval = 0
    private var reconnects = 0
    private var pendingSince: Date?
    private var controlGranted = false
    private var demandSent = false
    private var peerDemand = false
    private var captureAttempted = false
    private var lastMicrophonePacket = Date.distantPast

    init(defaults: UserDefaults = .standard, input: SharingInput = SharingInput(), loadPairingKey: @escaping @MainActor () -> String? = SharingPairingKey.load,
         screenPixels: SharingScreenPixels? = SharingScreenPixels.current,
         inputAccessAvailable: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() && CGPreflightListenEventAccess() && !IsSecureEventInputEnabled() },
         clipboard: SharingClipboard = SharingClipboard(),
         monotonicNow: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults; self.input = input; self.loadPairingKey = loadPairingKey; self.inputAccessAvailable = inputAccessAvailable
        self.clipboard = clipboard; self.monotonicNow = monotonicNow
        rememberedPeerName = defaults.string(forKey: "sharing.lastPeerName")
        disconnectHold = defaults.bool(forKey: "sharing.disconnectHold")
        let savedEdge = SharingEdge(rawValue: defaults.string(forKey: "sharing.edge") ?? "right") ?? .right
        edge = savedEdge
        microphoneUID = defaults.string(forKey: "sharing.microphoneUID") ?? ""
        let identity = defaults.string(forKey: "sharing.deviceID") ?? UUID().uuidString
        deviceID = identity; defaults.set(identity, forKey: "sharing.deviceID")
        let ownPixels = screenPixels.flatMap { (try? $0.validate()) != nil ? $0 : nil }
        localPixels = ownPixels
        let ownAspect = ownPixels?.aspect ?? Self.activeDisplayAspect
        localAspect = ownAspect
        let savedPixels = defaults.data(forKey: "sharing.peerPixels").flatMap { try? JSONDecoder().decode(SharingScreenPixels.self, from: $0) }.flatMap { (try? $0.validate()) != nil ? $0 : nil }
        peerPixels = savedPixels
        let savedAspect = defaults.double(forKey: "sharing.peerAspect")
        let otherAspect = savedPixels?.aspect ?? ((0.1...10).contains(savedAspect) ? savedAspect : ownAspect)
        peerAspect = otherAspect
        let pixelsOffset = defaults.data(forKey: "sharing.pixelLayoutOffset").flatMap { try? JSONDecoder().decode(SharingLayoutPoint.self, from: $0) }.flatMap { (try? $0.validate()) != nil ? $0 : nil }
        let oldOffset = defaults.data(forKey: "sharing.layoutOffset").flatMap { try? JSONDecoder().decode(SharingLayoutPoint.self, from: $0) }.flatMap { (try? $0.validate()) != nil ? $0 : nil }
            ?? SharingDisplayLayout.touching(savedEdge, localAspect: ownAspect, peerAspect: otherAspect)
        legacyLayoutOffset = pixelsOffset == nil ? oldOffset : nil
        let geometry = SharingDisplayLayout(peerOffset: .zero, localAspect: ownAspect, peerAspect: otherAspect, localPixels: ownPixels, peerPixels: savedPixels)
        layoutOffset = pixelsOffset ?? geometry.offsetFromLegacyUnits(oldOffset)
        layoutStamp = defaults.data(forKey: "sharing.layoutStamp").flatMap { try? JSONDecoder().decode(SharingLayoutStamp.self, from: $0) }.flatMap { (try? $0.validate()) != nil ? $0 : nil }
            ?? SharingLayoutStamp(counter: (defaults.string(forKey: "sharing.lastPeerHost")?.isEmpty == false ? 1 : 0), author: identity)
        input.edge = edge
        input.send = { [weak self] packet in
            guard let self else { return }
            if self.isCursorDiagnostic { self.diagnosticForwardAttempts += 1; return } // Never emit .input during diagnosis.
            guard self.isRunning, self.keyboardReady, self.control == .controlling, self.input.isCapturing else { return }
            if self.transport.send(.init(kind: .input, input: packet, handoffID: self.activeHandoffID), ifAllowed: { self.input.isCapturing && self.control == .controlling && !self.isCursorDiagnostic }) {
                self.sentInputPackets += 1
                if self.peerSupportsContinuousReturn { self.sentHandoffMotion.record(packet) }
            }
        }
        input.requestControl = { [weak self] direction, fraction in self?.requestControl(fraction: fraction, direction: direction) }
        input.returnLocal = { [weak self] position in self?.returnToLocal(at: position) }
        input.returnAcrossEdge = { [weak self] position in self?.returnAcrossEdge(at: position) }
        input.localResumed = { [weak self] in
            guard let self else { return }
            self.input.canSwitch = self.canStartControl
        }
        input.failure = { [weak self] message in self?.handleInputFailure(message) }
        input.captureInterrupted = { [weak self] interruption in self?.recoverInterruptedInput(interruption) }
        input.physicalStateChanged = { [weak self] in
            // Finish delivery of the local key/button-up before changing the tap's routing.
            DispatchQueue.main.async { [weak self] in self?.activateControlWhenNeutral() }
        }
        clipboard.changed = { [weak self] in self?.clipboardStatus = $0 }
        clipboard.isAuthorized = { [weak self] in
            guard let self else { return false }
            return self.userSessionStarted && self.isRunning && self.keyboardMouseEnabled && self.isAllowed()
                && self.peerName != nil && self.transport.isConnected
        }
        clipboard.canSendText = { [weak self] in self?.transport.canSendClipboardText == true }
        clipboard.send = { [weak self] in self?.transport.send($0) == true }
        clipboard.configureImages = { [weak self] in self?.transport.setClipboardImageGrants($0) }
        clipboard.sendImage = { [weak self] data, revision in self?.transport.offerClipboardImage(data, revision: revision) }
        clipboard.discardPendingImage = { [weak self] in self?.transport.discardPendingClipboardImage() }
        transport.beginClipboardImage = { [weak self] revision in self?.clipboard.beginImage(revision: revision) }
        transport.clipboardImageStatusChanged = { [weak self] status in
            if self?.clipboardImageStatus != status { self?.clipboardImageStatus = status }
        }
        transport.peersChanged = { [weak self] in self?.peers = $0 }
        transport.listening = { [weak self] port in
            guard let self else { return }
            self.status = "正在监听 TCP \(port)；可自动发现同网段设备，或按 IP / VPN 地址连接。"
            self.tryReconnect(at: self.monotonicNow())
        }
        transport.failed = { [weak self] in self?.stop(reason: $0) }
        transport.connected = { [weak self] in
            guard let self else { return }
            self.lastReceived = self.monotonicNow(); self.status = "已加密连接，正在确认对端…"
            // The dialer speaks first; a rejected background dial must not
            // see a successful hello, even when its TLS-PSK is valid.
            self.deferredIncomingHello = self.dialIsAutomatic == nil
            if !self.deferredIncomingHello { self.sendHello() }
        }
        transport.received = { [weak self] in self?.receive($0) }
        transport.disconnected = { [weak self] reason in
            guard let self else { return }
            self.connectionLost(reason: reason)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.stopUserSession(reason: "设备睡眠或会话已锁定，共享已停止。") }
            })
        }
        observers.append(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let pixels = SharingScreenPixels.current, aspect = pixels?.aspect ?? Self.activeDisplayAspect
                guard pixels != self.localPixels || abs(aspect - self.localAspect) > 0.0001 else { return }
                self.returnToLocal()
                let old = self.workspace, offset = self.layoutOffset
                self.localPixels = pixels; self.localAspect = aspect
                let next = self.workspace
                self.setLayoutOffset(.init(x: offset.x * Double(next.localRect.width + next.peerRect.width) / Double(old.localRect.width + old.peerRect.width),
                                           y: offset.y * Double(next.localRect.height + next.peerRect.height) / Double(old.localRect.height + old.peerRect.height)))
            }
        })
        observers.append(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked")).sink { [weak self] _ in
            Task { @MainActor in self?.stopUserSession(reason: "锁屏后共享已停止；解锁后请手动启动。") }
        })
    }
    var hasDriver: Bool { SharingAudioDevices.device(SharingAudioDevices.inputUID) != nil && SharingAudioDevices.device(SharingAudioDevices.feedUID) != nil }
    var serviceName: String { "\(Host.current().localizedName ?? "Mac") · \(deviceID.prefix(6))" }
    func refreshDevices() { audioDevices = SharingAudioDevices.hardwareInputs(); objectWillChange.send() }
    func start(key: String? = nil, localOnly: Bool = false, listenPort: UInt16? = nil) throws {
        guard !isCursorDiagnostic else { throw PluginError.invalid("请先结束本机接管测试。") }
        guard isAllowed() else { throw PluginError.invalid("请先安装并启用外设共享插件。") }
        guard !isRunning else { return }
        guard let key = key ?? loadPairingKey() else { throw PluginError.invalid("请先生成配对密钥，并在另一台 Mac 中粘贴同一密钥。") }
        try transport.start(key: SharingPairingKey.decode(key), name: serviceName, localOnly: localOnly, listenPort: listenPort)
        isRunning = true; lastTick = -.infinity; previousTick = nil
        maximumTickGap = 0; reconnects = 0
        status = "正在发现局域网设备；仅接受持有同一密钥的对端。"
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    /// A prior explicit Start can be resumed on ordinary app relaunch. Installation,
    /// plugin enablement and lock/sleep never create that intent.
    func startUserSession(localOnly: Bool = false) throws {
        try beginUserSession(localOnly: localOnly, explicit: true)
    }
    private func beginUserSession(localOnly: Bool, explicit: Bool) throws {
        try start(localOnly: localOnly)
        runtimeReporting = !localOnly
        do { try setKeyboardMouse(true) }
        catch { stop(reason: "共享未开启：" + error.localizedDescription); throw error }
        if explicit { setDisconnectHold(false) }
        if !userSessionStarted, !disconnectHold, peerName == nil { loadReconnectTarget() }
        userSessionStarted = true
        defaults.set(true, forKey: "sharing.sessionEnabled")
        clipboard.refreshAuthorization()
    }
    func restoreUserSessionIfRequested(localOnly: Bool = false) throws {
        guard defaults.bool(forKey: "sharing.sessionEnabled"), isAllowed() else { return }
        try beginUserSession(localOnly: localOnly, explicit: false)
    }
    func stopUserSession(reason: String = "共享已关闭。") {
        defaults.set(false, forKey: "sharing.sessionEnabled"); stop(reason: reason)
    }
    private func loadReconnectTarget() {
        guard reconnectTarget == nil, !defaults.bool(forKey: "sharing.reconnectPassive") else { return }
        let endpoint: NWEndpoint?
        if let service = defaults.string(forKey: "sharing.reconnectService"), !service.isEmpty {
            endpoint = .service(name: service, type: SharingTransport.serviceType,
                                domain: defaults.string(forKey: "sharing.reconnectDomain") ?? "local.", interface: nil)
        } else if let host = defaults.string(forKey: "sharing.lastPeerHost"), !host.isEmpty {
            endpoint = try? SharingManualEndpoint.parse(host: host, port: defaults.string(forKey: "sharing.lastPeerPort") ?? String(SharingTransport.defaultPort))
        } else { endpoint = nil }
        guard let endpoint else { return }
        let id = defaults.string(forKey: "sharing.reconnectPeerID").flatMap(UUID.init(uuidString:))
        reconnectTarget = .init(endpoint: endpoint, expectedPeer: id, startupDeadline: id == nil ? monotonicNow() + 120 : nil)
    }
    private func saveReconnectTarget(_ target: ReconnectTarget) {
        switch target.endpoint {
        case .hostPort(let host, let port):
            defaults.set("\(host)", forKey: "sharing.lastPeerHost")
            defaults.set(String(port.rawValue), forKey: "sharing.lastPeerPort")
            defaults.removeObject(forKey: "sharing.reconnectService")
            defaults.removeObject(forKey: "sharing.reconnectDomain")
        case .service(let name, _, let domain, _):
            defaults.set(name, forKey: "sharing.reconnectService")
            defaults.set(domain, forKey: "sharing.reconnectDomain")
        default: return
        }
        defaults.set(false, forKey: "sharing.reconnectPassive")
    }
    private func tryReconnect(at now: TimeInterval) {
        guard userSessionStarted, isRunning, isAllowed(), !disconnectHold, peerName == nil,
              transport.canDial, let target = reconnectTarget, now >= reconnectRetry.next else { return }
        if let deadline = target.startupDeadline, now >= deadline { clearReconnectTarget(); return }
        reconnectRetry.deferAfterAttempt(at: now)
        do {
            try dial(target.endpoint, automatic: !target.explicitlySelected)
            reconnectTarget?.explicitlySelected = false
            status = target.expectedPeer == nil ? "正在连接配对设备…" : "正在重新连接原配对设备…"
        } catch { /* A busy or unavailable transport consumes at most this retry slot. */ }
    }
    private func dial(_ endpoint: NWEndpoint, automatic: Bool) throws {
        try transport.connect(endpoint)
        dialIsAutomatic = automatic
    }
    private func setDisconnectHold(_ value: Bool) {
        disconnectHold = value
        if userSessionStarted || !value { defaults.set(value, forKey: "sharing.disconnectHold") }
    }
    private func clearReconnectTarget() {
        reconnectTarget = nil; reconnectRetry = SharingRetry()
        if reconnecting { reconnecting = false }
    }
    private func connectionLost(reason: String?) {
        let wasReady = peerName != nil
        dialIsAutomatic = nil; deferredIncomingHello = false
        clearSession()
        if userSessionStarted, !disconnectHold, let target = reconnectTarget, target.expectedPeer != nil {
            if wasReady {
                reconnectRetry = SharingRetry()
                reconnects = min(reconnects + 1, 1_000_000_000)
            }
            reconnecting = true
            status = "连接中断，正在后台重连。"
        } else {
            if wasReady, userSessionStarted, !disconnectHold { reconnecting = true }
            status = reason ?? (reconnecting ? "连接中断，等待原配对设备重连。" : (isRunning ? "等待对端连接" : "已停止"))
        }
    }
    private func sendHello() {
        transport.send(.init(kind: .hello, version: 1, deviceID: deviceID, name: String((Host.current().localizedName ?? "Mac").prefix(80)), layoutSync: true,
            layoutVersion: localPixels == nil ? nil : 3, screenAspect: localAspect, layoutStamp: layoutStamp, screenPixels: localPixels,
            cursorParking: true, continuousReturn: true, directHandoff: true, keyboardEnabled: keyboardReady,
            automaticReconnect: dialIsAutomatic ?? false, clipboardSync: true, clipboardImages: true))
    }
    func stop(reason: String = "已停止，共享设备与网络监听均已释放。") {
        if isCursorDiagnostic { finishCursorDiagnostic(reason: "已手动结束测试。") }
        userSessionStarted = false; clearReconnectTarget(); dialIsAutomatic = nil; deferredIncomingHello = false
        timer?.invalidate(); timer = nil
        cancelInputRecovery()
        returnToLocal(); transport.stop(); clearSession(); input.stop()
        isRunning = false; keyboardMouseEnabled = false; microphoneOffered = false; wantsRemoteMicrophone = false
        status = reason; writeRuntimeState()
    }
    func connect(_ peer: SharingTransport.Peer) throws {
        guard isRunning, isAllowed() else { throw PluginError.invalid("请先启动共享。") }
        if !keyboardMouseEnabled { try startUserSession() }
        let endpoint: NWEndpoint
        if case .service(let name, let type, let domain, _) = peer.endpoint {
            endpoint = .service(name: name, type: type, domain: domain, interface: nil)
        } else { endpoint = peer.endpoint }
        try connectExplicitly(to: endpoint)
        status = "正在认证 \(peer.name)…"
    }
    func connect(host: String, port: String) throws {
        guard isRunning, isAllowed() else { throw PluginError.invalid("请先启动共享。") }
        try connectExplicitly(to: SharingManualEndpoint.parse(host: host, port: port))
        status = "正在认证 \(host)…"
    }
    private func connectExplicitly(to endpoint: NWEndpoint) throws {
        if peerName == nil, dialIsAutomatic == true {
            clearReconnectTarget()
            transport.disconnect() // Manual selection supersedes a pending background attempt.
        }
        try dial(endpoint, automatic: false)
        setDisconnectHold(false)
        clearReconnectTarget()
        // Only a successful explicit selection may replace a previously trusted route.
        if userSessionStarted { reconnectTarget = .init(endpoint: endpoint, startupDeadline: monotonicNow() + 120) }
    }
    func connectUserSelected(host: String, port: String) throws {
        let endpoint = try SharingManualEndpoint.parse(host: host, port: port)
        try startUserSession()
        if transport.port != nil { try connectExplicitly(to: endpoint) }
        else {
            clearReconnectTarget()
            reconnectTarget = .init(endpoint: endpoint, startupDeadline: monotonicNow() + 120, explicitlySelected: true)
        }
    }
    func disconnect() {
        clearReconnectTarget(); setDisconnectHold(true)
        returnToLocal(); transport.disconnect()
        if isRunning { status = "已主动断开，等待手动连接。" }
    }
    /// A new key is a new pairing. Never carry the previous peer's identity,
    /// route or explicit-disconnect state over to the replacement.
    func forgetReconnectRoute() {
        clearReconnectTarget(); setDisconnectHold(false)
        for key in ["reconnectPeerID", "reconnectService", "reconnectDomain", "reconnectPassive", "lastPeerHost", "lastPeerPort"] {
            defaults.removeObject(forKey: "sharing." + key)
        }
    }
    static var activeDisplayAspect: Double { let bounds = SharingInput.bounds; return bounds.height > 0 ? min(10, max(0.1, Double(bounds.width / bounds.height))) : 1.6 }
    var workspace: SharingDisplayLayout { SharingDisplayLayout(peerOffset: layoutOffset, localAspect: localAspect, peerAspect: peerAspect, localPixels: localPixels, peerPixels: peerPixels) }
    func setLayoutOffset(_ desired: SharingLayoutPoint) {
        guard control == .local, (try? desired.validate()) != nil else { return }
        legacyLayoutOffset = nil
        layoutOffset = workspace.adjusted(desired, magnet: 0)
        layoutStamp = SharingLayoutStamp(counter: min(1_000_000_000_000, layoutStamp.counter + 1), author: deviceID)
        persistLayout(); sendLayout()
    }
    func setLayoutEdge(_ value: SharingEdge) { setLayoutOffset(SharingDisplayLayout.touching(value, localAspect: localAspect, peerAspect: peerAspect, localPixels: localPixels, peerPixels: peerPixels)) }
    private func persistLayout() {
        edge = workspace.primaryEdge
        defaults.set(try? JSONEncoder().encode(layoutOffset), forKey: "sharing.pixelLayoutOffset")
        defaults.set(try? JSONEncoder().encode(layoutStamp), forKey: "sharing.layoutStamp")
        input.workspace = peerSupportsFreeLayout ? workspace : nil
    }
    private func sendLayout() {
        guard peerName != nil, peerSupportsLayoutSync else { return }
        if peerSupportsFreeLayout {
            layoutReady = false; input.canSwitch = false
            transport.send(.init(kind: .layout, edge: edge, layoutVersion: 3, screenAspect: localAspect, layoutOffset: layoutOffset, layoutStamp: layoutStamp, screenPixels: localPixels))
        } else { transport.send(.init(kind: .layout, edge: edge)) }
    }
    private func applyLayout(_ message: SharingMessage) -> Bool {
        guard let offset = message.layoutOffset, let stamp = message.layoutStamp, stamp >= layoutStamp else { return false }
        updatePeerScreen(message)
        let next = SharingDisplayLayout(peerOffset: offset.mirrored, localAspect: localAspect, peerAspect: peerAspect, localPixels: localPixels, peerPixels: peerPixels)
        guard !next.localRect.intersects(next.peerRect) else { return false }
        if stamp == layoutStamp, next.peerOffset != layoutOffset, (peerDeviceID ?? "") < deviceID { sendLayout(); return false }
        legacyLayoutOffset = nil
        layoutOffset = offset.mirrored; layoutStamp = stamp; persistLayout(); return true
    }
    private func updatePeerScreen(_ message: SharingMessage) {
        if message.layoutVersion == 3, let pixels = message.screenPixels {
            peerPixels = pixels; peerAspect = pixels.aspect
            defaults.set(try? JSONEncoder().encode(pixels), forKey: "sharing.peerPixels")
        } else {
            peerPixels = nil; defaults.removeObject(forKey: "sharing.peerPixels")
            if let aspect = message.screenAspect { peerAspect = aspect }
        }
        defaults.set(peerAspect, forKey: "sharing.peerAspect")
    }
    func setKeyboardMouse(_ value: Bool) throws {
        guard isRunning, isAllowed() else { throw PluginError.invalid("请先启动共享。") }
        if value {
            guard !input.needsRecovery else { throw PluginError.invalid("鼠标恢复尚未完成，暂不能重新启用键鼠共享。") }
            try requirePermissions([.accessibility, .inputMonitoring])
            guard !IsSecureEventInputEnabled() else { throw PluginError.invalid("系统正在安全输入模式中，请退出密码输入后重试。") }
            if inputRecovering || !input.tapReady && keyboardMouseEnabled {
                guard input.repairTap() else { throw SharingCursorInterruption.tapLost }
            } else { try input.start() }
            inputStatus = nil
        } else { returnToLocal(); input.stop() }
        cancelInputRecovery()
        keyboardMouseEnabled = value; input.canSwitch = canStartControl
        defaults.set(value, forKey: "sharing.inputDesired")
        if peerName != nil {
            refreshInputStatus()
            transport.send(.init(kind: .ping, keyboardEnabled: value))
            clipboard.refreshAuthorization()
        }
    }
    func shareCopiedScreenshot(_ data: Data, changeCount: Int) {
        clipboard.offerCopiedPNG(data, changeCount: changeCount)
    }
    func setMicrophoneOffered(_ value: Bool) {
        microphoneOffered = value; captureAttempted = false
        if !value { stopCapture() }
        updateMicrophone()
    }
    func setWantsRemoteMicrophone(_ value: Bool) {
        wantsRemoteMicrophone = value
        updateMicrophone()
    }
    func retryMicrophone() { captureAttempted = false; refreshDevices(); updateMicrophone() }
    func toggleControl() {
        if control != .local { returnToLocal() }
        else if peerSupportsFreeLayout, let entry = workspace.defaultEntry { requestControl(fraction: entry.fraction, direction: entry.wireEdge) }
        else { requestControl(fraction: 0.5) }
    }
    private var canStartControl: Bool {
        isRunning && keyboardReady && peerKeyboardMouseEnabled != false && peerName != nil && control == .local && (!peerSupportsFreeLayout || layoutReady)
    }
    private func requestControl(fraction: Double, direction: SharingEdge? = nil) {
        guard peerKeyboardMouseEnabled != false else { refreshInputStatus(); return }
        guard canStartControl, isAllowed(), input.tapReady, captureTask == nil, !input.needsRecovery, !input.transitionPending else { return }
        do { try requirePermissions([.accessibility, .inputMonitoring]) }
        catch { reportError(error); return }
        control = .requesting; pendingSince = Date(); controlGranted = false; input.canSwitch = false
        activeHandoffID = peerSupportsCursorParking ? UUID().uuidString : nil
        sentHandoffMotion = SharingReturnMotion()
        let entry = SharingMessage(kind: .begin, edge: direction ?? edge, position: fraction, handoffID: activeHandoffID)
        if peerSupportsDirectHandoff, peerKeyboardMouseEnabled == true, activeHandoffID != nil {
            var direct = entry
            direct.directEntry = true; direct.layoutStamp = layoutStamp
            pendingDirectEntry = direct
        } else {
            guard transport.send(entry) else { finishLocalInput(); return }
        }
        activateControlWhenNeutral()
    }
    func returnToLocal(at position: SharingCursorPosition? = nil) {
        if isCursorDiagnostic { finishCursorDiagnostic(reason: "已手动结束测试。"); return }
        if control != .local || peerSupportsCursorParking { transport.send(.init(kind: .end, returnPosition: peerSupportsFreeLayout ? position : nil, handoffID: activeHandoffID)) }
        finishLocalInput()
    }
    private func returnAcrossEdge(at position: SharingCursorPosition?) {
        guard peerSupportsCursorParking, control == .receiving, captureTask == nil, let handoff = activeHandoffID else { returnToLocal(at: position); return }
        control = .returning; input.canSwitch = false; pendingSince = Date()
        let afterInput = peerSupportsContinuousReturn && position != nil && receivedHandoffInputs > 0 ? receivedHandoffInputs : nil
        let generation = captureGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            do {
                try await self.input.parkAfterReturn()
                guard generation == self.captureGeneration, !Task.isCancelled, self.control == .returning,
                      self.isRunning, self.keyboardMouseEnabled, self.activeHandoffID == handoff, self.input.isParked else { self.input.reset(); return }
                guard self.transport.send(.init(kind: .end, returnPosition: position, handoffID: handoff, returned: true,
                                                returnAfterInput: afterInput), ifAllowed: { self.input.isParked }) else {
                    self.returnToLocal(); return
                }
                self.control = .local; self.pendingSince = nil; self.controlGranted = false
                self.status = "已连接：\(self.peerName ?? "Mac")"
            } catch {
                if generation == self.captureGeneration { self.handleHandoffFailure(error, returnPosition: position) }
            }
        }
    }
    private func rejectControlRequest() {
        let wasLocal = control == .local
        returnToLocal()
        if wasLocal { transport.send(.init(kind: .end, handoffID: activeHandoffID)) }
    }
    private func cancelCaptureAttempt() { captureGeneration &+= 1; captureTask?.cancel() }
    private func finishLocalInput(restoring position: SharingCursorPosition? = nil, returnMotion: CGPoint? = nil,
                                  handoffDelay: TimeInterval = 0.65) {
        cancelCaptureAttempt()
        let errors = input.reset(restoring: position, returnMotion: returnMotion, handoffDelay: handoffDelay)
        sentHandoffMotion = SharingReturnMotion(); receivedHandoffInputs = 0
        control = .local; pendingSince = nil; controlGranted = false; activeHandoffID = nil; pendingDirectEntry = nil
        if !errors.isEmpty {
            cancelInputRecovery(); input.stop(); keyboardMouseEnabled = false; inputStatus = errors.joined(separator: "；")
            transport.send(.init(kind: .ping, keyboardEnabled: false))
            clipboard.refreshAuthorization()
        }
        refreshInputStatus()
        input.canSwitch = canStartControl
    }
    private func refreshInputStatus() {
        if inputRecovering { status = "键鼠正在恢复，连接保持。" }
        else if !keyboardMouseEnabled, let inputStatus { status = "键鼠共享已暂停：" + inputStatus }
        else if peerKeyboardMouseEnabled == false { status = "对端已连接，键鼠暂不可用。" }
        else if let peerName { status = "已连接：\(peerName)" }
    }
    private func handleHandoffFailure(_ error: Error, returnPosition: SharingCursorPosition? = nil) {
        let retryable = (error as? SharingCursorInterruption)?.mayRetry == true
        if error is CancellationError || retryable {
            // The scheduled tap withdrawal owns cancellation + local replay.
            // A second reset here would discard that physical input batch.
            guard !input.transitionPending else { return }
            returnToLocal(at: retryable ? returnPosition : nil) // Keep TLS, layout and the tap if cleanup succeeds.
            if keyboardMouseEnabled, retryable {
                inputStatus = error.localizedDescription
                status = error.localizedDescription
            }
            return
        }
        if let interruption = error as? SharingCursorInterruption, interruption.canRepairCapture {
            recoverInterruptedInput(interruption)
        } else { handleInputFailure(error.localizedDescription) }
    }
    private func recoverInterruptedInput(_ interruption: SharingCursorInterruption) {
        if isCursorDiagnostic { finishCursorDiagnostic(reason: interruption.localizedDescription); return }
        guard !inputRecovering else { return }
        guard isRunning, isAllowed(), keyboardMouseEnabled else { input.reset(); return }
        guard inputAccessAvailable() else {
            handleInputFailure("输入权限被撤销或进入安全输入模式，共享已暂停。")
            return
        }
        inputRecovering = true
        repairRequiresTap = interruption == .tapLost || !input.tapReady
        inputRetry = SharingRetry()
        inputStatus = interruption.localizedDescription
        // End only the stale handoff. Existing grants and the TLS/layout stay
        // in place; the far end releases held input when processing this .end.
        returnToLocal()
        guard inputRecovering else { return } // A cleanup error is a real safety stop.
        if repairRequiresTap { input.discardUnobservedReplay() }
        tryRepairInput(at: monotonicNow())
        if inputRecovering { transport.send(.init(kind: .ping, keyboardEnabled: false)) }
    }
    private func tryRepairInput(at now: TimeInterval) {
        guard inputRecovering, now >= inputRetry.next else { return }
        inputRetry.deferAfterAttempt(at: now)
        guard inputAccessAvailable() else {
            handleInputFailure("输入权限被撤销或进入安全输入模式，共享已暂停。")
            return
        }
        guard !input.needsRecovery, !input.transitionPending else { return }
        if repairRequiresTap || !input.tapReady {
            guard input.repairTap() else { return }
        }
        cancelInputRecovery(); inputStatus = nil
        input.canSwitch = canStartControl
        refreshInputStatus()
        transport.send(.init(kind: .ping, keyboardEnabled: true))
    }
    private func cancelInputRecovery() {
        if inputRecovering { inputRecovering = false }
        inputRetry = SharingRetry(); repairRequiresTap = false
    }
    private func handleInputFailure(_ message: String) {
        if isCursorDiagnostic { finishCursorDiagnostic(reason: message); return }
        cancelInputRecovery(); returnToLocal(); input.stop(); keyboardMouseEnabled = false; input.canSwitch = false
        let recovery = input.safetyDiagnostics["cleanupErrors"] as? [String] ?? []
        inputStatus = recovery.isEmpty ? message : message + "（" + recovery.joined(separator: "；") + "）"
        status = "键鼠共享已暂停：" + (inputStatus ?? message)
        transport.send(.init(kind: .ping, keyboardEnabled: false))
        clipboard.refreshAuthorization()
    }
    var allowsLocalPriorityShortcuts: Bool {
        !input.needsRecovery && (!keyboardMouseEnabled || (control == .local && captureTask == nil && input.allowsLocalPriorityShortcuts))
    }
    func reservesPriorityShortcut(_ key: HotKey?) -> Bool {
        guard keyboardMouseEnabled, let key else { return false }
        return key.keyCode == 53 || key.keyCode == 40 // Preserve the full emergency Esc/K strokes.
    }
    func configurePriorityShortcutRouting(route: @escaping (CGEventType, CGEvent) -> Bool,
                                          ownsKey: @escaping (UInt32) -> Bool, hasKeys: @escaping () -> Bool) {
        input.routeHostShortcut = route; input.priorityOwnsKey = ownsKey; input.priorityHasOutstandingKeys = hasKeys
    }
    func notePriorityShortcutOwnership(_ code: UInt32) { input.notePriorityShortcutOwnership(code) }
    func priorityShortcutOwnershipChanged() { input.priorityShortcutOwnershipChanged() }

    var inputDiagnostics: [String: Any] {
        var value = input.safetyDiagnostics
        value["control"] = control.rawValue; value["keyboardEnabled"] = keyboardMouseEnabled
        value["connected"] = peerName != nil; value["sentInputPackets"] = sentInputPackets
        value["receivedInputPackets"] = receivedInputPackets; value["status"] = inputStatus ?? ""
        return value
    }
    func startCursorDiagnostic(confirmation: @MainActor () -> Bool = PeripheralSharingController.confirmCursorDiagnostic,
                               delay: Duration = .seconds(3), maximumDuration: TimeInterval = 10,
                               reportDirectory: URL? = nil) throws {
        guard isAllowed(), captureTask == nil, !isCursorDiagnostic else { throw PluginError.invalid("请先结束当前切换操作。") }
        try requirePermissions([.accessibility, .inputMonitoring])
        guard !IsSecureEventInputEnabled(), maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 10 else {
            throw PluginError.invalid("请退出安全输入；本机接管测试最长十秒。")
        }
        guard confirmation() else { return }
        stop(); try input.start()
        isCursorDiagnostic = true; diagnosticForwardAttempts = 0; diagnosticDeadline = nil; diagnosticReportDirectory = reportDirectory
        inputStatus = "3秒后进行本机接管测试，请移动实体鼠标；⌃⌥⌘Esc 取消，十秒内恢复。"
        let generation = captureGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            do {
                try await Task.sleep(for: delay)
                guard generation == self.captureGeneration, self.isCursorDiagnostic else { return }
                try await self.input.capture(maximumDuration: maximumDuration)
                guard generation == self.captureGeneration, self.isCursorDiagnostic, !Task.isCancelled else { self.input.reset(); return }
                self.diagnosticDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.02, maximumDuration - 0.15) * 1_000_000_000)
                self.inputStatus = "正在测试：请移动实体鼠标；不向另一台发送任何输入，十秒内自动恢复。"
            } catch {
                if generation == self.captureGeneration { self.finishCursorDiagnostic(reason: error.localizedDescription) }
            }
        }
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCursorDiagnostic else { return }
                if let end = self.diagnosticDeadline, DispatchTime.now().uptimeNanoseconds >= end {
                    self.finishCursorDiagnostic(reason: nil); return
                }
                self.input.maintainCapture()
            }
        }
        diagnosticTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private static func confirmCursorDiagnostic() -> Bool {
        let alert = NSAlert()
        alert.messageText = "进行本机光标接管测试？"
        alert.informativeText = "将先停止共享。3秒后临时隐藏并固定本机光标，请只移动实体鼠标；最多10秒自动恢复，⌃⌥⌘Esc 可取消。\n\n不向远端发送输入、不记录按键内容、不采集音频。结果仅保存状态、错误码和汇总计数。"
        alert.addButton(withTitle: "开始测试"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func finishCursorDiagnostic(reason: String?) {
        guard isCursorDiagnostic else { return }
        let endingIssue = reason ?? input.captureValidationError()
        cancelCaptureAttempt(); diagnosticTimer?.invalidate(); diagnosticTimer = nil; diagnosticDeadline = nil
        let before = input.safetyDiagnostics
        input.stop(); isCursorDiagnostic = false
        let after = input.safetyDiagnostics
        let movement = (before["physicalMouseMovements"] as? Int ?? 0) > 0
        let recoveryOK = ["ownsHiddenCursor", "ownsDisassociation", "ownsCursorPanel", "ownsCursorRegion", "cursorPanelVisible", "recoveryPending"]
            .allSatisfy { after[$0] as? Bool == false }
            && (after["cleanupErrors"] as? [String] ?? []).isEmpty && (after["failure"] as? String ?? "").isEmpty
        let noInput = sentInputPackets == 0 && transport.port == nil && !transport.isConnected
        let result = endingIssue != nil || !recoveryOK || !noInput || after["watchdogExpired"] as? Bool == true ? "failed-or-cancelled" : (movement ? "native-freeze-verified-needs-visual-confirmation" : "incomplete-no-physical-motion")
        inputStatus = endingIssue ?? (result == "failed-or-cancelled" ? "安全监护触发或恢复未完成，本轮未通过，请复制诊断信息。" : (movement ? "接管测试已结束，请确认测试时光标隐藏、结束后已恢复。" : "未检测到实体鼠标移动，本轮未完成，请重试。"))
        var report = after
        report["result"] = result; report["reason"] = endingIssue ?? ""; report["zeroNetworkInput"] = noInput
        report["wouldForwardPackets"] = diagnosticForwardAttempts; report["visualConfirmation"] = "not-collected"
        report["updatedAt"] = Date().timeIntervalSince1970; report["appVersion"] = HostInfo.version
        report["pid"] = ProcessInfo.processInfo.processIdentifier
        do {
            let directory = diagnosticReportDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.untitled.app/SharingDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path,
                  attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw PluginError.invalid("诊断目录不安全，未写入报告。") }
            let url = directory.appendingPathComponent("cursor-test.json")
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { inputStatus = (inputStatus ?? "") + "（无法保存汇总报告）" }
    }
    private func activateControlWhenNeutral() {
        guard control == .requesting, input.isNeutral, peerName != nil, keyboardReady else { return }
        if input.mode == .staged { commitPreparedControl(); return }
        guard captureTask == nil else { return }
        let generation = captureGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            do {
                guard generation == self.captureGeneration, self.control == .requesting, self.input.isNeutral else { return }
                guard self.isRunning, self.isAllowed(), !IsSecureEventInputEnabled() else { throw PluginError.invalid("共享已停止或系统进入安全输入模式。") }
                try self.requirePermissions([.accessibility, .inputMonitoring])
                try await self.input.capture(deferForwarding: true)
                guard generation == self.captureGeneration, !Task.isCancelled, self.isRunning,
                      self.control == .requesting, self.peerName != nil, self.keyboardMouseEnabled else { self.input.reset(); return }
                self.commitPreparedControl()
            } catch {
                if generation == self.captureGeneration { self.handleHandoffFailure(error) }
            }
        }
    }
    private func commitPreparedControl() {
        guard control == .requesting, controlGranted || pendingDirectEntry != nil,
              input.mode == .staged, input.isNeutral, !input.transitionPending else { return }
        do {
            guard isRunning, isAllowed(), peerName != nil, keyboardReady else { throw CancellationError() }
            guard inputAccessAvailable(), !IsSecureEventInputEnabled() else { throw PluginError.invalid("输入权限或安全输入状态已改变，已归还本机。") }
            try requirePermissions([.accessibility, .inputMonitoring])
            try input.validateStaged()
            if let entry = pendingDirectEntry {
                pendingDirectEntry = nil
                guard peerSupportsDirectHandoff, layoutReady, entry.layoutStamp == layoutStamp else { throw CancellationError() }
                guard transport.send(entry, ifAllowed: { self.input.isStaged }) else {
                    if transport.isConnected { try input.validateStaged() }
                    throw CancellationError()
                }
            } else if peerSupportsCursorParking {
                guard transport.send(.init(kind: .commit, handoffID: activeHandoffID), ifAllowed: { self.input.isStaged }) else {
                    if transport.isConnected { try input.validateStaged() }
                    throw CancellationError()
                }
            }
            control = .controlling; pendingSince = nil; controlGranted = false; inputStatus = nil
            try input.beginForwarding()
            status = "已连接：\(peerName ?? "Mac")"
        } catch { handleHandoffFailure(error) }
    }
    private func clearSession() {
        clipboard.disconnect(); peerSupportsClipboardImages = false
        finishLocalInput(); input.canSwitch = false
        peerName = nil; peerKeyboardMouseEnabled = nil; peerDeviceID = nil; peerSupportsCursorParking = false; activeHandoffID = nil; peerSupportsLayoutSync = false; peerSupportsFreeLayout = false; layoutReady = false; input.workspace = nil; remoteMicrophoneAvailable = false; peerDemand = false; demandSent = false
        peerSupportsContinuousReturn = false; peerSupportsDirectHandoff = false
        sentAudioFrames = 0; receivedAudioFrames = 0; sentInputPackets = 0; receivedInputPackets = 0
        stopCapture(); sink.stop(); isReceivingMicrophone = false; captureAttempted = false
        // A repaired connection starts with fresh input/clipboard grants, never prior audio intent.
        microphoneOffered = false; wantsRemoteMicrophone = false; lastReceived = nil
    }
    private func receive(_ message: SharingMessage) {
        guard isRunning, isAllowed() else { stop(); return }
        lastReceived = monotonicNow()
        if message.kind == .hello {
            guard peerName == nil, let id = message.deviceID.flatMap(UUID.init(uuidString:)), id.uuidString != deviceID.uppercased() else {
                transport.disconnect(); status = "拒绝重复连接或连接到本机。"; return
            }
            if deferredIncomingHello && disconnectHold && message.automaticReconnect != false {
                transport.disconnect(); status = "已主动断开，未接受后台连接。"; return
            }
            let expectedPeer = dialIsAutomatic == true ? reconnectTarget?.expectedPeer
                : (deferredIncomingHello && message.automaticReconnect == true
                    ? defaults.string(forKey: "sharing.reconnectPeerID").flatMap(UUID.init(uuidString:)) : nil)
            if let expectedPeer, id != expectedPeer {
                transport.disconnect(); status = "原配对设备身份不符，未恢复共享。"; return
            }
            if deferredIncomingHello { deferredIncomingHello = false; sendHello() }
            guard transport.isConnected else { return }
            if disconnectHold { setDisconnectHold(false) }
            if userSessionStarted {
                defaults.set(id.uuidString, forKey: "sharing.reconnectPeerID")
                if dialIsAutomatic != nil, var target = reconnectTarget {
                    target.expectedPeer = id; target.startupDeadline = nil; target.explicitlySelected = false
                    reconnectTarget = target; saveReconnectTarget(target)
                    reconnectRetry = SharingRetry()
                    if reconnecting { reconnecting = false }
                } else {
                    // The current dialer owns retry, so a healthy pair does not
                    // start a cross-dial loop on the first dropped packet.
                    clearReconnectTarget()
                    defaults.set(true, forKey: "sharing.reconnectPassive")
                }
            }
            peerName = message.name; rememberedPeerName = message.name
            defaults.set(message.name, forKey: "sharing.lastPeerName")
            peerDeviceID = message.deviceID; peerKeyboardMouseEnabled = message.keyboardEnabled
            peerSupportsLayoutSync = message.layoutSync == true
            peerSupportsCursorParking = message.cursorParking == true
            // Older equal-width layouts cannot interpret pixel-space coordinates:
            // both sides deliberately fall back to the original edge protocol.
            peerSupportsFreeLayout = message.layoutVersion == 3 && localPixels != nil
            peerSupportsContinuousReturn = peerSupportsCursorParking && peerSupportsFreeLayout && message.continuousReturn == true
            peerSupportsDirectHandoff = peerSupportsCursorParking && peerSupportsFreeLayout && message.directHandoff == true
            updatePeerScreen(message)
            layoutReady = !peerSupportsFreeLayout
            if peerSupportsFreeLayout {
                if let legacyLayoutOffset { layoutOffset = workspace.offsetFromLegacyUnits(legacyLayoutOffset); self.legacyLayoutOffset = nil }
                layoutOffset = workspace.adjusted(layoutOffset, magnet: 0)
                persistLayout(); sendLayout()
            }
            guard transport.isConnected else { return }
            peerSupportsClipboardImages = message.clipboardImages == true
            clipboard.connect(supported: message.clipboardSync == true, images: peerSupportsClipboardImages)
            guard transport.isConnected else { return }
            refreshInputStatus()
            input.canSwitch = canStartControl; updateMicrophone(); writeRuntimeState(); return
        }
        guard peerName != nil else { transport.disconnect(); status = "对端尚未完成设备握手。"; return }
        if peerSupportsCursorParking, [.accepted, .commit, .input, .end].contains(message.kind) {
            // An unscoped .end is an explicit emergency return, not a delayed
            // normal return from an older handoff. Never replay stale input.
            let emergency = message.kind == .end && message.handoffID == nil && message.returned != true
            guard emergency || (message.handoffID != nil && message.handoffID == activeHandoffID) else { return }
        }
        switch message.kind {
        case .ping:
            if let enabled = message.keyboardEnabled, peerKeyboardMouseEnabled != enabled {
                peerKeyboardMouseEnabled = enabled
                if !enabled, control != .local { returnToLocal() }
                input.canSwitch = canStartControl
                refreshInputStatus()
            }
        case .layout:
            // This changes geometry only, never permissions or sharing enablement.
            // Do not change an in-progress input session or echo the update back.
            if peerSupportsFreeLayout, message.layoutVersion == 3 {
                if control != .local { returnToLocal() }
                if applyLayout(message) {
                    layoutReady = true; input.canSwitch = canStartControl
                    transport.send(.init(kind: .layoutAck, layoutStamp: layoutStamp))
                }
            } else if !peerSupportsFreeLayout, peerSupportsLayoutSync, control == .local, let value = message.edge {
                layoutOffset = SharingDisplayLayout.touching(value.opposite, localAspect: localAspect, peerAspect: peerAspect, localPixels: localPixels, peerPixels: peerPixels); persistLayout()
            }
        case .layoutAck:
            if peerSupportsFreeLayout, message.layoutStamp == layoutStamp { layoutReady = true; input.canSwitch = canStartControl }
        case .begin:
            guard input.reconcileParkedCapture() else {
                // A still-recovering idle cursor cannot accept this handoff.
                // Reject just the request; don't restart its recovery or the session.
                transport.send(.init(kind: .end, handoffID: message.handoffID)); return
            }
            if message.directEntry == true { acceptDirectEntry(message); return }
            guard keyboardReady, (!peerSupportsFreeLayout || layoutReady), control == .local, captureTask == nil,
                  input.canAcceptHandoff, let edge = message.edge, let position = message.position else {
                rejectControlRequest(); return
            }
            guard !peerSupportsCursorParking || message.handoffID != nil else { rejectControlRequest(); return }
            receivedHandoffInputs = 0
            activeHandoffID = message.handoffID; control = .preparing; input.canSwitch = false; pendingSince = Date()
            let generation = captureGeneration, handoff = activeHandoffID
            captureTask = Task { @MainActor [weak self] in
                guard let self else { return }; defer { self.captureTask = nil }
                do {
                    try self.requirePermissions([.accessibility, .inputMonitoring])
                    guard !IsSecureEventInputEnabled() else { self.rejectControlRequest(); return }
                    try await self.input.prepareReceiving(edge: edge, fraction: position, deferPointer: self.peerSupportsCursorParking)
                    guard generation == self.captureGeneration, !Task.isCancelled, self.isRunning, self.keyboardMouseEnabled,
                          self.control == .preparing, self.activeHandoffID == handoff else { self.input.reset(); return }
                    if !self.peerSupportsCursorParking { self.control = .receiving; self.pendingSince = nil }
                    self.transport.send(.init(kind: .accepted, handoffID: handoff))
                } catch {
                    if generation == self.captureGeneration {
                        self.rejectControlRequest()
                        if !(error is CancellationError) { self.reportError(error) }
                    }
                }
            }
        case .commit:
            guard peerSupportsCursorParking, control == .preparing, captureTask == nil else { rejectControlRequest(); return }
            do {
                try requirePermissions([.accessibility, .inputMonitoring])
                guard !IsSecureEventInputEnabled() else { rejectControlRequest(); return }
                try input.commitReceiving(); control = .receiving; pendingSince = nil
            } catch {
                rejectControlRequest()
                if !(error is CancellationError) { reportError(error) }
            }
        case .accepted:
            guard control == .requesting else { rejectControlRequest(); return }
            controlGranted = true; activateControlWhenNeutral()
        case .end:
            let normalReturn = message.returned == true && control == .controlling
            let motion = normalReturn && peerSupportsContinuousReturn ? message.returnAfterInput.flatMap { sentHandoffMotion.after($0) } : nil
            finishLocalInput(restoring: peerSupportsFreeLayout && control == .controlling ? message.returnPosition : nil,
                             returnMotion: motion, handoffDelay: normalReturn ? 0 : 0.65)
        case .input:
            #if DEBUG
            if control == .receiving, let gate = acceptanceAllowsInput, !gate() { returnToLocal(); return }
            #endif
            if control == .receiving, keyboardReady, let packet = message.input {
                receivedInputPackets += 1; receivedHandoffInputs += 1
                input.apply(packet)
            }
        case .clipboardConsent:
            clipboard.acceptConsent(message)
        case .clipboardText:
            if let text = message.clipboardText { clipboard.acceptText(text) }
        case .clipboardImageReady:
            if let grants = message.imageGrants { transport.acceptClipboardImageReady(grants) }
        case .micDemand:
            let demand = message.enabled == true
            if demand != peerDemand { peerDemand = demand; captureAttempted = false; updateMicrophone() }
        case .micState:
            remoteMicrophoneAvailable = message.enabled == true
            if !remoteMicrophoneAvailable { sink.stop(); isReceivingMicrophone = false }
        case .audio:
            guard wantsRemoteMicrophone, demandSent, remoteMicrophoneAvailable, let data = message.audio else { return }
            if !sink.isRunning {
                do { try sink.start() } catch { microphoneStatus = error.localizedDescription; setWantsRemoteMicrophone(false); return }
            }
            sink.append(data); receivedAudioFrames += data.count / 4
            if isReceivingMicrophone != sink.isRunning { isReceivingMicrophone = sink.isRunning }
        default: break
        }
    }
    private func acceptDirectEntry(_ message: SharingMessage) {
        guard let handoff = message.handoffID, let edge = message.edge, let position = message.position else { return }
        // Negotiated direct entry does not wait for the sender's cursor paint.
        // Admit it locally before processing the next ordered frame.
        // A rejection is scoped and must not reset a concurrent valid handoff.
        guard peerSupportsDirectHandoff, peerKeyboardMouseEnabled == true, message.layoutStamp == layoutStamp, layoutReady,
              keyboardReady, control == .local, captureTask == nil, input.canAcceptDirectEntry,
              inputAccessAvailable(), !IsSecureEventInputEnabled() else {
            transport.send(.init(kind: .end, handoffID: handoff)); return
        }
        do {
            try requirePermissions([.accessibility, .inputMonitoring])
            try input.receiveDirectly(edge: edge, fraction: position)
            receivedHandoffInputs = 0; activeHandoffID = handoff; control = .receiving
            input.canSwitch = false; inputStatus = nil
            status = "已连接：\(peerName ?? "Mac")"
        } catch {
            transport.send(.init(kind: .end, handoffID: handoff))
            if !(error is CancellationError) { reportError(error) }
        }
    }
    private func stopCapture() {
        let wasSending = isSendingMicrophone
        capture.stop(); isSendingMicrophone = false
        if wasSending { transport.send(.init(kind: .micState, enabled: false)) }
    }
    private func updateMicrophone() {
        guard isRunning, peerName != nil else { return }
        let demand = wantsRemoteMicrophone && hasDriver && SharingAudioDevices.isInUse
        if demand != demandSent {
            demandSent = demand; transport.send(.init(kind: .micDemand, enabled: demand))
            if !demand { sink.stop(); isReceivingMicrophone = false }
        }
        if wantsRemoteMicrophone && !hasDriver { microphoneStatus = "接收端尚未安装虚拟麦克风驱动" }
        else if wantsRemoteMicrophone && !demand { microphoneStatus = "等待应用使用 \(SharingAudioDevices.virtualInputName) 输入" }
        if microphoneOffered && peerDemand {
            if !capture.isRunning && !captureAttempted {
                captureAttempted = true
                do {
                    try requirePermissions([.microphone])
                    try capture.start(uid: microphoneUID); isSendingMicrophone = true
                    lastMicrophonePacket = Date()
                    transport.send(.init(kind: .micState, enabled: true)); microphoneStatus = "正在将实体麦克风同步给对端"
                } catch {
                    stopCapture(); transport.send(.init(kind: .micState, enabled: false))
                    microphoneStatus = error.localizedDescription; reportError(error)
                }
            }
        } else {
            stopCapture(); captureAttempted = false
            if !wantsRemoteMicrophone { microphoneStatus = microphoneOffered ? "允许共享；等待对端应用使用" : "麦克风共享已关闭" }
        }
        if isReceivingMicrophone { microphoneStatus = "远端声音 → \(SharingAudioDevices.virtualInputName)" }
    }
    private func tick() {
        guard isRunning else { return }
        guard isAllowed() else { stop(reason: "插件已停用，共享已释放。"); return }
        let now = monotonicNow()
        if let previousTick { maximumTickGap = max(maximumTickGap, now - previousTick) }
        previousTick = now
        input.maintainCapture()
        if inputRecovering { tryRepairInput(at: now) }
        tryReconnect(at: now)
        if isSendingMicrophone {
            let packets = capture.mailbox.drain()
            if !packets.isEmpty { lastMicrophonePacket = Date() }
            for packet in packets {
                transport.send(.init(kind: .audio, audio: packet)); sentAudioFrames += packet.count / 4
            }
            if Date().timeIntervalSince(lastMicrophonePacket) > 2 {
                stopCapture(); captureAttempted = true
                microphoneStatus = "麦克风启动后未收到音频帧，已停止采集；请检查设备后重试。"
            }
        }
        if let pendingSince, Date().timeIntervalSince(pendingSince) > 2 { returnToLocal(); status = "对端未启用键鼠或切换超时，已返回本机。" }
        guard now - lastTick >= 1 else { return }
        lastTick = now
        if transport.isConnected {
            // This deadline belongs to the connection, never to a cursor lease.
            if let lastReceived, now - lastReceived > 5 { transport.disconnect(); return }
            // The hello handshake (including explicit-disconnect admission)
            // must finish before any capability, clipboard or input messages.
            if peerName != nil { transport.send(.init(kind: .ping, keyboardEnabled: keyboardReady)) }
        }
        if keyboardMouseEnabled && !inputAccessAvailable() { handleInputFailure("输入权限被撤销或进入安全输入模式，共享已暂停。") }
        else if keyboardReady && !input.tapReady { recoverInterruptedInput(.tapLost) }
        clipboard.refreshAuthorization() // Reuse the existing heartbeat to see macOS permission changes.
        if isSendingMicrophone && (AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !capture.isRunning || SharingAudioDevices.device(capture.deviceUID ?? "") == nil) {
            stopCapture(); captureAttempted = true; microphoneStatus = "麦克风不可用；请检查权限或设备后点击重试。"
        }
        if sink.isRunning && !sink.isRoutingToFeed { sink.stop(); isReceivingMicrophone = false; wantsRemoteMicrophone = false; microphoneStatus = "音频路由变化，已安全停止接收。" }
        updateMicrophone(); writeRuntimeState()
    }
    private func writeRuntimeState() {
        guard runtimeReporting else { return }
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.untitled.app/SharingState", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { return }
            let report: [String: Any] = ["version": HostInfo.version, "pid": ProcessInfo.processInfo.processIdentifier,
                "updatedAt": Date().timeIntervalSince1970, "running": isRunning, "peer": peerName ?? "", "reconnecting": reconnecting,
                "keyboardEnabled": keyboardMouseEnabled, "inputRecovering": inputRecovering, "control": control.rawValue, "status": status,
                "layoutReady": layoutReady, "freeLayout": peerSupportsFreeLayout, "clipboardStatus": clipboardStatus.rawValue,
                "clipboardImages": clipboardImageStatus.rawValue,
                "localPixels": localPixels.map { ["width": $0.width, "height": $0.height] } ?? [:],
                "peerPixels": peerPixels.map { ["width": $0.width, "height": $0.height] } ?? [:],
                "layoutOffset": ["x": layoutOffset.x, "y": layoutOffset.y], "input": inputDiagnostics,
                "connection": ["reconnects": reconnects,
                               "retryArmed": !disconnectHold && peerName == nil && reconnectTarget != nil,
                               "maximumMainLoopGapMilliseconds": maximumTickGap * 1_000,
                               "messageAgeMilliseconds": lastReceived.map { max(0, monotonicNow() - $0) * 1_000 } ?? 0],
                "sendingMicrophone": isSendingMicrophone, "receivingMicrophone": isReceivingMicrophone]
            let url = directory.appendingPathComponent("status.json")
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* A read-only status report must never affect input routing. */ }
    }
}
