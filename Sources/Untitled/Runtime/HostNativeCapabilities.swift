import AppKit
import UserNotifications

@MainActor enum HostNativeCapabilities {
    static let clipboardByteLimit = 16 * 1024
    static let notificationTitleByteLimit = 240
    static let notificationBodyByteLimit = 1024

    static func revealInFinder(_ url: URL) throws {
        guard url.isFileURL else { throw PluginError.invalid("请选择本机文件或文件夹。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PluginError.invalid("文件已移动或无法访问，请重新选择。")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func readClipboard(from pasteboard: NSPasteboard = .general) throws -> String {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            throw PluginError.invalid("剪贴板中没有可读取的纯文本。")
        }
        try validateClipboardText(text)
        return text
    }

    static func copyText(_ text: String, to pasteboard: NSPasteboard = .general) throws {
        try validateClipboardText(text)
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else {
            throw PluginError.invalid("无法准备剪贴板文本，请重试。")
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw PluginError.invalid("无法写入系统剪贴板，请重试。")
        }
    }

    private static func validateClipboardText(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= clipboardByteLimit else {
            throw PluginError.invalid("剪贴板文本须为 1 字节至 16 KiB。")
        }
    }

    static func postNotification(
        title: String, body: String, permissions: HostPermissionCenter,
        deliver: @MainActor (String, String) async throws -> Void = deliverNotification
    ) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= notificationTitleByteLimit,
              body.utf8.count <= notificationBodyByteLimit else {
            throw PluginError.invalid("请输入标题，标题最多 240 字节，正文最多 1 KiB。")
        }
        let status = await permissions.systemStatus(.notifications)
        try Task.checkCancellation()
        guard status == .authorized else { throw HostPermissionError.missing }
        try await deliver(title, body)
    }

    static var notificationDriver: HostPermissionDriver {
        .init(
            descriptor: .init(id: .notifications, title: "通知", summary: "在你发送时将本地通知交给 macOS。", symbol: "bell"),
            status: { .unknown },
            request: {
                guard let center = notificationCenter else { return }
                _ = try? await center.requestAuthorization(options: [.alert])
            },
            openSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            },
            asyncStatus: {
                guard let center = notificationCenter else { return .unknown }
                switch await center.notificationSettings().authorizationStatus {
                case .authorized, .provisional: return .authorized
                case .denied: return .denied
                case .notDetermined: return .notDetermined
                default: return .unknown
                }
            })
    }

    private static var notificationCenter: UNUserNotificationCenter? {
        // Command-line builds and tests have no application bundle for UserNotifications to resolve.
        guard Bundle.main.bundleIdentifier == HostInfo.bundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return .current()
    }

    private static func deliverNotification(title: String, body: String) async throws {
        guard let center = notificationCenter else {
            throw PluginError.invalid("请从 Untitled.app 发送通知。")
        }
        center.delegate = LocalNotificationPresentation.shared
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
    }
}

private final class LocalNotificationPresentation: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = LocalNotificationPresentation()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
