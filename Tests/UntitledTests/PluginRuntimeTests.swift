import Foundation
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized) @MainActor
struct PluginRuntimeTests {
    private final class Probe: NativePluginRuntime {
        static let example = ActionKind(rawValue: "fixture.capture.test")
        let actions: Set<ActionKind> = [.captureRegion, Probe.example]
        var actionPresentation: [ActionKind: PluginActionPresentation] {
            [Self.example: .init(title: "测试操作", symbol: "checkmark", minimumHostVersion: "0.12.0")]
        }
        let styleNames: Set<String> = ["fixture.appearance"]
        var performed: [String] = [], changes: [String] = []
        func perform(_ command: PluginCommand, for pluginID: String, in host: PluginStore) async throws {
            performed.append(pluginID)
        }
        func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore) { changes.append("replace:\(plugin.manifest.version)") }
        func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore) { changes.append("enabled:\(plugin.isEnabled)") }
        func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws { changes.append("uninstall:\(plugin.id)") }
        func prepareForQuit() async -> Bool { changes.append("quit"); return true }
    }

    private func manifest(_ action: ActionKind, version: String = "1.0.0",
                          minimum: String = "0.5.0", id: String = "test.runtime-owner") -> PluginManifest {
        PluginManifest(schemaVersion: 2, id: id, name: "Runtime Fixture", version: version,
                       summary: "Isolated test fixture", author: "Tests", repository: HostInfo.repository,
                       minimumHostVersion: minimum, actions: [action], templates: [],
                       ui: PluginInterface(slots: [PluginUISlot.content.rawValue: [.component("commands", "host.commands")]]),
                       permissions: [])
    }
    private func store(in directory: URL, modules: [any NativePluginRuntime] = []) -> PluginStore {
        let ui = PluginUIRegistry()
        ui.register(HostPluginUIProvider())
        return PluginStore(runtime: PluginRuntimeRegistry(modules), directory: directory, startupError: nil,
                    uiRegistry: ui, permissions: HostPermissionCenter(drivers: []),
                    shortcutDefaults: nil, priorityHotKeyDriver: .unavailable,
                    ordinaryHotKeyDriver: .init(register: { _, _ in {} }), sideButtonDriver: .unavailable,
                    modifierDriver: .unavailable, priorityRecoverySleep: { _ in },
                    presentations: .bundled, initialCatalog: [])
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func anEmptyShellCanRunHostPrimitivesButRejectsUnregisteredNativeActions() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let host = store(in: path)
        let unsupported = manifest(.captureRegion)
        try unsupported.validate()
        #expect(throws: PluginError.self) { try host.installManifest(unsupported) }
        var unrelated = manifest(.showMainWindow, minimum: HostInfo.version)
        unrelated.styles = ["doubao.hud": ["version": .number(1)]]
        try unrelated.validate()
        #expect(throws: PluginError.self) { try host.installManifest(unrelated) }
        #expect(host.installed.isEmpty)
        let generic = manifest(.showMainWindow), command = PluginCommand(action: .showMainWindow)
        var opens = 0
        host.showMainWindow = { opens += 1 }
        try host.installManifest(generic)
        try host.saveCommand(command, pluginID: generic.id)
        await host.execute(command, pluginID: generic.id)
        #expect(opens == 1)
    }

    @Test func onlySavedEnabledCommandsRunAndTheModuleGetsItsOwnLifecycle() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let probe = Probe(), host = store(in: path, modules: [probe])
        let plugin = manifest(.captureRegion), command = PluginCommand(action: .captureRegion)
        try host.installManifest(plugin)
        await host.execute(command, pluginID: plugin.id)
        #expect(probe.performed.isEmpty)
        try host.saveCommand(command, pluginID: plugin.id)
        await host.execute(command, pluginID: plugin.id)
        host.setEnabled(false, pluginID: plugin.id)
        await host.execute(command, pluginID: plugin.id)
        #expect(probe.performed == [plugin.id])
        try host.installManifest(manifest(.captureRegion, version: "1.1.0"))
        #expect(host.installed.first?.commands == [command] && host.installed.first?.isEnabled == false)
        host.uninstall(plugin.id)
        #expect(await host.prepareForQuit())
        #expect(probe.changes == ["enabled:false", "replace:1.1.0", "uninstall:\(plugin.id)", "quit"])
    }

    @Test func registersNewActionAndStyleWithoutChangingTheWireModel() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let probe = Probe(), host = store(in: path, modules: [probe])
        let action = Probe.example
        #expect(try JSONDecoder().decode(ActionKind.self, from: Data(#""captureRegion""#.utf8)) == .captureRegion)
        #expect(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(action)) == action.rawValue)
        #expect(throws: PluginError.self) { try host.installManifest(manifest(action)) }
        var configuration = manifest(action, minimum: HostInfo.version)
        configuration.styles = ["fixture.appearance": ["version": .number(1)]]
        try host.installManifest(configuration)
        let command = PluginCommand(action: action)
        try host.saveCommand(command, pluginID: configuration.id)
        #expect(host.title(for: command) == "测试操作")
        await host.execute(command, pluginID: configuration.id)
        #expect(probe.performed == [configuration.id])
    }

    @Test func copiedImagesReachOnlyAnEnabledActiveSharingForkAndNeverCreateOne() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        var offers: [(PeripheralSharingController, Data, Int)] = []
        let sharing = SharingPluginRuntime(defaults: nil, isolated: true, forwardCopiedImage: { offers.append(($0, $1, $2)) })
        let host = store(in: path, modules: [sharing])
        let original = manifest(.sharePeripherals, id: PeripheralSharingController.pluginID)
        let fork = manifest(.sharePeripherals, id: "test.sharing-fork")
        try host.installManifest(original)
        try host.installManifest(fork)
        let data = Data([1, 2, 3])
        let originalDefaults = sharing.defaults(for: original.id), forkDefaults = sharing.defaults(for: fork.id)
        originalDefaults.set(true, forKey: "sharing.sessionEnabled")
        #expect(!forkDefaults.bool(forKey: "sharing.sessionEnabled"))
        #expect(SharingPairingKey.service(for: original.id) != SharingPairingKey.service(for: fork.id))
        host.publishRuntimeEvent(.copiedImage(data, changeCount: 10))
        #expect(offers.isEmpty && forkDefaults.string(forKey: "sharing.deviceID") == nil)
        let forkController = sharing.controller(for: fork.id, in: host)
        let key = try SharingPairingKey.generate()
        try forkController.start(key: key, localOnly: true)
        defer { forkController.stop() }
        let other = sharing.controller(for: original.id, in: host)
        #expect(throws: PluginError.self) { try other.start(key: key, localOnly: true) }
        host.publishRuntimeEvent(.copiedImage(data, changeCount: 11))
        try #require(offers.count == 1)
        #expect(offers[0].0 === forkController && offers[0].1 == data && offers[0].2 == 11)
        forkDefaults.set(true, forKey: "sharing.sessionEnabled")
        host.setEnabled(false, pluginID: fork.id)
        host.publishRuntimeEvent(.copiedImage(data, changeCount: 12))
        #expect(offers.count == 1 && !forkController.isRunning && !forkDefaults.bool(forKey: "sharing.sessionEnabled"))
        #expect(originalDefaults.bool(forKey: "sharing.sessionEnabled"))
    }

    @Test func aModuleStillGetsNotifiedWhenAnUpgradeDropsItsActions() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let probe = Probe(), host = store(in: path, modules: [probe])
        try host.installManifest(manifest(.captureRegion))
        try host.installManifest(manifest(.showMainWindow, version: "1.1.0"))
        #expect(probe.changes == ["replace:1.1.0"])
    }

    @Test func anUnwritableUpgradeDoesNotStopOrReplaceTheRunningModule() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let probe = Probe(), host = store(in: path, modules: [probe])
        let plugin = manifest(.captureRegion)
        try host.installManifest(plugin)
        let saved = path.appendingPathComponent(plugin.id + ".json")
        try FileManager.default.removeItem(at: saved)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try host.installManifest(manifest(.captureRegion, version: "1.1.0"))
        }
        #expect(probe.changes.isEmpty)
        #expect(host.installed.first?.manifest.version == "1.0.0")
    }
}
