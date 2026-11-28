import SwiftUI
import UntitledPluginSDK

package struct NativeCapabilityUIProvider: PluginUIProvider {
    package init() {}

    package func register(in registry: PluginUIRegistry) {
        for action in [ActionKind.revealFile, .shareFile] {
            registry.command("native.\(action.rawValue)", requiredActions: [action], presentation: { context in
                .init(title: action.title, symbol: action.symbol, isEnabled: context.plugin?.allowsAction(action) == true)
            }) { context in
                try await context.nativeCapabilities.execute(.init(action: action))
            }
        }
        for action in [ActionKind.readClipboardText, .copyText, .sendNotification] {
            registry.component("native.\(action.rawValue)", requiredActions: [action]) { context in
                AnyView(NativeCapabilityTextControl(context: context, action: action))
            }
        }
    }
}

private struct NativeCapabilityTextControl: View {
    @EnvironmentObject private var store: PluginStore
    @ViewState private var text = ""
    @ViewState private var notificationBody = ""
    @ViewState private var message: String?
    @ViewState private var request: Task<Void, Never>?
    let context: PluginUIContext
    let action: ActionKind

    private var available: Bool {
        store.installed.contains { $0.id == context.pluginID && $0.isEnabled && $0.allowsAction(action) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch action {
            case .readClipboardText:
                if !text.isEmpty { Text(text).textSelection(.enabled).lineLimit(12) }
            case .copyText:
                TextField("要复制的文本", text: bounded($text, limit: HostNativeCapabilities.clipboardByteLimit), axis: .vertical)
                    .lineLimit(2...4)
            case .sendNotification:
                TextField("通知标题", text: bounded($text, limit: NativeCapabilityInput.notificationTitleByteLimit))
                TextField("正文（可选）", text: bounded($notificationBody, limit: NativeCapabilityInput.notificationBodyByteLimit), axis: .vertical)
                    .lineLimit(1...3)
            default:
                EmptyView()
            }
            HStack(spacing: 8) {
                Button(action.title, systemImage: action.symbol, action: run)
                    .disabled(request != nil || (action != .readClipboardText && text.isEmpty))
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .disabled(!available)
        .onChange(of: available) { _, enabled in
            if !enabled {
                request?.cancel()
                text = ""
                notificationBody = ""
                message = nil
            }
        }
        .onDisappear { request?.cancel() }
    }

    private func run() {
        let client = context.nativeCapabilities
        message = nil
        switch action {
        case .readClipboardText:
            do { text = try client.readClipboardText() }
            catch { message = error.localizedDescription }
        case .copyText:
            do {
                try client.copyText(text)
                message = "已复制"
            } catch { message = error.localizedDescription }
        case .sendNotification:
            let title = text
            let body = notificationBody
            request = Task {
                defer { request = nil }
                do {
                    try await client.postNotification(title: title, body: body)
                    if !Task.isCancelled { message = "已提交给通知中心" }
                } catch is HostPermissionError {
                    message = "授权后重试"
                } catch is CancellationError {
                    return
                } catch {
                    message = error.localizedDescription
                }
            }
        default:
            break
        }
    }

    private func bounded(_ text: Binding<String>, limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { value in
            guard value.utf8.count <= limit else {
                message = "文本超过 \(limit) 字节。"
                return
            }
            text.wrappedValue = value
        })
    }
}
