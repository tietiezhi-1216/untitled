@preconcurrency import IOBluetooth
import Foundation
import UntitledPluginSDK

enum XiaomiRemotePairingCode: Equatable {
    case compare(BluetoothNumericValue)
    case enterOnRemote(BluetoothPasskey)

    var digits: String {
        switch self {
        case .compare(let value), .enterOnRemote(let value):
            return String(format: "%06u", value)
        }
    }
}

/// Uses the system's LE inquiry and pairing APIs for remotes that need to bond before ATVV is available.
@MainActor final class XiaomiRemotePairing: NSObject, IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate {
    enum Event {
        case devices([XiaomiVoiceRemote])
        case code(XiaomiRemotePairingCode)
        case paired
        case failed(String)
    }

    private struct Device {
        let candidate: XiaomiVoiceRemote
        let bluetooth: IOBluetoothDevice
    }

    private static let initializationQueue = DispatchQueue(label: "com.untitled.app.remote-pairing")
    private var inquiry: IOBluetoothDeviceInquiry?
    private var startingInquiry = false
    private var wantsInquiry = false
    private var devices: [Device] = []
    private var pairing: IOBluetoothDevicePair?
    private var isComparingCode = false

    var onEvent: ((Event) -> Void)?

    func discover() {
        guard !wantsInquiry, pairing == nil else { return }
        wantsInquiry = true
        devices.removeAll(keepingCapacity: true)
        onEvent?(.devices([]))
        guard wantsInquiry else { return }
        guard !startingInquiry else { return }
        startingInquiry = true

        // IOBluetooth waits for its CoreBluetooth coordinator during initialization.
        // Keep the main run loop free so that coordinator can receive its state.
        Task { @MainActor [weak self] in
            let inquiry = await withCheckedContinuation { (continuation: CheckedContinuation<IOBluetoothDeviceInquiry?, Never>) in
                Self.initializationQueue.async {
                    continuation.resume(returning: IOBluetoothDeviceInquiry(delegate: nil))
                }
            }
            guard let self else { return }
            self.startingInquiry = false
            guard self.wantsInquiry, let inquiry else { return }
            self.inquiry = inquiry
            inquiry.delegate = self
            inquiry.searchType = kIOBluetoothDeviceSearchLE.rawValue
            inquiry.inquiryLength = 15
            inquiry.updateNewDeviceNames = true
            if inquiry.start() != 0 { self.stopDiscovery() }
        }
    }

    func stopDiscovery() {
        wantsInquiry = false
        inquiry?.delegate = nil
        _ = inquiry?.stop()
        inquiry = nil
    }

    func pair(_ id: UUID) throws {
        guard pairing == nil, let device = devices.first(where: { $0.candidate.id == id }),
              let operation = IOBluetoothDevicePair(device: device.bluetooth) else {
            throw PluginError.invalid("遥控器已不在列表中。请重新查找。")
        }
        stopDiscovery()
        pairing = operation
        operation.delegate = self
        if operation.start() != 0 {
            stop()
            throw PluginError.invalid("启动配对失败。请让遥控器重新进入配对模式。")
        }
    }

    func confirmCode(_ confirmed: Bool) {
        guard isComparingCode, let pairing else { return }
        isComparingCode = false
        pairing.replyUserConfirmation(confirmed)
    }

    func stop() {
        stopDiscovery()
        pairing?.delegate = nil
        pairing?.stop()
        pairing = nil
        isComparingCode = false
        devices.removeAll()
    }

    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        updateFoundDevices(from: sender)
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!,
                                                     devicesRemaining: UInt32) {
        updateFoundDevices(from: sender)
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        updateFoundDevices(from: sender, finished: true)
    }

    private nonisolated func updateFoundDevices(from sender: IOBluetoothDeviceInquiry?, finished: Bool = false) {
        guard let sender else { return }
        let source = ObjectIdentifier(sender)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.collectDevices(from: source)
            if finished, let inquiry = self.inquiry, ObjectIdentifier(inquiry) == source {
                self.wantsInquiry = false
                inquiry.delegate = nil
                self.inquiry = nil
            }
        }
    }

    private func collectDevices(from source: ObjectIdentifier) {
        guard wantsInquiry, let inquiry, ObjectIdentifier(inquiry) == source else { return }
        var changed = false
        for device in inquiry.foundDevices().compactMap({ $0 as? IOBluetoothDevice }) {
            guard let name = XiaomiVoiceRemote.supportedName(device.name), !device.isPaired(),
                  devices.count < 12, !devices.contains(where: { $0.bluetooth.isEqual(device) }) else { continue }
            devices.append(.init(candidate: .init(id: UUID(), name: name, needsPairing: true), bluetooth: device))
            changed = true
        }
        if changed { onEvent?(.devices(devices.map(\.candidate))) }
    }

    nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        deliver(.code(.compare(numericValue)), from: sender)
    }

    nonisolated func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        deliver(.code(.enterOnRemote(passkey)), from: sender)
    }

    nonisolated func devicePairingPINCodeRequest(_ sender: Any!) {
        deliver(.failed("这只遥控器要求输入传统配对 PIN。请重新进入配对模式再试。"), from: sender)
    }

    nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        deliver(error == 0 ? .paired : .failed("蓝牙配对未完成。请确认遥控器还在配对模式并重试。"), from: sender)
    }

    private nonisolated func deliver(_ event: Event, from sender: Any?) {
        guard let sender = sender as? IOBluetoothDevicePair else { return }
        let source = ObjectIdentifier(sender)
        Task { @MainActor [weak self] in
            guard let self, let pairing = self.pairing, ObjectIdentifier(pairing) == source else { return }
            switch event {
            case .code(.compare):
                self.isComparingCode = true
            case .paired:
                pairing.delegate = nil
                self.pairing = nil
                self.isComparingCode = false
            default:
                break
            }
            self.onEvent?(event)
        }
    }
}
