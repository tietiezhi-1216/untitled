@preconcurrency import CoreBluetooth
import Foundation
import UntitledPluginSDK

struct XiaomiVoiceRemote: Identifiable, Equatable {
    let id: UUID
    let name: String
    let needsPairing: Bool

    init(id: UUID, name: String, needsPairing: Bool = false) {
        self.id = id
        self.name = name
        self.needsPairing = needsPairing
    }

    static func supportedName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        switch name.lowercased() {
        case "mi rc", "xiaomi bluetooth remote 2", "xiaomi bluetooth remote 2 pro",
             "xiaomi bluetooth remote control 2", "xiaomi bluetooth remote control 2 pro", "rc001-ms", "rc003-ms",
             "小米蓝牙语音遥控器", "小米蓝牙遥控器 2", "小米蓝牙遥控器 2 pro",
             "小米蓝牙遥控器2", "小米蓝牙遥控器2 pro":
            return name
        default:
            return nil
        }
    }

    func hasSameName(as other: XiaomiVoiceRemote) -> Bool {
        name.caseInsensitiveCompare(other.name) == .orderedSame
    }

    func pairingCandidate(among nearby: [XiaomiVoiceRemote], direct: [XiaomiVoiceRemote]) -> XiaomiVoiceRemote? {
        guard Self.supportedName(name) != nil,
              direct.count(where: { hasSameName(as: $0) }) == 1 else { return nil }
        let matches = nearby.filter { $0.needsPairing && hasSameName(as: $0) }
        return matches.count == 1 ? matches.first : nil
    }
}

enum XiaomiRemoteConnectionProgress: Equatable {
    case lookingForPairing, bluetooth, voiceServices, capabilities

    var title: String {
        switch self {
        case .lookingForPairing: "正在查找配对信息"
        case .bluetooth: "正在建立蓝牙连接"
        case .voiceServices: "正在初始化语音服务"
        case .capabilities: "正在等待遥控器语音响应"
        }
    }

    var timeout: String {
        switch self {
        case .lookingForPairing: "查找配对信息超时。请同时长按遥控器的主页键和菜单键后重试。"
        case .bluetooth: "蓝牙握手未完成。请把遥控器靠近 Mac，并重新进入配对模式。"
        case .voiceServices: "蓝牙已连上，但语音服务初始化超时。请唤醒遥控器后重试。"
        case .capabilities: "蓝牙语音通道已打开，但遥控器未回应语音协商。请重新连接。"
        }
    }
}

enum XiaomiRemoteLinkEvent {
    case devices([XiaomiVoiceRemote])
    case progress(XiaomiRemoteConnectionProgress)
    case startingPairing
    case pairingCode(XiaomiRemotePairingCode)
    case connectingVoice
    case choosePairedRemote([XiaomiVoiceRemote], String)
    case subscribed
    case control(Data)
    case audio(Data)
    case failed(String)
}

@MainActor protocol XiaomiRemoteLink: AnyObject {
    var onEvent: ((XiaomiRemoteLinkEvent) -> Void)? { get set }
    func discover()
    func stopDiscovery()
    func connect(_ id: UUID) throws
    func confirmPairingCode(_ confirmed: Bool)
    func send(_ command: Data) throws
    func stop()
}

@MainActor final class XiaomiRemoteBluetooth: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, XiaomiRemoteLink {
    private static let service = CBUUID(string: XiaomiRemoteVoice.serviceUUID)
    private static let command = CBUUID(string: XiaomiRemoteVoice.commandUUID)
    private static let audio = CBUUID(string: XiaomiRemoteVoice.audioUUID)
    private static let control = CBUUID(string: XiaomiRemoteVoice.controlUUID)
    private static let connectedServices = ["180A", "180F", "1812"].map { CBUUID(string: $0) }
    private static let genericVoiceName = "蓝牙语音遥控器（ATVV）"
    private static let encryptionFailure = "遥控器的蓝牙加密未完成。请同时长按主页键和菜单键，再次选择连接。"

    private struct Candidate {
        let remote: XiaomiVoiceRemote
        let peripheral: CBPeripheral
    }

    private struct PairingTarget {
        let remote: XiaomiVoiceRemote
        let preferredID: UUID?
        let previouslyConnected: Set<UUID>
    }

    private struct PairingLookup {
        let candidate: Candidate
        let previousFailure: String?
    }

