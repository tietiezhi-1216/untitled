import AppKit
import SwiftUI

struct NativeCapabilitiesView: View {
    private enum Page: String, CaseIterable {
        case tools = "工具"
        case plugins = "插件能力"
        case pending = "待接入"
    }

    @EnvironmentObject private var store: PluginStore
    @ViewState private var page: Page = .tools
    let openStore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("原生能力").font(.system(size: 28, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .panelWindowDragArea()
                Spacer()
                Button("权限管理", systemImage: "hand.raised") { store.permissions.reveal() }
                    .panelGlassButton()
            }
            .padding(.top, 64)
            .padding(.bottom, 16)
            .padding(.horizontal, PanelLayout.contentInset)

            Picker("原生能力页面", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PanelLayout.contentInset)
            .padding(.bottom, 16)

            PanelDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .tools: NativeCapabilityTools(permissions: store.permissions)
                    case .plugins: pluginCapabilities
                    case .pending: pendingCapabilities
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PanelLayout.contentInset)
                .padding(.vertical, 20)
            }
        }
        .panelRegion("host.nativeCapabilities")
    }

    private var pluginCapabilities: some View {
        ForEach(Self.pluginGroups, id: \.title) { group in
            let plugins = store.installed.filter { plugin in
                plugin.manifest.actions.contains { group.actions.contains($0) }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.summary).font(.callout).foregroundStyle(.secondary)
                    if plugins.isEmpty {
                        Button("浏览插件商店", action: openStore)
                    } else {
                        ForEach(plugins) { plugin in
                            Button(store.presentation(for: plugin.manifest).name, systemImage: "arrow.up.forward") {
                                store.requestedPluginID = plugin.id
                            }
                        }
                    }
                    DisclosureGroup("已接入的动作") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(group.actions, id: \.self) { action in
                                Label(action.title, systemImage: action.symbol).font(.callout)
                            }
                        }
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Label(group.title, systemImage: group.symbol) }
        }
    }

    private var pendingCapabilities: some View {
        ForEach(Self.gaps, id: \.title) { gap in
            GroupBox {
                Text(gap.summary).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: { Label(gap.title, systemImage: gap.symbol) }
        }
    }

    private static let pluginGroups: [(title: String, symbol: String, summary: String, actions: [ActionKind])] = [
        ("应用与快捷指令", "command", "启动应用、打开网页、运行 macOS 快捷指令及全局热键。",
         [.openApplication, .openURL, .runShortcut, .showMainWindow]),
        ("屏幕、图像与录制", "display", "截图、长截图、贴图和录屏，支持本地 OCR、摄像头画中画及音频选项。",
         ActionKind.allCases.filter(\.isScreenshotAction)),
        ("麦克风与听写", "mic", "语音输入插件可用麦克风听写并处理定稿。",
         [.toggleDoubaoDictation, .holdDoubaoDictation, .cancelDoubaoDictation]),
        ("外设与局域网", "network", "经过配对的 Mac 可以共享键鼠，按需同步麦克风。",
         [.sharePeripherals, .switchPeripheralControl, .stopPeripheralSharing]),
    ]

    private static let gaps: [(title: String, symbol: String, summary: String)] = [
        ("目录与磁盘访问", "folder", "持续的目录授权、文件批处理与完全磁盘访问管理。"),
        ("跨应用自动化", "macwindow", "按目标应用处理 Apple Events 授权及自动化动作。"),
        ("系统个人数据", "person.crop.circle", "日历、提醒事项、通讯录与系统照片图库。"),
        ("定位与外部设备", "location", "定位、蓝牙、USB 与其他设备的通用接口。"),
        ("本地执行与委托", "terminal", "带执行范围和停止入口的进程、Shell、外部插件与 agent 委托。"),
    ]
}

private struct NativeCapabilityTools: View {
    @ObservedObject var permissions: HostPermissionCenter
    @ViewState private var selectedFile: URL?
    @ViewState private var clipboardText = ""
    @ViewState private var notificationTitle = ""
    @ViewState private var notificationBody = ""
    @ViewState private var notificationTask: Task<Void, Never>?
    @ViewState private var statusMessage: String?
    @ViewState private var error: String?

    var body: some View {
        Group {
            fileTools
            clipboardTools
            notificationTools
        }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var fileTools: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let selectedFile {
                    Text(selectedFile.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("选择文件或文件夹…", action: chooseFile)
                    if let selectedFile {
                        Button("在 Finder 中定位") {
                            perform { try HostNativeCapabilities.revealInFinder(selectedFile) }
                        }
                        ShareLink(item: selectedFile) { Label("分享…", systemImage: "square.and.arrow.up") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 5)
        } label: { Label("文件", systemImage: "folder") }
    }

    private var clipboardTools: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("纯文本（最多 16 KiB）", text: bounded($clipboardText, limit: HostNativeCapabilities.clipboardByteLimit), axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityLabel("剪贴板文本")
                HStack {
                    Button("读取剪贴板") { perform { clipboardText = try HostNativeCapabilities.readClipboard() } }
                    Button("复制到剪贴板") {
                        perform { try HostNativeCapabilities.copyText(clipboardText) }
                    }
                    .disabled(clipboardText.isEmpty)
                }
            }
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("文本剪贴板", systemImage: "doc.on.clipboard") }
    }

    private var notificationTools: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("通知标题", text: bounded($notificationTitle, limit: HostNativeCapabilities.notificationTitleByteLimit))
                TextField("正文（可选）", text: bounded($notificationBody, limit: HostNativeCapabilities.notificationBodyByteLimit), axis: .vertical)
                    .lineLimit(1...3)
                HStack {
                    Button("发送通知", action: sendNotification)
                        .disabled(notificationTask != nil || notificationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(statusMessage ?? permissions.status(.notifications).title)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("本地通知", systemImage: "bell") }
        .task { _ = await permissions.systemStatus(.notifications) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { _ = await permissions.systemStatus(.notifications) }
        }
        .onDisappear { notificationTask?.cancel() }
    }

    private func bounded(_ text: Binding<String>, limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { input in
            guard input.utf8.count <= limit else {
                error = "文本超过了 \(limit) 字节，请缩短后重试。"
                return
            }
            text.wrappedValue = input
        })
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "选择要定位或分享的文件"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK { selectedFile = panel.url }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }

    private func sendNotification() {
        let title = notificationTitle
        let body = notificationBody
        statusMessage = nil
        notificationTask = Task {
            defer { notificationTask = nil }
            do {
                try await HostNativeCapabilities.postNotification(title: title, body: body, permissions: permissions)
                statusMessage = "已提交给通知中心"
            } catch is HostPermissionError {
                permissions.reveal()
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
