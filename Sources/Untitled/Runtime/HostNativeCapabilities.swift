import AppKit
import UserNotifications

@MainActor enum HostNativeCapabilities {
    nonisolated static let clipboardByteLimit = 16 * 1024
    nonisolated static let notificationTitleByteLimit = 240
    nonisolated static let notificationBodyByteLimit = 1024

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

    nonisolated static func validateClipboardText(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= clipboardByteLimit else {
            throw PluginError.invalid("剪贴板文本须为 1 字节至 16 KiB。")
        }
    }

    nonisolated static func notificationTitle(_ title: String, body: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= notificationTitleByteLimit,
              body.utf8.count <= notificationBodyByteLimit else {
            throw PluginError.invalid("请输入标题，标题最多 240 字节，正文最多 1 KiB。")
        }
        return title
    }

    static var notificationDriver: HostPermissionDriver {
        .init(
            descriptor: .init(id: .notifications, title: "通知", summary: "允许 Untitled 将插件发送的本地通知交给 macOS。", symbol: "bell"),
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

    fileprivate static func deliverNotification(title: String, body: String) async throws {
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

@MainActor struct PluginNativeCapabilityClient {
    let pluginID: String
    let permissions: HostPermissionCenter
    let filePicker: NativeFilePicker
    let currentPlugin: (ActionKind) throws -> InstalledPlugin
    let presentFilePicker: () -> Void

    func readClipboardText(from pasteboard: NSPasteboard = .general) throws -> String {
        _ = try currentPlugin(.readClipboardText)
        return try HostNativeCapabilities.readClipboard(from: pasteboard)
    }

    func copyText(_ text: String, to pasteboard: NSPasteboard = .general) throws {
        _ = try currentPlugin(.copyText)
        try HostNativeCapabilities.copyText(text, to: pasteboard)
    }

    func revealFile(_ url: URL) throws {
        _ = try currentPlugin(.revealFile)
        try HostNativeCapabilities.revealInFinder(url)
    }

    func shareFile(_ url: URL) throws {
        _ = try currentPlugin(.shareFile)
        try filePicker.presentSharePicker(for: url, pluginID: pluginID)
    }

    func chooseAndRevealFile() async throws {
        if let url = try await chooseFile(for: .revealFile) { try revealFile(url) }
    }

    func chooseAndShareFile() async throws {
        if let url = try await chooseFile(for: .shareFile) { try shareFile(url) }
    }

    func postNotification(
        title: String, body: String = "",
        deliver: @MainActor (String, String) async throws -> Void = HostNativeCapabilities.deliverNotification
    ) async throws {
        let title = try HostNativeCapabilities.notificationTitle(title, body: body)
        try await permissions.requireAsynchronously(.notifications) { try currentPlugin(.sendNotification) }
        try Task.checkCancellation()
        try await deliver(title, body)
    }

    func execute(_ command: PluginCommand) async throws {
        switch command.action {
        case .revealFile: try await chooseAndRevealFile()
        case .shareFile: try await chooseAndShareFile()
        case .copyText: try copyText(command.target)
        case .sendNotification: try await postNotification(title: command.target)
        default: throw PluginError.invalid("此能力需要由插件组件调用。")
        }
    }

    private func chooseFile(for action: ActionKind) async throws -> URL? {
        _ = try currentPlugin(action)
        try Task.checkCancellation()
        presentFilePicker()
        let url = try await filePicker.chooseFile(for: pluginID, title: action.title, directoriesAllowed: action == .revealFile)
        try Task.checkCancellation()
        return url
    }
}

@MainActor final class NativeFilePicker: NSObject, NSSharingServicePickerDelegate {
    private struct Selection {
        let id: UUID
        let pluginID: String
        let panel: NSOpenPanel
    }
    private var selection: Selection?
    private var sharing: (pluginID: String, picker: NSSharingServicePicker)?

    func chooseFile(for pluginID: String, title: String, directoriesAllowed: Bool) async throws -> URL? {
        guard selection == nil else { throw PluginError.invalid("请先完成已打开的文件选择。") }
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = directoriesAllowed
        panel.allowsMultipleSelection = false
        let id = UUID()
        selection = .init(id: id, pluginID: pluginID, panel: panel)
        defer { selection = nil }
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                panel.begin { response in continuation.resume(returning: response) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.selection?.id == id { self?.selection?.panel.cancel(nil) }
            }
        }
        return response == .OK ? panel.url : nil
    }

    func presentSharePicker(for url: URL, pluginID: String) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw PluginError.invalid("请选择仍可访问的本机文件。")
        }
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else {
            throw PluginError.invalid("请打开插件面板后重试分享。")
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        sharing = (pluginID, picker)
        picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view,
                    preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let pickerID = ObjectIdentifier(picker)
        Task { @MainActor [weak self] in
            if let picker = self?.sharing?.picker, ObjectIdentifier(picker) == pickerID { self?.sharing = nil }
        }
    }

    func cancel(for pluginID: String? = nil) {
        if pluginID == nil || selection?.pluginID == pluginID { selection?.panel.cancel(nil) }
        if pluginID == nil || sharing?.pluginID == pluginID { sharing = nil }
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
