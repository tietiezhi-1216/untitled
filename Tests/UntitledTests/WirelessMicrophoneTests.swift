import Foundation
import Network
import Security
import Testing

import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginSharing
@testable import UntitledComposition

@Suite(.serialized) struct WirelessMicrophoneTests {
    @Test @MainActor func audioWaitsForConsumerAndDisableReleasesTheSession() async throws {
        let senderAudio = TestAudio()
        let receiverAudio = TestAudio(hasDriver: true)
        let sender = try Fixture(audio: senderAudio)
        let receiver = try Fixture(audio: receiverAudio)
        defer { sender.cleanup(); receiver.cleanup() }

        #expect(sender.controller.connection == .stopped)
        #expect(sender.controller.listeningPort == nil)
        let initialPermissionChecks = sender.permissionChecks
        #expect(senderAudio.captureStarts == 0)
        try await connect(sender.controller, receiver.controller)

        sender.controller.setSending(true)
        receiver.controller.setReceiving(true)
        #expect(!receiver.controller.demandSent)
        #expect(sender.permissionChecks == initialPermissionChecks)
        #expect(senderAudio.captureStarts == 0)

        for round in 1...10 {
            receiverAudio.inputInUse = true
            receiver.controller.refreshDevices()
            try await wait { receiverAudio.outputStarts == round && receiver.controller.isReceiving }
            #expect(receiverAudio.lastPacket == TestAudio.packet)
            #expect(receiverAudio.receivedPackets >= round)
            #expect(senderAudio.captureStarts == round)
            if round < 10 {
                receiverAudio.inputInUse = false
                receiver.controller.refreshDevices()
                try await wait { !sender.controller.isSending }
                #expect(!receiver.controller.isReceiving)
                #expect(!senderAudio.captureRunning && !receiverAudio.outputRunning)
            }
        }
        sender.store.setEnabled(false, pluginID: WirelessMicrophoneController.pluginID)
        #expect(sender.controller.connection == .stopped)
        #expect(sender.controller.listeningPort == nil)
        #expect(!senderAudio.captureRunning)
        try await wait { receiver.controller.connection == .listening }
        #expect(!receiver.controller.receiveEnabled && !receiverAudio.outputRunning)
        #expect(senderAudio.captureStarts == senderAudio.captureStops)
        #expect(receiverAudio.outputStarts == receiverAudio.outputStops)

        sender.store.setEnabled(true, pluginID: WirelessMicrophoneController.pluginID)
        #expect(!sender.controller.isRunning && !sender.controller.sendEnabled)
        #expect(sender.systemPrompts == 0)
        #expect(receiver.systemPrompts == 0)
    }

    @Test @MainActor func permissionDenialAndRevocationRequireAnotherExplicitSend() async throws {
        let senderAudio = TestAudio()
        let sender = try Fixture(audio: senderAudio)
        let receiver = try Fixture(audio: TestAudio(hasDriver: true, inputInUse: true))
        defer { sender.cleanup(); receiver.cleanup() }
        sender.authorization = .denied
        try await connect(sender.controller, receiver.controller)
        receiver.controller.setReceiving(true)
        sender.controller.setSending(true)

        try await wait { sender.controller.sendIssue != nil }
        #expect(sender.store.permissions.pendingRequest?.pluginID == WirelessMicrophoneController.pluginID)
        #expect(sender.store.permissions.pendingRequest?.permissions == [.microphone])
        #expect(!sender.controller.sendEnabled && senderAudio.captureStarts == 0)

        sender.authorization = .authorized
        sender.controller.setSending(true)
        try await wait { receiver.controller.isReceiving }
        #expect(senderAudio.captureRunning)
        senderAudio.captureIsAvailable = false
        try await wait { !sender.controller.isSending && !receiver.controller.isReceiving }
        #expect(!sender.controller.sendEnabled && !senderAudio.captureRunning)
        #expect(senderAudio.captureStarts == 1 && sender.systemPrompts == 0)

        sender.controller.refreshDevices()
        sender.controller.selectInput("fixture-input")
        let pairing = try sender.controller.pairingKey()
        try sender.store.installManifest(sender.manifest)
        #expect(!sender.controller.isRunning && !sender.controller.sendEnabled)
        #expect(sender.controller.inputUID == "fixture-input")
        #expect(try sender.controller.pairingKey() == pairing)
        sender.store.uninstall(WirelessMicrophoneController.pluginID)
        #expect(sender.store.installed.isEmpty && !sender.controller.isRunning)
    }

