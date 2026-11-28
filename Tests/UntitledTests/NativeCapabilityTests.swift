import AppKit
import Testing

@testable import Untitled

@Suite(.serialized) struct NativeCapabilityTests {
    @Test @MainActor func clipboardRoundTripAndOversizeWritePreservesTheExistingValue() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(throws: PluginError.self) { try HostNativeCapabilities.readClipboard(from: pasteboard) }
        let text = "Untitled 原生能力\nmacOS 🔔"
        try HostNativeCapabilities.copyText(text, to: pasteboard)
        #expect(try HostNativeCapabilities.readClipboard(from: pasteboard) == text)

        let oversize = String(repeating: "字", count: HostNativeCapabilities.clipboardByteLimit / 3 + 1)
        #expect(throws: PluginError.self) { try HostNativeCapabilities.copyText(oversize, to: pasteboard) }
        #expect(try HostNativeCapabilities.readClipboard(from: pasteboard) == text)

        pasteboard.clearContents()
        #expect(pasteboard.setString(oversize, forType: .string))
        #expect(throws: PluginError.self) { try HostNativeCapabilities.readClipboard(from: pasteboard) }
    }

    @Test @MainActor func finderRequiresALocalExistingSelection() {
        let remoteURL = URL(string: "https://example.com/example")!
        let missingFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        #expect(throws: PluginError.self) { try HostNativeCapabilities.revealInFinder(remoteURL) }
        #expect(throws: PluginError.self) { try HostNativeCapabilities.revealInFinder(missingFile) }
    }

    @Test @MainActor func notificationRechecksAuthorizationBeforeEverySubmission() async throws {
        var status: HostPermissionStatus = .notDetermined
        var prompts = 0
        var deliveries: [String] = []
        let center = HostPermissionCenter(drivers: [
            .init(
                descriptor: .init(id: .notifications, title: "通知", summary: "Test", symbol: "bell"),
                status: { .unknown },
                request: { prompts += 1; status = .authorized },
                openSettings: {},
                asyncStatus: { status }),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory, permissions: center)
        let plugin = manifest(id: "dev.example.notifications", actions: [.sendNotification], permissions: [notificationPermission])
        try store.installManifest(plugin)
        center.presentPluginManagement = { [weak store] in store?.showPluginAccess($0) }
        func post(_ title: String) async throws {
            try await store.nativeCapabilities(for: plugin.id).postNotification(title: title, body: "正文") { title, body in
                deliveries.append(title + body)
            }
        }

        #expect(center.status(.notifications) == .unknown)
        await #expect(throws: HostPermissionError.self) { try await post("通知") }
        #expect(center.status(.notifications) == .notDetermined)
        #expect(store.accessSelection?.id == plugin.id)
        #expect(center.pendingRequest?.permissions == [.notifications])
        #expect(prompts == 0)
        #expect(deliveries.isEmpty)

        await center.request(.notifications)
        #expect(prompts == 1)
        #expect(center.status(.notifications) == .authorized)
        await #expect(throws: PluginError.self) { try await post(" \n ") }
        try await post(" 通知 ")
        #expect(deliveries == ["通知正文"])

        status = .denied
        await #expect(throws: HostPermissionError.self) { try await post("通知") }
        #expect(center.status(.notifications) == .denied)
        #expect(deliveries == ["通知正文"])
        #expect(prompts == 1)
    }

    @Test @MainActor func capabilityRequiresDeclarationAndLocalChoiceSurvivesReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let store = PluginStore(directory: directory, permissions: .init(drivers: []))
        let reader = manifest(id: "dev.example.reader", actions: [.readClipboardText])
        let writer = manifest(id: "dev.example.writer", actions: [.copyText])
        try store.installManifest(reader)
        try store.installManifest(writer)
        let client = store.nativeCapabilities(for: writer.id)
        try client.copyText("  保留空格\n", to: pasteboard)
        #expect(try store.nativeCapabilities(for: reader.id).readClipboardText(from: pasteboard) == "  保留空格\n")
        #expect(throws: PluginError.self) { try client.readClipboardText(from: pasteboard) }

        store.setNativeActionAllowed(false, action: .copyText, pluginID: writer.id)
        #expect(throws: CancellationError.self) { try client.copyText("stale", to: pasteboard) }
        let reloaded = PluginStore(directory: directory, permissions: .init(drivers: []))
        #expect(throws: PluginError.self) { try reloaded.nativeCapabilities(for: writer.id).copyText("blocked", to: pasteboard) }
        #expect(try reloaded.nativeCapabilities(for: reader.id).readClipboardText(from: pasteboard) == "  保留空格\n")
        reloaded.setNativeActionAllowed(true, action: .copyText, pluginID: writer.id)
        try reloaded.nativeCapabilities(for: writer.id).copyText("restored", to: pasteboard)
        #expect(try reloaded.nativeCapabilities(for: reader.id).readClipboardText(from: pasteboard) == "restored")
    }

    @Test @MainActor func pluginStopInvalidatesAnInFlightNotificationEvenIfReenabled() async throws {
        var query: CheckedContinuation<HostPermissionStatus, Never>?
        var delivered = false
        let center = HostPermissionCenter(drivers: [
            .init(descriptor: .init(id: .notifications, title: "通知", summary: "Test", symbol: "bell"),
                  status: { .unknown }, request: {}, openSettings: {},
                  asyncStatus: { await withCheckedContinuation { query = $0 } }),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory, permissions: center)
        let plugin = manifest(id: "dev.example.lifecycle", actions: [.sendNotification], permissions: [notificationPermission])
        try store.installManifest(plugin)
        let client = store.nativeCapabilities(for: plugin.id)
        let operation = Task {
            try await client.postNotification(title: "测试") { _, _ in delivered = true }
        }
        while query == nil { await Task.yield() }
        store.setEnabled(false, pluginID: plugin.id)
        store.setEnabled(true, pluginID: plugin.id)
        query?.resume(returning: .authorized)
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!delivered)
    }

    @Test @MainActor func nativeDeclarationRequiresHostVersionAndNotificationPermission() throws {
        let registry = PluginComposition.makeUIRegistry()
        let reader = manifest(id: "dev.example.reader", actions: [.readClipboardText], component: "native.readClipboardText")
        try reader.validate()
        try registry.validate(reader)
        let mismatched = manifest(id: "dev.example.reader", actions: [.copyText], component: "native.readClipboardText")
        #expect(throws: PluginError.self) { try registry.validate(mismatched) }
        #expect(throws: PluginError.self) {
            try manifest(id: reader.id, actions: [.readClipboardText], minimum: "0.13.51").validate()
        }
        #expect(throws: PluginError.self) {
            try manifest(id: reader.id, actions: [.sendNotification]).validate()
        }
        #expect(registry.commands["native.revealFile"]?.requiredActions == [.revealFile])
        #expect(registry.commands["native.shareFile"]?.requiredActions == [.shareFile])
    }

    private var notificationPermission: PluginPermissionDeclaration {
        .init(id: .notifications, reason: "发送测试通知")
    }

    private func manifest(id: String, actions: [ActionKind], permissions: [PluginPermissionDeclaration] = [],
                          minimum: String = HostInfo.nativeCapabilityVersion, component: String = "host.commands") -> PluginManifest {
        .init(schemaVersion: 2, id: id, name: "测试", version: "1.0.0", summary: "Test", author: "Test",
              repository: URL(string: "https://github.com/example/native-test")!, minimumHostVersion: minimum,
              actions: actions, templates: [], ui: .init(slots: ["content": [.component("tool", component)]]),
              permissions: permissions)
    }
}
