@preconcurrency import CoreBluetooth
import Foundation

struct XiaomiVoiceRemote: Identifiable, Equatable {
    let id: UUID
    let name: String

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
    func send(_ command: Data) throws
    func stop()
}

@MainActor final class XiaomiRemoteBluetooth: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, XiaomiRemoteLink {
    private static let service = CBUUID(string: XiaomiRemoteVoice.serviceUUID)
    private static let command = CBUUID(string: XiaomiRemoteVoice.commandUUID)
    private static let audio = CBUUID(string: XiaomiRemoteVoice.audioUUID)
    private static let control = CBUUID(string: XiaomiRemoteVoice.controlUUID)
    private var central: CBCentralManager?
    private var candidates: [(remote: XiaomiVoiceRemote, peripheral: CBPeripheral)] = []
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var control: CBCharacteristic?
    private var notified = false
    private var wantsDiscovery = false

    var onEvent: ((XiaomiRemoteLinkEvent) -> Void)?

    func discover() {
        wantsDiscovery = true
        candidates.removeAll(keepingCapacity: true)
        onEvent?(.devices([]))
        if let central { updateState(central) }
        else {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stopDiscovery() {
        wantsDiscovery = false
        central?.stopScan()
    }

    func connect(_ id: UUID) throws {
        guard let central, central.state == .poweredOn, peripheral == nil,
              let candidate = candidates.first(where: { $0.remote.id == id }) else {
            throw PluginError.invalid("遥控器已不在列表中。请重新查找。")
        }
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
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        updateState(central)
    }

    private func updateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard wantsDiscovery else { return }
            let pairedServices = [CBUUID(string: "180A"), CBUUID(string: "180F"), CBUUID(string: "1812")]
            for device in central.retrieveConnectedPeripherals(withServices: pairedServices) {
                add(device, names: [device.name], hasVoiceService: false)
            }
            for device in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
                add(device, names: [device.name], hasVoiceService: true)
            }
            // Xiaomi devices may omit the audio service from their advertisements.
            central.scanForPeripherals(withServices: nil)
        case .resetting:
            if peripheral != nil { onEvent?(.failed("蓝牙正在重启。请重新连接遥控器。")) }
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
        add(peripheral, names: [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name],
            hasVoiceService: services.contains(Self.service))
    }

    private func add(_ peripheral: CBPeripheral, names: [String?], hasVoiceService: Bool) {
        let name = names.compactMap { XiaomiVoiceRemote.supportedName($0) }.first
        guard name != nil || hasVoiceService else { return }
        let id = peripheral.identifier
        if let index = candidates.firstIndex(where: { $0.remote.id == id }) {
            guard let name, candidates[index].remote.name != name else { return }
            candidates[index] = (.init(id: id, name: name), peripheral)
        } else {
            guard candidates.count < 12 else { return }
            candidates.append((.init(id: id, name: name ?? "蓝牙语音遥控器（ATVV）"), peripheral))
        }
        onEvent?(.devices(candidates.map(\.remote)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        onEvent?(.failed("连接遥控器失败。请确认它已在系统蓝牙中配对，然后重试。"))
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
            onEvent?(.failed("遥控器语音订阅失败。请在系统蓝牙中确认配对后重试。"))
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
