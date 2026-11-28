import AppKit
import UntitledPluginSDK
import UntitledHost
import SwiftUI

struct SharingPluginView: View {
    @ObservedObject var controller: PeripheralSharingController
    @EnvironmentObject private var store: PluginStore
    private let keyAvailable: () -> Bool
    @ViewState private var hasKey = false
    @ViewState private var showSettings = false
    @ViewState private var editingKey = false
    @ViewState private var replaceKey = false
    @ViewState private var unpair = false
    @ViewState private var keyDraft = ""
    @ViewState private var notice = ""
    @ViewState private var manualHost: String
    private let manualPort: String

    init(controller: PeripheralSharingController, keyAvailable: (() -> Bool)? = nil) {
        self.controller = controller
        self.keyAvailable = keyAvailable ?? { controller.pairingKey() != nil }
        _manualHost = ViewState(wrappedValue: controller.savedPeerHost)
        manualPort = controller.savedPeerPort
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                SharingLayoutEditor(
                    localName: Host.current().localizedName ?? "这台 Mac",
                    remoteName: controller.peerName ?? controller.rememberedPeerName ?? "另一台 Mac",
                    peerOffset: Binding(get: { controller.layoutOffset }, set: { controller.setLayoutOffset($0) }),
                    localAspect: controller.localAspect, peerAspect: controller.peerAspect,
                    localPixels: controller.localPixels, peerPixels: controller.peerPixels,
                    isConnected: controller.peerName != nil, canEdit: controller.control == .local,
                    controllingRemote: controller.control == .controlling)
                    .help("拖动设备自由排列；拖动画布平移，双指缩放")
                if let inputStatus = controller.inputStatus {
                    Text(inputStatus).font(.caption).foregroundStyle(.orange)
                } else if controller.peerKeyboardMouseEnabled == false {
                    Text("对端连接仍在，键鼠暂不可用。").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.bottom, 12)
        }
        .onAppear { hasKey = keyAvailable() }
        .sheet(isPresented: $showSettings) { connectionSettings }
        .confirmationDialog("更换配对码？另一台 Mac 也需要更新。", isPresented: $replaceKey) {
            Button("生成新配对码", role: .destructive) { generateKey() }
        }
        .confirmationDialog("解除本机配对？", isPresented: $unpair) {
            Button("解除配对", role: .destructive) {
                run {
                    controller.stopUserSession()
                    try controller.deletePairingKey()
                    controller.forgetReconnectRoute()
                    hasKey = false; keyDraft = ""; notice = "已解除配对。"
                }
            }
        }
        .panelRegion("sharing.dashboard")
    }
    private var header: some View {
        HStack(spacing: 12) {
            Label(connectionLabel, systemImage: "circle.fill")
                .font(.callout).foregroundStyle(controller.isRunning && (controller.inputRecovering || !controller.keyboardMouseEnabled || controller.peerKeyboardMouseEnabled == false) ? Color.orange : (controller.peerName != nil ? .green : .secondary))
            Spacer()
            if !hasKey { Button("配对设备") { showSettings = true }.buttonStyle(.borderedProminent) }
            Toggle("共享", isOn: Binding(get: { controller.isRunning && controller.keyboardMouseEnabled }, set: { enabled in
                run { if enabled { try controller.startUserSession() } else { controller.stopUserSession() } }
            })).toggleStyle(.switch).disabled(!hasKey)
                .help("连接配对 Mac 后自动同步新复制的文字和 Untitled 截图")
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .help("连接设备").accessibilityLabel("连接设备")
        }.panelRegion("sharing.layout.header")
    }
    private var connectionLabel: String {
        if controller.inputRecovering { return "键鼠正在恢复" }
        if controller.isRunning && !controller.keyboardMouseEnabled { return "本机已暂停" }
        if controller.peerKeyboardMouseEnabled == false { return "对端键鼠暂不可用" }
        if controller.peerName != nil { return "已连接" }
        if controller.reconnecting { return "正在重连" }
        return controller.isRunning ? "等待连接" : "未连接"
    }
    private var clipboardNotice: String? {
        switch controller.clipboardStatus {
        case .unsupported: return "对端版本不支持剪贴板同步。"
        case .denied: return "macOS 已拒绝 Untitled 访问剪贴板，可在系统设置中允许。"
        case .waiting: return "等待对端剪贴板就绪。旧版对端请更新 Untitled。"
        case .active where controller.clipboardImageStatus == .unavailable:
            return "文本仍可同步；截图通道不可用，可断开后重新连接。"
        default: return nil
        }
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("连接设备").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { showSettings = false }.keyboardShortcut(.defaultAction)
            }
            if let name = controller.peerName {
                HStack { Label(name, systemImage: "desktopcomputer").lineLimit(1); Spacer(); Button("断开") { controller.disconnect() } }
                if let clipboardNotice { Text(clipboardNotice).font(.caption).foregroundStyle(.secondary) }
            } else {
                if controller.reconnecting {
                    HStack { Text("正在用原配对重连…"); Spacer(); Button("取消重连") { controller.disconnect() } }
                }
                HStack {
                    TextField("对端地址", text: $manualHost).textFieldStyle(.roundedBorder)
                    Button("连接") { run { try controller.connectUserSelected(host: manualHost, port: manualPort); showSettings = false } }
                        .disabled(!hasKey || manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !controller.peers.isEmpty {
                    ForEach(controller.peers) { peer in
                        HStack {
                            Label(peer.name, systemImage: "desktopcomputer").lineLimit(1)
                            Spacer()
                            Button("连接") { run { try controller.connect(peer); showSettings = false } }.disabled(!controller.isRunning)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Label(hasKey ? "已配对" : "设备配对", systemImage: "key")
                Spacer()
                if hasKey {
                    Menu {
                        Button("复制配对码") { copyKey() }
                        Button("输入其他配对码") { editingKey.toggle() }.disabled(controller.isRunning)
                        Button("生成新配对码") { replaceKey = true }.disabled(controller.isRunning)
                        Button("解除配对", role: .destructive) { unpair = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                }
            }
            if !hasKey || editingKey {
                HStack {
                    SecureField("粘贴配对码", text: $keyDraft).textFieldStyle(.roundedBorder)
                    Button("保存") {
                        run {
                            try controller.savePairingKey(keyDraft)
                            controller.forgetReconnectRoute()
                            keyDraft = ""; hasKey = true; editingKey = false; notice = "已配对。"
                        }
                    }
                        .disabled(keyDraft.isEmpty || controller.isRunning)
                }.disabled(controller.isRunning)
                if !hasKey { Button("生成配对码") { generateKey() }.disabled(controller.isRunning) }
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 460)
    }
    private func run(_ body: () throws -> Void) { do { try body() } catch { store.handleExecutionError(error) } }
    private func generateKey() {
        run {
            try controller.savePairingKey(SharingPairingKey.generate())
            controller.forgetReconnectRoute()
            hasKey = true; notice = "复制配对码，在另一台 Mac 保存即可。"
        }
    }
    private func copyKey() {
        guard let key = controller.pairingKey(), let changeCount = SharingSystemPasteboard.copyPairingCode(key) else {
            notice = "未能复制配对码。"; return
        }
        notice = "已复制，仅分享给可信设备。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }
}
