import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var selection: String
    @StateObject private var marketplace = PluginMarketplaceNavigation()

    init(initialSelection: String = "__store__") {
        _selection = ViewState(wrappedValue: initialSelection)
    }

    private var selectedPlugin: InstalledPlugin? {
        store.installed.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: PanelLayout.sidebarWidth)
            Divider()
                .opacity(0.45)
            Group {
                if let plugin = selectedPlugin {
                    PluginWorkspaceView(pluginID: plugin.id).id(plugin.id)
                } else {
                    PluginStoreView(navigation: marketplace) { selection = $0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background((selectedPlugin == nil ? PanelPalette.store(scheme) : PanelPalette.content(scheme)).opacity(contentBackgroundOpacity))
        }
        .frame(minWidth: 880, minHeight: 580)
        .background {
            if reduceTransparency {
                PanelPalette.window(scheme)
            } else {
                ZStack {
                    PanelWindowBackdrop()
                    PanelPalette.window(scheme).opacity(0.96)
                }
            }
        }
        .background {
            PanelWindowChromeAccessor()
                .allowsHitTesting(false)
        }
        .panelRegion("panel.root")
        .coordinateSpace(name: PanelLayout.coordinateSpace)
        .ignoresSafeArea(.container, edges: .top)
        .controlSize(.regular)
        .onAppear {
            let action = openWindow
            store.showMainWindow = {
                action(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            let settings = openSettings
            store.permissions.presentManagement = {
                NSApplication.shared.activate(ignoringOtherApps: true)
                settings()
            }
            store.permissions.presentPluginManagement = { [weak store] id in store?.showPluginAccess(id) }
            if let id = store.requestedPluginID { selection = id; store.requestedPluginID = nil }
        }
        .onChange(of: store.requestedPluginID) { _, id in
            if let id { selection = id; store.requestedPluginID = nil }
        }
        .onChange(of: marketplace.search) { _, _ in
            marketplace.selectedID = nil
            selection = "__store__"
        }
        .sheet(item: $store.accessSelection) { selection in
            PluginAccessView(pluginID: selection.id).environmentObject(store)
        }
        .alert("操作未完成", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: PanelLayout.windowControlsHeight)
                .contentShape(Rectangle())
                .panelWindowDragArea()
                .panelRegion("panel.windowControls")
            PanelSearchField(text: $marketplace.search, compact: true)
                .padding(.horizontal, 16).padding(.bottom, 20)
                .panelRegion("store.sidebar.search")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    navigationItem("插件商店", symbol: "storefront", id: "__store__")
                    Text("我的插件")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 22)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(store.installed) { plugin in
                        navigationItem(
                            store.presentation(for: plugin.manifest).name,
                            symbol: "puzzlepiece.extension",
                            id: plugin.id, icon: store.presentation(for: plugin.manifest).icon,
                            enabled: plugin.isEnabled
                        )
                        .contextMenu {
                            Button("权限与能力…") { store.showPluginAccess(plugin.id) }
                        }
                    }
                    if store.installed.isEmpty {
                        Text("安装的插件会显示在这里")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            SettingsLink {
                Label("应用设置", systemImage: "gearshape")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .help("应用设置（⌘,）")
            .panelRegion("panel.settings")
        }
        .frame(maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color.indigo.opacity(scheme == .dark ? 0.16 : 0.07), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .panelNavigationSurface()
        .accessibilityElement(children: .contain)
        .panelRegion("panel.sidebar")
    }

    private func isSelected(_ id: String) -> Bool {
        if id == "__store__" { return selectedPlugin == nil }
        return selection == id
    }

    private func navigationItem(_ title: String, symbol: String, id: String, icon: PluginIcon? = nil, enabled: Bool = true) -> some View {
        let active = isSelected(id)
        return Button {
            if id == "__store__" {
                marketplace.search = ""
                marketplace.selectedID = nil
            }
            selection = id
        } label: {
            HStack(spacing: 10) {
                if let icon {
                    PluginIconView(icon: icon, size: 22).opacity(enabled ? 1 : 0.4)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(Color.accentColor).frame(width: 22)
                }
                Text(title)
            }
                .font(.system(size: 13, weight: active ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(Color.primary.opacity(active ? 1 : 0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
                .background(
                    active ? Color.accentColor.opacity(0.13) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(active ? 0.04 : 0), lineWidth: 1 / displayScale)
                }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .panelRegion("navigation.\(id)")
    }

    private var contentBackgroundOpacity: Double {
        if reduceTransparency { return 1 }
        return contrast == .increased ? 1 : 0.98
    }
}
