import AppKit
import Combine
import SwiftUI
import UntitledHost
import UntitledPluginSDK

struct WirelessMicrophonePluginUIProvider: PluginUIProvider {
    let runtime: WirelessMicrophonePluginRuntime

    @MainActor func register(in registry: PluginUIRegistry) {
        registry.component("wirelessMicrophone.dashboard", requiredActions: [.shareWirelessMicrophone]) { context in
            AnyView(WirelessMicrophoneView(controller: runtime.controller(for: context.pluginID, in: context.store),
                                          isEnabled: context.plugin?.isEnabled == true,
                                          needsUpgrade: !Self.declaresBluetooth(context)) {
                context.store.handleExecutionError($0)
            })
        }
        registry.command("wirelessMicrophone.toggle", requiredActions: [.shareWirelessMicrophone], presentation: { context in
            let active = runtime.controller(for: context.pluginID, in: context.store).isRunning
            return .init(title: active ? "停止无线麦" : "查找小米遥控器", symbol: active ? "stop.circle" : "mic",
                         isEnabled: Self.declaresBluetooth(context))
        }, updates: {
            runtime.controller(for: $0.pluginID, in: $0.store).objectWillChange.eraseToAnyPublisher()
        }) { context in
            try runtime.toggle(pluginID: context.pluginID, in: context.store)
        }
    }

    @MainActor private static func declaresBluetooth(_ context: PluginUIContext) -> Bool {
        context.plugin?.manifest.permissions?.contains(where: { $0.id == .bluetooth }) == true
    }
}

private struct WirelessMicrophoneView: View {
    @ObservedObject var controller: WirelessMicrophoneController
    let isEnabled: Bool
    let needsUpgrade: Bool
    let reportError: (Error) -> Void
    @State private var copiedInstallCommand = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if needsUpgrade {
                    Label("通过「插件商店 → 从 ZIP 安装」更新无线麦，启用小米遥控器连接。", systemImage: "arrow.down.circle")
                        .font(.callout)
                } else {
                    connection
                    voice
                }
            }
            .padding(.bottom, 12)
            .disabled(!isEnabled)
        }
        .onAppear { if !needsUpgrade { controller.refreshAudioDevice() } }
        .panelRegion("wirelessMicrophone.dashboard")
    }

    private var connection: some View {
        GroupBox("小米遥控器") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(connectionStatus, systemImage: connected ? "link.circle.fill" : "dot.radiowaves.left.and.right")
                        .lineLimit(1)
                    Spacer()
                    connectionControls
                }
                if !connected {
                    Text("支持小米蓝牙遥控器 2 和 2 Pro。首次连接时，同时长按遥控器的主页键和菜单键，然后在下方选择遥控器。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let code = controller.pairingCode {
                    pairingPrompt(code)
                }
                if let issue = controller.issue {
                    Text(issue).font(.callout).foregroundStyle(.orange)
                }
                if controller.connection == .discovering || controller.connection == .choosing {
                    ForEach(controller.devices) { device in
                        HStack {
                            Label(device.name, systemImage: "av.remote").lineLimit(1)
                            if device.needsPairing {
                                Text("首次配对").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("连接") { attempt { try controller.connect(device.id) } }
                                .accessibilityLabel("连接 \(device.name)")
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var connectionControls: some View {
        switch controller.connection {
        case .idle, .choosing:
            Button("查找遥控器") { attempt { try controller.discover() } }
                .buttonStyle(.borderedProminent)
            if controller.isRunning { Button("关闭") { controller.stop() } }
        case .discovering:
            Button("停止查找") { controller.stop() }
        case .pairing, .connecting:
            Button("取消连接") { controller.stop() }
        case .connected:
            Button("断开") { controller.stop() }
        }
    }

    @ViewBuilder private func pairingPrompt(_ code: XiaomiRemotePairingCode) -> some View {
        switch code {
        case .compare:
            VStack(alignment: .leading, spacing: 8) {
                Text("请核对配对码 \(code.digits)。")
                HStack {
                    Button("配对码一致") { attempt { try controller.confirmPairingCode(true) } }
                    Button("取消配对") { attempt { try controller.confirmPairingCode(false) } }
                }
            }
        case .enterOnRemote:
            Text("请在遥控器上输入配对码 \(code.digits)。")
        }
    }

    private var voice: some View {
        GroupBox("按住说话") {
            VStack(alignment: .leading, spacing: 10) {
                Label(controller.isTalking ? "正在接收遥控器语音" : "按住遥控器的语音键说话，松开结束。",
                      systemImage: controller.isTalking ? "mic.fill" : "mic")
                    .foregroundStyle(controller.isTalking ? Color.accentColor : .secondary)
                ProgressView(value: controller.level)
                    .accessibilityLabel("遥控器输入电平")
                if let name = controller.inputName {
                    Text("在录音、会议或听写软件中选择 \(name) 作为麦克风。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("上方电平可以直接试音。要给其他应用输入声音，请安装 Untitled 虚拟麦克风。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let installer = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "PeripheralAudio") {
                        Button(copiedInstallCommand ? "已复制安装命令" : "复制安装命令") {
                            let path = installer.path.replacingOccurrences(of: "'", with: "'\\''")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("sudo '\(path)' install", forType: .string)
                            copiedInstallCommand = true
                        }
                        Text("在终端执行后重启 Mac。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let outputIssue = controller.outputIssue {
                    Text(outputIssue).font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        }
    }

    private var connected: Bool {
        if case .connected = controller.connection { return true }
        return false
    }

    private var connectionStatus: String {
        switch controller.connection {
        case .idle: "未连接"
        case .discovering: "正在查找遥控器"
        case .choosing: controller.devices.isEmpty ? "未找到附近的小米遥控器" : "请选择遥控器"
        case .pairing(let name): "正在配对 \(name)"
        case .connecting(let name): "正在连接 \(name)"
        case .connected(let name): "已连接 \(name)"
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { reportError(error) }
    }
}