    private let pairing = XiaomiRemotePairing()
    private var central: CBCentralManager?
    private var candidates: [Candidate] = []
    private var nearby: [XiaomiVoiceRemote] = []
    private var pairingLookup: PairingLookup?
    private var pairingLookupDeadline: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?
    private var recoveryCandidate: Candidate?
    private var pairTarget: PairingTarget?
    private var pairedLookup: Task<Void, Never>?
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var control: CBCharacteristic?
    private var notified = false
    private var wantsDiscovery = false

    var onEvent: ((XiaomiRemoteLinkEvent) -> Void)?

    override init() {
        super.init()
        pairing.onEvent = { [weak self] event in self?.receivePairing(event) }
    }

    func discover() {
        wantsDiscovery = true
        candidates.removeAll(keepingCapacity: true)
        nearby.removeAll(keepingCapacity: true)
        onEvent?(.devices([]))
        if let central { updateState(central) }
        else {
            let manager = CBCentralManager(delegate: self, queue: .main,
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            central = manager
            if manager.state == .poweredOn { updateState(manager) }
        }
    }

    func stopDiscovery() {
        wantsDiscovery = false
        central?.stopScan()
        pairing.stopDiscovery()
    }

    func connect(_ id: UUID) throws {
        guard let central, central.state == .poweredOn, peripheral == nil,
              pairTarget == nil, pairingLookup == nil else {
            throw PluginError.invalid("遥控器已不在列表中。请重新查找。")
        }
        if let candidate = candidates.first(where: { $0.remote.id == id }) {
            let hasSystemLink = connectedCandidates(using: central).contains { $0.remote.id == id }
            if hasSystemLink || XiaomiVoiceRemote.supportedName(candidate.remote.name) == nil {
                connectVoice(candidate, using: central)
            } else {
                lookForPairing(candidate, using: central)
            }
        } else if let remote = nearby.first(where: { $0.id == id }) {
            try startPairing(remote, preferredID: nil, using: central)
        } else {
            throw PluginError.invalid("遥控器已不在列表中。请重新查找。")
        }
    }

    func confirmPairingCode(_ confirmed: Bool) { pairing.confirmCode(confirmed) }

    private func lookForPairing(_ candidate: Candidate, using central: CBCentralManager, afterFailure failure: String? = nil) {
        pairingLookup = .init(candidate: candidate, previousFailure: failure)
        onEvent?(.progress(.lookingForPairing))
        guard central === self.central, pairingLookup != nil else { return }
        if pairMatchingRemote(using: central) { return }
        pairing.discover()
        pairingLookupDeadline = Task { @MainActor [weak self, weak central] in
            do { try await Task.sleep(for: .seconds(failure == nil ? 5 : 8)) }
            catch { return }
            guard let self, let central, central === self.central, let lookup = self.pairingLookup else { return }
            self.pairingLookup = nil
            self.pairingLookupDeadline = nil
            if let failure = lookup.previousFailure {
                self.onEvent?(.failed(failure))
            } else {
                self.connectVoice(lookup.candidate, using: central, canRecoverPairing: true)
            }
        }
    }

    private func startPairing(_ remote: XiaomiVoiceRemote, preferredID: UUID?, using central: CBCentralManager) throws {
        pairingLookupDeadline?.cancel()
        pairingLookupDeadline = nil
        pairingLookup = nil
        cancelVoiceConnection(using: central)
        let connected = connectedCandidates(using: central)
        pairTarget = .init(remote: remote, preferredID: preferredID, previouslyConnected: Set(connected.map(\.remote.id)))
        stopDiscovery()
        // Retain the selected IOBluetooth device until pair() transfers it to the system pairing operation.
        try pairing.pair(remote.id)
        onEvent?(.startingPairing)
    }

    private func pairMatchingRemote(using central: CBCentralManager) -> Bool {
        guard let candidate = pairingLookup?.candidate ?? recoveryCandidate,
              let match = candidate.remote.pairingCandidate(among: nearby, direct: candidates.map(\.remote)) else { return false }
        do { try startPairing(match, preferredID: candidate.remote.id, using: central) }
        catch { onEvent?(.failed(error.localizedDescription)) }
        return true
    }

    private func connectVoice(_ candidate: Candidate, using central: CBCentralManager, canRecoverPairing: Bool = false) {
        wantsDiscovery = false
        central.stopScan()
        if !canRecoverPairing { pairing.stopDiscovery() }
        recoveryCandidate = canRecoverPairing ? candidate : nil
        peripheral = candidate.peripheral
        candidate.peripheral.delegate = self
        onEvent?(.progress(.bluetooth))
        guard central === self.central, peripheral === candidate.peripheral else { return }
        central.connect(candidate.peripheral)
        handshakeDeadline = Task { @MainActor [weak self, weak central] in
            do { try await Task.sleep(for: .seconds(6)) }
            catch { return }
            guard let self, let central, central === self.central else { return }
            self.voiceConnectionFailed(XiaomiRemoteConnectionProgress.bluetooth.timeout, using: central, canRecoverPairing: true)
        }
    }

    private func cancelVoiceConnection(using central: CBCentralManager?) {
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        recoveryCandidate = nil
        if let peripheral {
            self.peripheral = nil
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        command = nil
        audio = nil
        control = nil
        notified = false
    }

    private func voiceConnectionFailed(_ message: String, using central: CBCentralManager, canRecoverPairing: Bool) {
        if canRecoverPairing, let candidate = recoveryCandidate, central.state == .poweredOn {
            cancelVoiceConnection(using: central)
            lookForPairing(candidate, using: central, afterFailure: message)
        } else {
            onEvent?(.failed(message))
        }
    }

    func send(_ data: Data) throws {
        guard let peripheral, let command, peripheral.state == .connected else {
            throw PluginError.invalid("遥控器连接已断开。")
        }
        if command.properties.contains(.write) {
            peripheral.writeValue(data, for: command, type: .withResponse)
        } else if peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: command, type: .withoutResponse)
        } else {
            throw PluginError.invalid("蓝牙写入暂不可用。请重新连接遥控器。")
        }
    }

