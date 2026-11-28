@preconcurrency import CoreBluetooth
import Foundation

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
}

enum XiaomiRemoteLinkEvent {
    case devices([XiaomiVoiceRemote])
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

    private struct Candidate {
        let remote: XiaomiVoiceRemote
        let peripheral: CBPeripheral
    }

    private struct PairingTarget {
        let name: String
        let previouslyConnected: Set<UUID>
    }

    private let pairing = XiaomiRemotePairing()
    private var central: CBCentralManager?
    private var candidates: [Candidate] = []
    private var nearby: [XiaomiVoiceRemote] = []
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
        guard let central, central.state == .poweredOn, peripheral == nil, pairTarget == nil else {
            throw PluginError.invalid("遥控器已不在列表中。请重新查找。")
        }
        if let candidate = candidates.first(where: { $0.remote.id == id }) {
            connectVoice(candidate, using: central)
        } else if let remote = nearby.first(where: { $0.id == id }) {
            let connected = connectedCandidates(using: central)
            pairTarget = .init(name: remote.name, previouslyConnected: Set(connected.map(\.remote.id)))
            stopDiscovery()
            try pairing.pair(id)
        } else {
            throw PluginError.invalid("遥控器已不在列表中。请重新查找。")
        }
    }

    func confirmPairingCode(_ confirmed: Bool) { pairing.confirmCode(confirmed) }

    private func connectVoice(_ candidate: Candidate, using central: CBCentralManager) {
        stopDiscovery()
        peripheral = candidate.peripheral
        candidate.peripheral.delegate = self
        central.connect(candidate.peripheral)
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
        pairedLookup?.cancel()
        pairedLookup = nil
        pairTarget = nil
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.delegate = nil
        central = nil
        peripheral = nil
        command = nil
        audio = nil
        control = nil
        notified = false
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
            if peripheral != nil || pairTarget != nil { onEvent?(.failed("蓝牙正在重启。请重新连接遥控器。")) }
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
        // A remote the system reports as unpaired should go through pairing before opening ATVV.
        let otherDirect = direct.filter { device in
            direct.filter { Self.sameName($0.name, device.name) }.count != 1 ||
                nearby.filter { Self.sameName($0.name, device.name) }.count != 1
        }
        onEvent?(.devices(Array((nearby + otherDirect).prefix(12))))
    }

    private static func sameName(_ first: String, _ second: String) -> Bool {
        first.caseInsensitiveCompare(second) == .orderedSame
    }

    private func receivePairing(_ event: XiaomiRemotePairing.Event) {
        switch event {
        case .devices(let devices):
            guard wantsDiscovery else { return }
            nearby = devices
            publishCandidates()
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
                let matchingNames = newRemotes.filter { Self.sameName($0.remote.name, target.name) }
                if matchingNames.count == 1, let match = matchingNames.first {
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
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        onEvent?(.failed("连接遥控器失败。请同时按住主页键和菜单键，再查找并连接。"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        onEvent?(.failed("遥控器已断开。唤醒它后可以重新连接。"))
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
            onEvent?(.failed("遥控器语音订阅失败。请确认配对提示后重新连接。"))
            return
        }
        if !notified, audio?.isNotifying == true, control?.isNotifying == true {
            notified = true
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
