import AppKit
import Testing

import UntitledPluginSDK
@testable import UntitledHost

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
        func post(_ title: String) async throws {
            try await HostNativeCapabilities.postNotification(title: title, body: "正文", permissions: center) { title, body in
                deliveries.append(title + body)
            }
        }

        #expect(center.status(.notifications) == .unknown)
        await #expect(throws: HostPermissionError.self) { try await post("通知") }
        #expect(center.status(.notifications) == .notDetermined)
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
}