    func stop() {
        stopDiscovery()
        pairing.stop()
        pairingLookupDeadline?.cancel()
        pairingLookupDeadline = nil
        pairingLookup = nil
        pairedLookup?.cancel()
        pairedLookup = nil
        pairTarget = nil
        cancelVoiceConnection(using: central)
        central?.delegate = nil
        central = nil
        candidates.removeAll()
        nearby.removeAll()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        updateState(central)
    }

    private func updateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard wantsDiscovery else { return }
            for candidate in connectedCandidates(using: central) { add(candidate) }
            if !central.isScanning {
                // The name may arrive with a scan response after the first advertising packet.
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
            pairing.discover()
        case .resetting:
            if peripheral != nil || pairTarget != nil || pairingLookup != nil {
                onEvent?(.failed("蓝牙正在重启。请重新连接遥控器。"))
            }
        case .unknown:
            break
        case .poweredOff:
            onEvent?(.failed("请在系统设置中打开蓝牙，再查找遥控器。"))
        case .unauthorized:
            onEvent?(.failed("请在 Untitled 权限管理中允许蓝牙访问。"))
        default:
            onEvent?(.failed("这台 Mac 的蓝牙目前不可用。"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, wantsDiscovery else { return }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        if let found = candidate(peripheral, names: [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name],
                                 hasVoiceService: services.contains(Self.service) || serviceData?[Self.service] != nil) {
            add(found)
        }
    }

    private func candidate(_ peripheral: CBPeripheral, names: [String?], hasVoiceService: Bool) -> Candidate? {
        let name = names.compactMap { XiaomiVoiceRemote.supportedName($0) }.first
        guard name != nil || hasVoiceService else { return nil }
        return .init(remote: .init(id: peripheral.identifier, name: name ?? Self.genericVoiceName), peripheral: peripheral)
    }

    private func connectedCandidates(using central: CBCentralManager) -> [Candidate] {
        var result: [Candidate] = []
        var seen = Set<UUID>()
        for service in [Self.service] + Self.connectedServices {
            for device in central.retrieveConnectedPeripherals(withServices: [service]) {
                if let found = candidate(device, names: [device.name], hasVoiceService: service == Self.service),
                   seen.insert(found.remote.id).inserted {
                    result.append(found)
                }
            }
        }
        return result
    }

    private func add(_ found: Candidate) {
        if let index = candidates.firstIndex(where: { $0.remote.id == found.remote.id }) {
            guard found.remote.name != Self.genericVoiceName, candidates[index].remote != found.remote else { return }
            candidates[index] = found
        } else {
            guard candidates.count < 12 else { return }
            candidates.append(found)
        }
        publishCandidates()
    }

    private func publishCandidates() {
        let direct = candidates.map(\.remote)
        let otherDirect = direct.filter { $0.pairingCandidate(among: nearby, direct: direct) == nil }
        onEvent?(.devices(Array((nearby + otherDirect).prefix(12))))
    }

    private func receivePairing(_ event: XiaomiRemotePairing.Event) {
        switch event {
        case .devices(let devices):
            guard wantsDiscovery || pairingLookup != nil || recoveryCandidate != nil else { return }
            nearby = devices
            if let central, pairMatchingRemote(using: central) { return }
            if wantsDiscovery { publishCandidates() }
        case .code(let code):
            if pairTarget != nil { onEvent?(.pairingCode(code)) }
        case .paired:
            guard let central, let pairTarget else { return }
            lookUpPairedRemote(pairTarget, using: central)
        case .failed(let message):
            if pairTarget != nil { onEvent?(.failed(message)) }
        }
    }

    private func lookUpPairedRemote(_ target: PairingTarget, using central: CBCentralManager) {
        pairedLookup = Task { @MainActor [weak self, weak central] in
            let deadline = ContinuousClock.now + .seconds(10)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, let central, central === self.central else { return }
                let connected = self.connectedCandidates(using: central)
                let newRemotes = connected.filter { !target.previouslyConnected.contains($0.remote.id) }
                let matchingNames = newRemotes.filter { $0.remote.hasSameName(as: target.remote) }
                let preferred = target.preferredID.flatMap { id in connected.first { $0.remote.id == id } }
                if let match = preferred ?? (matchingNames.count == 1 ? matchingNames.first : nil) {
                    self.completePairing()
                    self.onEvent?(.connectingVoice)
                    self.connectVoice(match, using: central)
                    return
                }
                if matchingNames.count > 1 || ContinuousClock.now >= deadline {
                    self.completePairing()
                    self.candidates = Array(connected.prefix(12))
                    let message = connected.isEmpty
                        ? "遥控器已配对，正在等待语音服务。唤醒遥控器后再查找。"
                        : "遥控器已配对。请从列表中选择刚配对的遥控器。"
                    self.onEvent?(.choosePairedRemote(self.candidates.map(\.remote), message))
                    return
                }
            }
        }
    }

    private func completePairing() {
        pairTarget = nil
        pairedLookup = nil
        nearby.removeAll()
        pairing.stop()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral else { return }
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        onEvent?(.progress(.voiceServices))
        guard central === self.central, peripheral === self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        voiceConnectionFailed(Self.connectionMessage(for: error), using: central, canRecoverPairing: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        let message = notified ? "遥控器已断开。唤醒它后可以重新连接。" : Self.connectionMessage(for: error)
        voiceConnectionFailed(message, using: central, canRecoverPairing: !notified)
    }

    static func connectionMessage(for error: Error?) -> String {
        if let error = error as? CBError, [.encryptionTimedOut, .peerRemovedPairingInformation].contains(error.code) {
            return encryptionFailure
        }
        return XiaomiRemoteConnectionProgress.bluetooth.timeout
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            onEvent?(.failed("这只遥控器未提供兼容的语音服务。请核对型号并重新连接。"))
            return
        }
        peripheral.discoverCharacteristics([Self.command, Self.audio, Self.control], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == Self.service else { return }
        let characteristics = service.characteristics ?? []
        guard error == nil,
              let command = characteristics.first(where: { $0.uuid == Self.command }),
              !command.properties.intersection([.write, .writeWithoutResponse]).isEmpty,
              let audio = characteristics.first(where: { $0.uuid == Self.audio }),
              let control = characteristics.first(where: { $0.uuid == Self.control }),
              !audio.properties.intersection([.notify, .indicate]).isEmpty,
              !control.properties.intersection([.notify, .indicate]).isEmpty else {
            onEvent?(.failed("遥控器语音通道不完整。请重新连接。"))
            return
        }
        self.command = command
        self.audio = audio
        self.control = control
        peripheral.setNotifyValue(true, for: control)
        peripheral.setNotifyValue(true, for: audio)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === audio || characteristic === control else { return }
        guard error == nil, characteristic.isNotifying else {
            let needsEncryption: Bool
            if let attError = error as? CBATTError {
                needsEncryption = [.insufficientAuthentication, .insufficientEncryption, .insufficientEncryptionKeySize].contains(attError.code)
            } else { needsEncryption = false }
            if let central, needsEncryption {
                voiceConnectionFailed(Self.encryptionFailure, using: central, canRecoverPairing: true)
            } else {
                onEvent?(.failed("遥控器语音订阅失败。请确认配对提示后重新连接。"))
            }
            return
        }
        if !notified, audio?.isNotifying == true, control?.isNotifying == true {
            notified = true
            recoveryCandidate = nil
            pairing.stopDiscovery()
            onEvent?(.subscribed)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === command, error != nil else { return }
        onEvent?(.failed("遥控器没有接受语音控制指令。请重新连接。"))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, notified else { return }
        if error != nil {
            onEvent?(.failed("遥控器语音连接中断。请重新连接。"))
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic === control { onEvent?(.control(data)) }
        if characteristic === audio { onEvent?(.audio(data)) }
    }
}
