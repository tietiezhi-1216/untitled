import Foundation
import Testing

@testable import Untitled

@Suite(.serialized) struct WirelessMicrophoneTests {
    @Test func recognizesSupportedRemoteNames() {
        for name in ["MI RC", "Xiaomi Bluetooth Remote 2", "Xiaomi Bluetooth Remote 2 Pro",
                     "Xiaomi Bluetooth Remote Control 2", " 小米蓝牙语音遥控器 "] {
            #expect(XiaomiVoiceRemote.supportedName(name) != nil)
        }
        for name in [nil, "Mi Box", "Xiaomi Bluetooth Remote", "MI RC (unknown clone)"] {
            #expect(XiaomiVoiceRemote.supportedName(name) == nil)
        }
    }

    @Test func negotiatesBoundedAtvvAndDecodesHighNibbleFirst() {
        #expect(XiaomiRemoteVoice.getCapabilities == Data([0x0A, 1, 0, 0, 3, 3]))
        #expect(XiaomiRemoteVoice.control(Fixture.capabilities) == .capabilities(frameBytes: 120))
        #expect(XiaomiRemoteVoice.control(Data([0x0B, 1, 0, 0, 2, 0, 120, 0, 0])) == .capabilities(frameBytes: 120))
        #expect(XiaomiRemoteVoice.control(Data([0x0B, 1, 0, 1, 3, 0, 120])) == .incompatibleCapabilities)
        #expect(XiaomiRemoteVoice.control(Data([0x0B, 1, 0, 2, 3, 0xFF, 0xFF])) == .incompatibleCapabilities)
        #expect(XiaomiRemoteVoice.control(Data([0x04, 3])) == nil)
        #expect(XiaomiRemoteVoice.control(Data([0x0A, 2, 0, 0, 0, 0, 89])) == nil)

        var decoder = XiaomiVoiceDecoder(frameBytes: 2)
        #expect(decoder.append(Data([0x7F])).isEmpty)
        let samples = decoder.append(Data([0]))
        #expect(Array(samples.prefix(2)) == [11, -19])
        #expect(samples.count == 4)
        #expect(decoder.append(Data(repeating: 0, count: 513)).isEmpty)
        _ = decoder.append(Data([0x77]))
        decoder.synchronize(predictor: -300, step: 0)
        #expect(decoder.append(Data([0])).isEmpty)
        #expect(decoder.append(Data([0])) == [-300, -300, -300, -300])
    }

    @Test @MainActor func onlyThePhysicalHoldAcceptsAudioAndReleaseKeepsTheTail() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.connect()
        let link = fixture.link
        let controller = fixture.controller
        let output = fixture.output

        #expect(controller.connection == .connected("Xiaomi Bluetooth Remote 2 Pro"))
        #expect(link.writes == [XiaomiRemoteVoice.getCapabilities])
        link.emit(.audio(Fixture.frame))
        #expect(output.starts == 0)

        link.emit(.control(Data([0x0A, 2, 0, 0, 0xFC, 0x18, 0])))
        link.emit(.control(Fixture.hold))
        #expect(controller.isTalking)
        #expect(output.starts == 0)
        link.emit(.audio(Data(Fixture.frame.prefix(40))))
        #expect(output.samples.isEmpty)
        link.emit(.audio(Data(Fixture.frame.dropFirst(40))))
        #expect(output.samples == Array(repeating: -1000, count: 240))
        #expect(controller.level > 0)

