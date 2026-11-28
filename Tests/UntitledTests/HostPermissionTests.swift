import Foundation
@preconcurrency import ScreenCaptureKit
import Testing

import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized) struct HostPermissionTests {
    @Test @MainActor func statusChecksAndPluginRequestsNeverPromptTheOS() throws {
        let system = FakeSystem()
        let center = system.center()
        let plugin = try screenshot()
        try center.validate(plugin.manifest)
        center.refresh()
        var presentations = 0
        center.presentManagement = { presentations += 1 }
        #expect(system.requests.isEmpty)
        #expect(throws: HostPermissionError.self) { try center.require([.screenRecording], for: plugin) }
        #expect(center.pendingRequest?.pluginID == plugin.id)
        #expect(center.pendingRequest?.permissions == [.screenRecording])
        #expect(center.settingsPage == .permissions)
        #expect(presentations == 1)
        #expect(system.requests.isEmpty)
        #expect(system.settingsOpened.isEmpty)
    }

    @Test @MainActor func undeclaredAndUnknownPermissionsNeverReachSystemDrivers() throws {
        let system = FakeSystem()
        let center = system.center()
        var plugin = try screenshot()
        plugin.manifest.permissions = []
        #expect(throws: PluginError.self) { try center.require([.screenRecording], for: plugin) }
        let unknown = HostPermissionID(rawValue: "example.future")
        plugin.manifest.permissions = [.init(id: unknown, reason: "Future capability")]
        #expect(throws: PluginError.self) { try center.validate(plugin.manifest) }
        #expect(throws: PluginError.self) { try center.require([unknown], for: plugin) }
        #expect(center.pendingRequest == nil)
        #expect(system.requests.isEmpty)
    }

    @Test @MainActor func optionalInsertionAccessIsLiveScopedAndNeverPresentsSettings() throws {
        let system = FakeSystem(), center = system.center()
        var plugin = try screenshot(), presentations = 0
        center.presentManagement = { presentations += 1 }
        plugin.manifest.permissions = [.init(id: .accessibility, reason: "测试", optional: true)]
        #expect(!center.isAuthorized(.accessibility, for: plugin))
        system.states[.accessibility] = .authorized
        #expect(center.isAuthorized(.accessibility, for: plugin))
        plugin.isEnabled = false
        #expect(!center.isAuthorized(.accessibility, for: plugin))
        plugin.isEnabled = true; plugin.manifest.permissions = []
        #expect(!center.isAuthorized(.accessibility, for: plugin))
        plugin.manifest.permissions = [.init(id: .accessibility, reason: "测试", optional: true)]
        system.states[.accessibility] = .denied
        #expect(!center.isAuthorized(.accessibility, for: plugin))
        #expect(center.pendingRequest == nil && presentations == 0 && system.requests.isEmpty && system.settingsOpened.isEmpty)
    }

    @Test @MainActor func grantsAndRevocationsAreAlwaysReadFromTheSystem() async throws {
        let system = FakeSystem()
        let center = system.center()
        await center.request(.screenRecording)
        #expect(system.requests == [.screenRecording])
        #expect(center.status(.screenRecording) == .authorized)
        try center.require([.screenRecording], for: screenshot())
        await center.request(.screenRecording)
        #expect(system.requests.count == 1)
        system.states[.screenRecording] = .notGranted
        #expect(throws: HostPermissionError.self) { try center.require([.screenRecording], for: screenshot()) }
        #expect(center.status(.screenRecording) == .notGranted)
        center.openSettings(.screenRecording)
        #expect(system.settingsOpened == [.screenRecording])
    }

    @Test @MainActor func pendingPromptsAreSerializedAndDeniedStatesAreNotTreatedAsGrants() async {
        let system = FakeSystem()
        system.delay = true
        let center = system.center()
        let first = Task { await center.request(.screenRecording) }
        while center.requesting == nil { await Task.yield() }
        await center.request(.camera)
        #expect(system.requests == [.screenRecording])
        #expect(center.status(.screenRecording) == .notGranted)
        system.continuation?.resume()
        system.continuation = nil
        await first.value
        #expect(center.requesting == nil)
        #expect(center.status(.screenRecording) == .authorized)
        system.states[.camera] = .restricted
        await center.request(.camera)
        #expect(system.requests == [.screenRecording])
        system.delay = false
        system.grant = false
        system.states[.microphone] = .notDetermined
        await center.request(.microphone)
        #expect(center.status(.microphone) == .denied)
        #expect(center.messages[.microphone] != nil)
        await center.request(.microphone)
        #expect(system.requests == [.screenRecording, .microphone])
    }

    @Test @MainActor func captureIsStoppedBeforeUsingTheScreenAndErrorsRouteToHostSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = FakeSystem()
        let center = system.center()
        var presentations = 0
        center.presentManagement = { presentations += 1 }
        let store = PluginStore(
            directory: directory.appendingPathComponent("Plugins"),
            captureDirectory: directory.appendingPathComponent("Images"), permissions: center)
        let plugin = try screenshot()
        try store.installManifest(plugin.manifest)
        #expect(system.requests.isEmpty)
        let command = try #require(store.installed.first(where: { $0.id == plugin.id })?.commands.first { $0.action == .captureRegion })
        await store.execute(command, pluginID: plugin.id)
        #expect(presentations == 1)
        #expect(store.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Images").path))
        #expect(center.pendingRequest?.permissions == [.screenRecording])
        #expect(system.requests.isEmpty)
        store.setEnabled(false, pluginID: plugin.id)
        #expect(throws: PluginError.self) { try store.permissionClient(for: plugin.id).require([.screenRecording]) }
    }

    @Test @MainActor func repeatedCaptureIsIgnoredBeforeHostPermissionManagement() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("CaptureHostAdmission-"+UUID().uuidString)
        let system=FakeSystem(),center=system.center()
        var continuation:CheckedContinuation<SCShareableContent,any Error>?
        let controller=ScreenshotController(directory:directory.appendingPathComponent("Images"),service:CaptureService {
            try await withCheckedThrowingContinuation { continuation=$0 }
        })
        let store=PluginStore(directory:directory.appendingPathComponent("Plugins"),permissions:center,captureFactory:{ _ in controller })
        defer { continuation?.resume(throwing:CancellationError());controller.deactivate();try? FileManager.default.removeItem(at:directory) }
        let plugin=try screenshot();try store.installManifest(plugin.manifest)
        _=store.screenshots
        let first=Task { try await controller.perform(.captureRegion,permissions:PluginPermissionClient { _ in }) }
        for _ in 0..<100 { if continuation != nil { break };try await Task.sleep(for:.milliseconds(5)) }
        #expect(controller.busy && continuation != nil)
        try await store.performScreenshot(.captureRegion,pluginID:plugin.id)
        try await store.performScreenshot(.captureRecording,pluginID:plugin.id)
        #expect(center.pendingRequest == nil && system.requests.isEmpty && store.errorMessage == nil)
        let pending=continuation;continuation=nil;pending?.resume(throwing:CancellationError())
        _=await first.result
        do { try await store.performScreenshot(.captureRegion,pluginID:plugin.id);Issue.record("A new nonbusy capture must still check authorization") }
        catch is HostPermissionError {}
        #expect(center.pendingRequest?.permissions == [.screenRecording] && system.requests.isEmpty)
    }
    @Test @MainActor func onlyEnabledRecordingOptionsRequireOptionalPermissions() {
        let name = "com.untitled.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(
            CapturePermissionRequirements.permissions(for: .captureRecording, recordingOptions: defaults) == [
                .screenRecording
            ])
        defaults.set(true, forKey: "capture.camera")
        defaults.set(true, forKey: "capture.microphone")
        defaults.set(true, forKey: "capture.keystrokes")
        #expect(
            CapturePermissionRequirements.permissions(for: .captureRecording, recordingOptions: defaults)
                == [.screenRecording, .camera, .microphone, .inputMonitoring])
        #expect(
            CapturePermissionRequirements.permissions(for: .captureScrolling, recordingOptions: defaults) == [
                .screenRecording
            ])
        #expect(CapturePermissionRequirements.permissions(for: .captureHistory, recordingOptions: defaults).isEmpty)
        #expect(CapturePermissionRequirements.permissions(for: .pinSelection, recordingOptions: defaults).isEmpty)
    }

    @Test @MainActor func oldPluginDeclarationsAreAdaptedAndExplicitEmptyListsAreRespected() throws {
        let system = FakeSystem()
        let center = system.center()
        var plugin = try screenshot()
        let expected = center.declarations(for: plugin.manifest)
        plugin.manifest.permissions = nil
        #expect(Set(center.declarations(for: plugin.manifest).map(\.id)) == Set(expected.map(\.id)))
        plugin.manifest.permissions = []
        #expect(center.declarations(for: plugin.manifest).isEmpty)
        #expect(throws: PluginError.self) { try center.require([.camera], for: plugin) }
    }

    @Test @MainActor func declarationValidationProtectsExistingInstalledConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = FakeSystem()
        let store = PluginStore(directory: directory, permissions: system.center())
        var manifest = try screenshot().manifest
        try store.installManifest(manifest)
        let original = store.installed
        manifest.permissions = [.init(id: .camera, reason: "Camera"), .init(id: .camera, reason: "Duplicate")]
        #expect(throws: PluginError.self) { try store.installManifest(manifest) }
        #expect(store.installed == original)
        manifest.permissions = [.init(id: .camera, reason: "")]
        #expect(throws: PluginError.self) { try store.installManifest(manifest) }
        manifest.permissions = nil
        #expect(throws: PluginError.self) { try store.installManifest(manifest) }
    }

    private func screenshot() throws -> InstalledPlugin {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
        return InstalledPlugin(manifest: manifest, commands: [])
    }

    @MainActor private final class FakeSystem {
        var states: [HostPermissionID: HostPermissionStatus] = [:]
        var requests: [HostPermissionID] = []
        var settingsOpened: [HostPermissionID] = []
        var delay = false
        var grant = true
        var continuation: CheckedContinuation<Void, Never>?
        func center() -> HostPermissionCenter {
            let ids: [HostPermissionID] = [.screenRecording, .accessibility, .inputMonitoring, .camera, .microphone]
            let drivers = ids.map { id in
                HostPermissionDriver(
                    descriptor: .init(id: id, title: id.rawValue, summary: "Test", symbol: "lock"),
                    status: { [self] in states[id] ?? .notGranted },
                    request: { [self] in
                        requests.append(id)
                        if delay { await withCheckedContinuation { continuation = $0 } }
                        states[id] = grant ? .authorized : .denied
                    }, openSettings: { [self] in settingsOpened.append(id) })
            }
            return HostPermissionCenter(
                drivers: drivers, legacyDeclarations: CapturePermissionRequirements.legacyDeclarations)
        }
    }
}
