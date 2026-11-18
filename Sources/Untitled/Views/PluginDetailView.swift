import SwiftUI

struct PluginDetailView: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.pluginContentHasInsets) private var hasInsets
    @ViewState private var editingCommand: PluginCommand?
    let pluginID: String

    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == pluginID }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(plugin.commands) { command in
                        commandRow(command, plugin: plugin)
                    }
                }
            }
            .safeAreaInset(edge:.top,spacing:8) {
                if plugin.isEnabled,store.priorityHotKeysEnabled,store.priorityHotKeyRecoveryNeeded,
                   plugin.commands.contains(where:{ $0.isEnabled && $0.hotKey != nil }) {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment:.leading,spacing:4) {
                            Text("优先快捷键暂不可用").font(.callout.weight(.medium))
                            Text(store.priorityHotKeyStatus ?? "请检查辅助功能授权并重试。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("临时故障会有限重试；返回应用、解锁或唤醒时也会尝试恢复。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:8)
                        Button("重试") { store.retryHotKeys() }.buttonStyle(.bordered)
                    }
                    .padding(.horizontal,hasInsets ? 0:PanelLayout.contentInset).padding(.vertical,8)
                    .accessibilityIdentifier("commands.priorityRecovery")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if plugin.commands.isEmpty {
                    ContentUnavailableView(
                        "还没有操作", systemImage: "keyboard",
                        description: Text("点击右上方“添加操作”，选择应用或要执行的事情。")
                    )
                }
            }

            .sheet(item: $editingCommand) { command in
                CommandEditor(pluginID: pluginID, command: command, actions: plugin.manifest.actions)
                    .environmentObject(store)
            }
        }
    }

    private func commandRow(_ command: PluginCommand, plugin: InstalledPlugin) -> some View {
        HStack(spacing: PanelLayout.itemSpacing) {
            PanelIcon(symbol: command.action.symbol)
            VStack(alignment: .leading, spacing: 6) {
                Text(command.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(command.title)
                Text(commandDescription(command) + (command.isEnabled ? "" : " · 已停用"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                if let error = store.hotKeyErrors[command.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PanelLayout.itemSpacing)
            Text(command.hotKey?.display ?? "未设快捷键")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
            HStack(spacing: 8) {
                Button {
                    Task { await store.execute(command, pluginID: pluginID) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .frame(width: 16)
                }
                .help("执行 \(command.title)")
                .accessibilityLabel("执行 \(command.title)")
                .disabled(!plugin.isEnabled || !command.isEnabled || !command.isConfigured)
                Button("编辑") { editingCommand = command }
            }
            .panelGlassButton()
            .fixedSize()
        }
        .padding(.horizontal, hasInsets ? 0 : PanelLayout.contentInset)
        .padding(.vertical, PanelLayout.rowInset)
        .accessibilityElement(children: .contain)
        .panelRegion("command.\(command.id.uuidString)")
        .contextMenu {
            Button("删除操作", role: .destructive) { store.removeCommand(command.id, pluginID: pluginID) }
        }
    }

    private func commandDescription(_ command: PluginCommand) -> String {
        switch command.action {
        case .openApplication:
            "打开应用"
        case .openURL:
            command.target.isEmpty ? "尚未设置网址" : command.target
        case .runShortcut:
            "运行 macOS 快捷指令"
        case .showMainWindow:
            "将工具箱主窗口带到前台"
        case .sharePeripherals, .switchPeripheralControl, .stopPeripheralSharing:
            "已配对 Mac 的键鼠共享操作"
        default:
            "全局截图操作"
        }
    }
}

enum PluginHeaderControl { case enabled, more, info }

struct PluginHeaderControlView: View {
    let control: PluginHeaderControl
    @EnvironmentObject private var store: PluginStore
    @ViewState private var confirmUninstall = false
    @ViewState private var showingInfo = false
    let plugin: InstalledPlugin

    var body: some View {
        Group {
            if control == .enabled {
                Toggle(
                    "启用",
                    isOn: Binding(
                        get: { plugin.isEnabled },
                        set: { store.setEnabled($0, pluginID: plugin.id) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("启用插件")
                .panelRegion("plugin.header.enabled")

            } else if control == .more {
                Menu {
                    Link("查看源码", destination: plugin.manifest.repository)
                    Divider()
                    Button("卸载插件…", role: .destructive) { confirmUninstall = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.4), in: Circle())
                .help("插件更多操作")
                .accessibilityLabel("插件更多操作")
                .panelRegion("plugin.header.more")

            } else if control == .info {
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 15))
                        .frame(width: 18, height: 18)
                }
                .panelGlassButton(circular: true)
                .help("查看插件说明与信息")
                .accessibilityLabel("插件详情")
                .panelRegion("plugin.header.info")
                .sheet(isPresented: $showingInfo) {
                    PluginStoreDetailView(item: .installed(plugin, store: store), goBack: { showingInfo = false }) { id in
                        showingInfo = false
                        store.requestedPluginID = id
                    }
                    .environmentObject(store).frame(width: 760, height: 660)
                }
            }
        }
        .fixedSize()
        .confirmationDialog("卸载「\(store.presentation(for: plugin.manifest).name)」？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { store.uninstall(plugin.id) }
        } message: {
            Text("将移除该插件的本地配置，并释放全部快捷键。")
        }
    }

}

struct PluginAddCommandView: View {
    @EnvironmentObject private var store: PluginStore
    @ViewState private var editingCommand: PluginCommand?
    let pluginID: String
    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == pluginID }) {
            Menu {
                if plugin.manifest.templates.isEmpty {
                    ForEach(plugin.manifest.actions, id: \.self) { action in
                        Button(action.title) { editingCommand = PluginCommand(action: action) }
                    }
                } else {
                    ForEach(plugin.manifest.templates) { template in
                        Button(template.title) { editingCommand = PluginCommand(action: template.action) }
                    }
                }
            } label: {
                Label("添加操作", systemImage: "plus")
            }
            .panelGlassButton(prominent: true).fixedSize()
            .sheet(item: $editingCommand) { command in
                CommandEditor(pluginID: pluginID, command: command, actions: plugin.manifest.actions)
                    .environmentObject(store)
            }
        }
    }
}
