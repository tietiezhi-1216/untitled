import SwiftUI

struct HostPluginUIProvider: PluginUIProvider {
    func register(in registry: PluginUIRegistry) {
        registry.component("host.icon") { context in
            AnyView(
                PluginIconView(icon: context.plugin.map { context.store.presentation(for: $0.manifest).icon } ?? nil,
                               fallbackSymbol: context.interface?.icon ?? "puzzlepiece.extension", size: PanelLayout.iconSize)
                    .panelRegion("plugin.header.icon"))
        }
        registry.component("host.identity") { context in
            AnyView(PluginIdentityView(context: context))
        }
        for (name, control) in [("enabled", PluginHeaderControl.enabled), ("more", .more), ("info", .info)] {
            registry.component("host.\(name)") { context in
                AnyView(PluginHostControl(context: context, control: control))
            }
        }
        registry.component("host.commandHeading") { _ in AnyView(Text("操作").font(.headline)) }
        registry.component("host.addCommand") { context in AnyView(PluginAddCommandView(pluginID: context.pluginID)) }
        registry.component("host.commands") { context in AnyView(PluginDetailView(pluginID: context.pluginID)) }
        registry.component("host.compactCommands") { context in
            AnyView(PluginDetailView(pluginID: context.pluginID, compact: true))
        }
        registry.component("host.commandStatus") { _ in
            AnyView(Text("关闭主窗口后快捷键仍然有效，退出应用后停止。").font(.caption).foregroundStyle(.secondary))
        }
        registry.command("host.restoreDefaultCommands", presentation: { _ in .init(title: "恢复默认快捷键", symbol: "arrow.counterclockwise") }) { context in
            try context.store.restoreDefaultCommands(pluginID: context.pluginID)
        }
        registry.command("host.openPlugin", presentation: { _ in .init(title: "打开插件", symbol: "macwindow") }) {
            context in
            context.store.requestedPluginID = context.pluginID
            context.store.showMainWindow()
        }
    }
}

private struct PluginIdentityView: View {
    @EnvironmentObject private var store: PluginStore
    let context: PluginUIContext
    private var plugin: InstalledPlugin? { store.installed.first { $0.id == context.pluginID } }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(plugin.map { store.presentation(for: $0.manifest).name } ?? "")
                .font(.system(size: 22, weight: .semibold)).lineLimit(1)
            if plugin?.isEnabled == false {
                Text("已停用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
                    .panelRegion("plugin.header.disabledStatus")
            }
            Text(plugin?.manifest.author ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).panelWindowDragArea().panelRegion("panel.title")
    }
}

private struct PluginHostControl: View {
    @EnvironmentObject private var store: PluginStore
    let context: PluginUIContext
    let control: PluginHeaderControl
    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == context.pluginID }) {
            PluginHeaderControlView(control: control, plugin: plugin)
        }
    }
}