    @Test @MainActor func audioServiceRejectsPeripheralMessagesAfterAuthentication() async throws {
        let microphone = try Fixture(audio: TestAudio())
        let peer = SharingTransport()
        defer { peer.stop(); microphone.cleanup() }
        let key = try WirelessMicrophoneController.transportKey(for: Fixture.code)
        #expect(try key != SharingPairingKey.decode(Fixture.code))
        try microphone.controller.start(localOnly: true)
        try peer.start(key: key, name: "fixture-peer", localOnly: true)
        try await wait { microphone.controller.listeningPort != nil && peer.port != nil }
        let port = try #require(microphone.controller.listeningPort)
        peer.connected = {
            peer.send(.init(kind: .hello, version: 1, deviceID: UUID().uuidString, name: "Fixture Mac"))
        }
        defer { peer.connected = {} }
        try peer.connect(SharingManualEndpoint.parse(host: "127.0.0.1", port: String(port)))
        try await wait { microphone.controller.isPaired }
        peer.send(.init(kind: .layout, edge: .right))
        try await wait { microphone.controller.connection == .listening }
        #expect(!microphone.controller.sendEnabled && !microphone.controller.receiveEnabled)
    }

    @MainActor private func connect(_ sender: WirelessMicrophoneController, _ receiver: WirelessMicrophoneController) async throws {
        try sender.start(localOnly: true)
        try receiver.start(localOnly: true)
        try await wait { sender.connection == .listening && receiver.connection == .listening }
        try sender.connect(host: "127.0.0.1", port: #require(receiver.listeningPort))
        try await wait { sender.isPaired && receiver.isPaired }
    }

    @MainActor private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(4)
        while !condition() && ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(15))
        }
        try #require(condition(), "Wireless microphone state did not settle", sourceLocation: sourceLocation)
    }

    @MainActor private final class Fixture {
        static let code = String(repeating: "36", count: 32)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manifest: PluginManifest
        let store: PluginStore
        let controller: WirelessMicrophoneController
        let permissions = TestPermissions()
        var authorization: HostPermissionStatus {
            get { permissions.authorization }
            set { permissions.authorization = newValue }
        }
        var permissionChecks: Int { permissions.checks }
        var systemPrompts: Int { permissions.prompts }

        init(audio: TestAudio) throws {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf:
                URL(fileURLWithPath: "Plugins/wireless-microphone/manifest.json")))
            let secret = TestSecret()
            store = PluginStore(directory: directory, permissions: permissions.center(), wirelessMicrophoneFactory: { pluginID, defaults in
                WirelessMicrophoneController(pluginID: pluginID, defaults: defaults, audio: audio, credentials: secret.backend)
            })
            try store.installManifest(manifest)
            let runtime = try #require(store.runtime.owner(of: .shareWirelessMicrophone) as? WirelessMicrophonePluginRuntime)
            controller = runtime.controller(for: manifest.id, in: store)
            try controller.savePairingKey(Self.code)
        }

        func cleanup() {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor private final class TestPermissions {
        var authorization: HostPermissionStatus = .authorized
        var checks = 0
        var prompts = 0

        func center() -> HostPermissionCenter {
            HostPermissionCenter(drivers: [
                .init(descriptor: .init(id: .microphone, title: "Fixture microphone", summary: "", symbol: "mic"),
                      status: { [self] in checks += 1; return authorization },
                      request: { [self] in prompts += 1 }, openSettings: {})
            ])
        }
    }

    private final class TestSecret {
        var value: Data?
        var backend: CredentialBackend {
            .init(read: { [self] _, _ in (value == nil ? errSecItemNotFound : errSecSuccess, value) },
                  update: { [self] _, _, data in value = data; return errSecSuccess },
                  add: { _, _, _ in errSecDuplicateItem },
                  delete: { [self] _, _ in value = nil; return errSecSuccess })
        }
    }

    @MainActor private final class TestAudio: WirelessMicrophoneAudio {
        static let packet = [Float](repeating: 0.125, count: 960).withUnsafeBytes { Data($0) }
        let hasDriver: Bool
        var inputInUse: Bool
        var captureIsAvailable = true
        var captureRunning = false
        var outputRunning = false
        var captureStarts = 0
        var captureStops = 0
        var outputStarts = 0
        var outputStops = 0
        var receivedPackets = 0
        var lastPacket: Data?

        init(hasDriver: Bool = false, inputInUse: Bool = false) {
            self.hasDriver = hasDriver
            self.inputInUse = inputInUse
        }

        func listInputs() -> [SharingAudioDevice] { [.init(id: "fixture-input", name: "Fixture Input", objectID: 1)] }
        func virtualInput() -> WirelessMicrophoneVirtualInput? {
            hasDriver ? .init(name: "Fixture Virtual Input", isInUse: inputInUse) : nil
        }
        var captureIsHealthy: Bool { captureRunning && captureIsAvailable }
        func startCapture(uid: String) throws { captureStarts += 1; captureRunning = true }
        func drainCapture() -> [Data] { captureRunning ? [Self.packet] : [] }
        func stopCapture() { captureStops += 1; captureRunning = false }
        var outputIsHealthy: Bool { outputRunning }
        func startOutput() throws { outputStarts += 1; outputRunning = true }
        func appendOutput(_ data: Data) { receivedPackets += 1; lastPacket = data }
        func stopOutput() { outputStops += 1; outputRunning = false }
    }
}
