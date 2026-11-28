import AppKit
import Combine
import SwiftUI

struct WirelessMicrophonePluginUIProvider: PluginUIProvider {
    @MainActor func register(in registry: PluginUIRegistry) {
        registry.component("wirelessMicrophone.dashboard", requiredActions: [.shareWirelessMicrophone]) { context in
            AnyView(WirelessMicrophoneView(controller: context.store.wirelessMicrophone(for: context.pluginID),
                                           isEnabled: context.plugin?.isEnabled == true) { context.store.handleExecutionError($0) })
        }
        registry.command("wirelessMicrophone.toggle", requiredActions: [.shareWirelessMicrophone], presentation: { context in
            let running = context.store.wirelessMicrophone(for: context.pluginID).isRunning
            return .init(title: running ? "停止无线麦" : "启动无线麦", symbol: running ? "stop.circle" : "mic")
        }, updates: {
            $0.store.wirelessMicrophone(for: $0.pluginID).objectWillChange.eraseToAnyPublisher()
        }) { context in
            try context.store.performWirelessMicrophoneAction(pluginID: context.pluginID)
        }
    }
}

private struct WirelessMicrophoneView: View {
    @ObservedObject var controller: WirelessMicrophoneController
    let isEnabled: Bool
    let reportError: (Error) -> Void
    @State private var showingPairing = false
    @State private var manualHost = ""
    @State private var copiedInstallCommand = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionSettings
                sendSettings
                receiveSettings
            }
            .padding(.bottom, 12)
            .disabled(!isEnabled)
        }
        .sheet(isPresented: $showingPairing) {
            WirelessMicrophonePairingView(controller: controller)
        }
        .onAppear { controller.refreshDevices() }
        .panelRegion("wirelessMicrophone.dashboard")
    }

    private var connectionSettings: some View {
        GroupBox("连接") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(connectionDescription, systemImage: controller.isPaired ? "link.circle.fill" : "link")
                        .foregroundStyle(controller.isPaired ? Color.green : .secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("配对设备…") { showingPairing = true }
                        .disabled(controller.isRunning)
                    Button(controller.isRunning ? "停止" : "启动无线麦") {
                        if controller.isRunning { controller.stop() }
                        else { attempt { try controller.start() } }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let issue = controller.connectionIssue {
                    Text(issue).font(.callout).foregroundStyle(.orange)
                }
                if controller.connection == .listening {
                    ForEach(controller.peers) { peer in
                        HStack {
                            Label(peer.name, systemImage: "desktopcomputer").lineLimit(1)
                            Spacer()
                            Button("连接") { attempt { try controller.connect(peer.endpoint) } }
                        }
                    }
                    HStack {
                        TextField("另一台 Mac 的 IP 地址或主机名", text: $manualHost)
                            .textFieldStyle(.roundedBorder)
                        Button("连接") { attempt { try controller.connect(host: manualHost) } }
                            .disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else if controller.isPaired || controller.connection == .connecting {
                    Button(controller.isPaired ? "断开" : "取消连接") { controller.disconnect() }
                }
            }
            .padding(.top, 4)
        }
    }

    private var sendSettings: some View {
        GroupBox("发送") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("允许发送本机麦克风", isOn: Binding(get: { controller.sendEnabled }, set: { controller.setSending($0) }))
                    .toggleStyle(.switch).disabled(!controller.isPaired)
                HStack {
                    Picker("输入", selection: Binding(get: { controller.inputUID }, set: { controller.selectInput($0) })) {
                        Text("默认实体麦克风").tag("")
                        if !controller.inputUID.isEmpty, !controller.inputs.contains(where: { $0.id == controller.inputUID }) {
                            Text("已保存的设备不可用").tag(controller.inputUID)
                        }
                        ForEach(controller.inputs) { device in Text(device.name).tag(device.id) }
                    }
                    Button("刷新设备") { controller.refreshDevices() }.fixedSize()
                }
                if let issue = controller.sendIssue {
                    Text(issue).font(.callout).foregroundStyle(.orange)
                } else if controller.sendEnabled {
                    Text(controller.isSending ? "正在发送本机声音" : "等待对端应用使用虚拟麦克风")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    private var receiveSettings: some View {
        GroupBox("接收") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("在这台 Mac 使用对端麦克风", isOn: Binding(get: { controller.receiveEnabled }, set: { controller.setReceiving($0) }))
                    .toggleStyle(.switch).disabled(!controller.isPaired || controller.virtualInputName == nil)
                if let name = controller.virtualInputName {
                    Text("在会议或录音软件的输入设备中选择 \(name)。")
                        .font(.callout).foregroundStyle(.secondary)
                    if controller.receiveEnabled && controller.demandSent {
                        Text(controller.isReceiving ? "正在接收对端声音" : "等待对端发送麦克风")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("要在本机接收声音，请先安装虚拟麦克风。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let installer = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "PeripheralAudio") {
                        Button(copiedInstallCommand ? "已复制安装命令" : "复制安装命令") {
                            let path = installer.path.replacingOccurrences(of: "'", with: "'\\''")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("sudo '\(path)' install", forType: .string)
                            copiedInstallCommand = true
                        }
                        Text("在终端运行该命令，随后重启 Mac。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let issue = controller.receiveIssue {
                    Text(issue).font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        }
    }

    private var connectionDescription: String {
        switch controller.connection {
        case .stopped: "未启动"
        case .opening: "正在启动局域网发现"
        case .listening: "尚未连接"
        case .connecting: "正在认证对端"
        case .paired(let name): "已连接 \(name)"
        }
    }

    private func attempt(_ operation: () throws -> Void) {
        do { try operation() } catch { reportError(error) }
    }
}

private struct WirelessMicrophonePairingView: View {
    @ObservedObject var controller: WirelessMicrophoneController
    @Environment(\.dismiss) private var dismiss
    @State private var hasPairing = false
    @State private var draft = ""
    @State private var notice: String?
    @State private var showingForgetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("配对设备").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("在一台 Mac 生成配对码，复制后在另一台 Mac 粘贴并保存。")
                .foregroundStyle(.secondary)
            HStack {
                SecureField("粘贴配对码", text: $draft).textFieldStyle(.roundedBorder)
                Button("保存") { update { try controller.savePairingKey(draft) } }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                if hasPairing {
                    Button("复制配对码") { copyKey() }
                    Spacer()
                    Button("解除配对…", role: .destructive) { showingForgetConfirmation = true }
                } else {
                    Button("生成配对码") { update { try controller.savePairingKey(SharingPairingKey.generate()) } }
                }
            }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(24)
        .frame(width: 450)
        .onAppear { update { } }
        .confirmationDialog("解除这台 Mac 的配对？", isPresented: $showingForgetConfirmation) {
            Button("解除配对", role: .destructive) { update { try controller.forgetPairing() } }
        }
    }

    private func update(_ operation: () throws -> Void) {
        do {
            try operation()
            hasPairing = try controller.pairingKey() != nil
            draft = ""
            notice = hasPairing ? "配对码已保存在钥匙串。" : nil
        } catch { notice = error.localizedDescription }
    }

    private func copyKey() {
        do {
            guard let code = try controller.pairingKey() else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(code, forType: .string)
            let changeCount = pasteboard.changeCount
            notice = "已复制配对码。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
            }
        } catch { notice = error.localizedDescription }
    }
}