        link.emit(.control(Data([0, 2])))
        #expect(!controller.isTalking && controller.level == 0)
        #expect(output.isRunning)
        #expect(output.hasQueuedAudio)
        let spoken = output.samples
        link.emit(.audio(Fixture.frame))
        #expect(output.samples == spoken)
        try await wait { !output.isRunning }
        #expect(output.starts == 1 && output.stops == 1)
        #expect(link.writes == [XiaomiRemoteVoice.getCapabilities])
    }

    @Test @MainActor func rejectsUnnegotiatedAudioAndWorksAsAMeterWithoutTheDriver() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.output.inputName = nil
        try fixture.connect()
        fixture.link.emit(.control(Data([4, 1, 2, 2])))
        fixture.link.emit(.audio(Fixture.frame))
        #expect(!fixture.controller.isTalking && fixture.output.samples.isEmpty)
        #expect(fixture.link.writes.last == XiaomiRemoteVoice.close(stream: 2))

        fixture.link.emit(.control(Fixture.hold))
        fixture.link.emit(.audio(Data(repeating: 0x77, count: 120)))
        #expect(fixture.controller.isTalking && fixture.controller.level > 0)
        #expect(fixture.controller.inputName == nil && fixture.output.starts == 0)
        fixture.link.emit(.failed("Transport disconnected"))
        #expect(fixture.controller.connection == .idle && !fixture.controller.isTalking)
        #expect(fixture.link.stops == 1)
    }

    @Test @MainActor func permissionGateAndPluginDisableCloseTheRemoteStream() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.driver.state = .denied
        #expect(throws: HostPermissionError.self) {
            try fixture.store.performWirelessMicrophoneAction(pluginID: fixture.manifest.id)
        }
        #expect(fixture.link.discoveries == 0)
        #expect(fixture.store.permissions.pendingRequest?.permissions == [.bluetooth])
        #expect(fixture.store.permissions.pendingRequest?.pluginID == fixture.manifest.id)
        fixture.driver.state = .authorized
        try fixture.connect()
        fixture.link.emit(.control(Fixture.hold))
        fixture.link.emit(.audio(Fixture.frame))
        #expect(fixture.output.isRunning)

        fixture.store.setEnabled(false, pluginID: fixture.manifest.id)
        #expect(fixture.controller.connection == .idle)
        #expect(!fixture.output.isRunning)
        #expect(fixture.link.writes.last == XiaomiRemoteVoice.close(stream: 1))
        fixture.link.emit(.control(Fixture.hold))
        fixture.link.emit(.audio(Fixture.frame))
        #expect(fixture.output.starts == 1)
        #expect(fixture.link.stops == 1)
        fixture.store.setEnabled(true, pluginID: fixture.manifest.id)
        #expect(fixture.link.discoveries == 1)
    }

    @Test @MainActor func upgradeKeepsTheIdentityAndRequiresNewBluetoothDeclaration() throws {
        let fixture = try Fixture(installLegacy: true)
        defer { fixture.cleanup() }
        #expect(fixture.store.installed.first?.manifest.version == "1.0.0")
        #expect(throws: PluginError.self) { try fixture.controller.discover() }
        #expect(fixture.link.discoveries == 0)
        let command = PluginCommand(action: .shareWirelessMicrophone)
        try fixture.store.saveCommand(command, pluginID: fixture.manifest.id)

        try fixture.store.installManifest(fixture.manifest)
        let upgraded = try #require(fixture.store.installed.first)
        #expect(upgraded.manifest.id == "com.untitled.wireless-microphone")
        #expect(upgraded.manifest.version == "2.0.0")
        #expect(upgraded.commands == [command])
        #expect(upgraded.manifest.permissions?.map(\.id) == [.bluetooth])
        #expect(fixture.link.discoveries == 0)
        try fixture.connect()
        fixture.store.uninstall(fixture.manifest.id)
        #expect(fixture.store.installed.isEmpty && fixture.controller.connection == .idle)
    }

    @MainActor private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @MainActor private final class Fixture {
        nonisolated static let capabilities = Data([0x0B, 1, 0, 2, 3, 0, 120, 0, 0])
        nonisolated static let hold = Data([4, 3, 2, 1])
        nonisolated static let frame = Data(repeating: 0, count: 120)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let device = XiaomiVoiceRemote(id: UUID(), name: "Xiaomi Bluetooth Remote 2 Pro")
        let manifest: PluginManifest
        let link = TestLink()
        let output = TestAudio()
        let driver = TestPermissions()
        let store: PluginStore
        let controller: WirelessMicrophoneController

        init(installLegacy: Bool = false) throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Plugins/wireless-microphone/manifest.json"))
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            let link = self.link, output = self.output
            store = PluginStore(directory: directory, permissions: driver.center(), wirelessMicrophoneFactory: {
                WirelessMicrophoneController(link: link, output: output)
            })
            if installLegacy {
                var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                old["version"] = "1.0.0"
                old["minimumHostVersion"] = "0.13.51"
                old["permissions"] = [["id": "system.microphone", "reason": "Legacy microphone"]]
                try store.installManifest(JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: old)))
            } else {
                try store.installManifest(manifest)
            }
            controller = store.wirelessMicrophone(for: manifest.id)
        }

        func connect() throws {
            try store.performWirelessMicrophoneAction(pluginID: manifest.id)
            link.emit(.devices([device]))
            try controller.connect(device.id)
            #expect(link.connectedID == device.id)
            link.emit(.subscribed)
            link.emit(.control(Self.capabilities))
        }

        func cleanup() {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor private final class TestPermissions {
        var state: HostPermissionStatus = .authorized
        func center() -> HostPermissionCenter {
            HostPermissionCenter(drivers: [
                .init(descriptor: .init(id: .bluetooth, title: "Bluetooth", summary: "", symbol: "link"),
                      status: { [self] in state }, request: {}, openSettings: {}),
                .init(descriptor: .init(id: .microphone, title: "Microphone", summary: "", symbol: "mic"),
                      status: { .authorized }, request: {}, openSettings: {}),
            ])
        }
    }

    @MainActor private final class TestLink: XiaomiRemoteLink {
        var onEvent: ((XiaomiRemoteLinkEvent) -> Void)?
        var discoveries = 0
        var stops = 0
        var connectedID: UUID?
        var writes: [Data] = []
        func discover() { discoveries += 1 }
        func stopDiscovery() {}
        func connect(_ id: UUID) throws { connectedID = id }
        func send(_ data: Data) throws { writes.append(data) }
        func stop() { stops += 1 }
        func emit(_ event: XiaomiRemoteLinkEvent) { onEvent?(event) }
    }

    @MainActor private final class TestAudio: WirelessMicrophoneAudio {
        var inputName: String? = "Fixture Virtual Microphone"
        var isRunning = false
        var hasQueuedAudio = false
        var starts = 0
        var stops = 0
        var samples: [Int16] = []
        func start() throws { starts += 1; isRunning = true }
        func append(_ samples: [Int16]) throws { self.samples += samples; hasQueuedAudio = true }
        func stop() {
            if isRunning { stops += 1 }
            isRunning = false
            hasQueuedAudio = false
        }
    }
}
