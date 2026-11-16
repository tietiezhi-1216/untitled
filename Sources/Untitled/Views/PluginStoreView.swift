import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PluginStoreScope: String, CaseIterable { case store = "商店", installed = "已安装" }
enum PluginStoreSort: String, CaseIterable { case catalog = "默认顺序", name = "名称", recent = "最近安装" }

@MainActor final class PluginMarketplaceNavigation: ObservableObject {
    @Published var search = ""
    @Published var scope: PluginStoreScope
    @Published var category: String?
    @Published var sort = PluginStoreSort.catalog
    @Published var onlyUninstalled = false
    init(scope: PluginStoreScope = .store) { self.scope = scope }
}

struct PluginStoreItem: Identifiable {
    let id: String
    let entry: CatalogEntry?
    let plugin: InstalledPlugin?
    let presentation: PluginPresentation
    let author: String
    var prefersInstalledVersion = false
    var version: String {
        if prefersInstalledVersion, let plugin { return plugin.manifest.version }
        return entry?.version ?? plugin?.manifest.version ?? ""
    }
    var hasUpdate: Bool {
        guard let entry, let plugin, let latest = Version(entry.version), let current = Version(plugin.manifest.version) else { return false }
        return latest > current
    }
    @MainActor static func installed(_ plugin: InstalledPlugin, store: PluginStore) -> Self {
        Self(id: plugin.id, entry: store.catalog.first { $0.id == plugin.id }, plugin: plugin,
             presentation: store.presentation(for: plugin.manifest), author: plugin.manifest.author, prefersInstalledVersion: true)
    }
}

struct PluginStoreView: View {
    @EnvironmentObject private var store: PluginStore
    @ObservedObject private var navigation: PluginMarketplaceNavigation
    @ViewState private var selectedID: String?
    let selectPlugin: (String) -> Void

    init(initialScope: PluginStoreScope = .store, navigation: PluginMarketplaceNavigation? = nil,
         selectPlugin: @escaping (String) -> Void) {
        self.navigation = navigation ?? PluginMarketplaceNavigation(scope: initialScope)
        self.selectPlugin = selectPlugin
    }

    private var allItems: [PluginStoreItem] {
        if navigation.scope == .installed { return store.installed.map { .installed($0, store: store) } }
        return store.catalog.map { entry in
            PluginStoreItem(id: entry.id, entry: entry, plugin: store.installed.first { $0.id == entry.id },
                            presentation: store.presentation(for: entry), author: entry.author)
        } + store.installed.filter { plugin in !store.catalog.contains { $0.id == plugin.id } }
            .map { .installed($0, store: store) }
    }

    private var items: [PluginStoreItem] {
        let filtered = allItems.filter { item in
            (navigation.scope == .store ? item.entry != nil : item.plugin != nil) &&
                (navigation.category == nil || item.presentation.category == navigation.category) &&
                (!navigation.onlyUninstalled || navigation.scope == .installed || item.plugin == nil) &&
                (navigation.search.isEmpty || (item.presentation.name + item.presentation.summary + item.author +
                    (item.entry?.name ?? "") + (item.presentation.storefront?.category ?? ""))
                    .localizedCaseInsensitiveContains(navigation.search))
        }
        switch navigation.sort {
        case .catalog: return filtered
        case .name: return filtered.sorted { $0.presentation.name.localizedStandardCompare($1.presentation.name) == .orderedAscending }
        case .recent: return filtered.sorted {
            let left = $0.plugin?.installedAt ?? .distantPast, right = $1.plugin?.installedAt ?? .distantPast
            if left != right { return left > right }
            return $0.presentation.name.localizedStandardCompare($1.presentation.name) == .orderedAscending
        }
        }
    }

    private var title: String {
        if !navigation.search.isEmpty { return "“\(navigation.search)”的搜索结果" }
        return navigation.category ?? (navigation.scope == .installed ? "已安装" : "插件商店")
    }

    var body: some View {
        Group {
            if let selectedID, let item = allItems.first(where: { $0.id == selectedID }) {
                PluginStoreDetailView(item: item, goBack: { self.selectedID = nil }, openPlugin: selectPlugin)
            } else { marketplace }
        }
        .task(id: navigation.scope) { if navigation.scope == .store && store.catalog.isEmpty { await store.refreshCatalog() } }
        .onChange(of: navigation.search) { _, _ in selectedID = nil }
        .onChange(of: navigation.category) { _, _ in selectedID = nil }
    }

    private var marketplace: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 28, weight: .bold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).panelWindowDragArea().panelRegion("panel.title")
                .padding(.horizontal, PanelLayout.contentInset).padding(.top, 64).padding(.bottom, 18)
                .panelRegion("panel.header")

            HStack {
                HStack(spacing: 0) {
                    scopeButton("商店", value: .store)
                    scopeButton("已安装 · \(store.installed.count)", value: .installed)
                }
                .background(Color.primary.opacity(0.07), in: Capsule())
                .panelRegion("store.scope")
                Spacer()
                Menu {
                    Picker("排序", selection: $navigation.sort) {
                        ForEach(PluginStoreSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("仅显示未安装", isOn: $navigation.onlyUninstalled).disabled(navigation.scope == .installed)
                    Divider()
                    Button("刷新商店", systemImage: "arrow.clockwise") { Task { await store.refreshCatalog() } }
                        .disabled(store.isRefreshing)
                    Button("从 ZIP 安装…", systemImage: "square.and.arrow.down", action: importPackage)
                        .disabled(store.isInstalling)
                    Link("开发插件", destination: HostInfo.repository.appendingPathComponent("tree/main/Plugins"))
                } label: {
                    Text("筛选")
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible)
                .foregroundStyle(Color.accentColor).font(.system(size: 13, weight: .medium))
                .fixedSize().panelRegion("store.filter")
            }
            .padding(.horizontal, PanelLayout.contentInset).frame(height: 30)
            .panelRegion("store.controls").padding(.bottom, 12)
            PanelDivider().padding(.bottom, 28)

            if let error = store.catalogError {
                HStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await store.refreshCatalog() } }.panelGlassButton()
                }.padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 16)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(minimum: 250), spacing: 26), GridItem(.flexible(minimum: 250), spacing: 26)],
                          alignment: .leading, spacing: 34) {
                    ForEach(items) { item in
                        PluginStoreCard(item: item, openPlugin: selectPlugin) { selectedID = item.id }
                    }
                }
                .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 36)
            }
            .panelRegion("store.gallery").frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if store.isRefreshing && store.catalog.isEmpty && navigation.scope == .store {
                    ProgressView("正在加载插件…")
                } else if items.isEmpty {
                    ContentUnavailableView(
                        navigation.search.isEmpty ? "暂无插件" : "没有找到插件", systemImage: "magnifyingglass",
                        description: Text(navigation.search.isEmpty ? "选择其他分类，或从筛选菜单导入 ZIP。" : "试试其他关键词。")
                    )
                }
            }
        }
    }

    private func scopeButton(_ title: String, value: PluginStoreScope) -> some View {
        Button { navigation.scope = value } label: {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(navigation.scope == value ? Color.white : Color.primary.opacity(0.7))
                .padding(.horizontal, 15).frame(height: 28)
                .background(navigation.scope == value ? Color.accentColor : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(navigation.scope == value ? .isSelected : [])
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.title = "选择插件 ZIP 包"
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await store.importPackage(url) }
        }
    }
}

private struct PluginStoreCard: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.colorScheme) private var scheme
    @ViewState private var isAcquiring = false
    let item: PluginStoreItem
    let openPlugin: (String) -> Void
    let select: () -> Void

    private var actionTitle: String { item.hasUpdate ? "更新" : (item.plugin == nil ? "获取" : "打开") }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Button(action: select) {
                    HStack(spacing: 12) {
                        PluginIconView(icon: item.presentation.icon, size: 50)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.presentation.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                            Text(item.presentation.category).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(item.author).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(item.presentation.name)，查看详情")
                .panelRegion("store.card.\(item.id).identity")
                VStack(spacing: 5) {
                    Button {
                        if let entry = item.entry, item.plugin == nil || item.hasUpdate {
                            isAcquiring = true
                            Task { await store.install(entry); isAcquiring = false }
                        } else { openPlugin(item.id) }
                    } label: {
                        Group {
                            if isAcquiring { ProgressView().controlSize(.small) }
                            else { Text(actionTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor) }
                        }
                        .frame(width: 66, height: 27)
                        .background(scheme == .dark ? Color.white.opacity(0.94) : Color.primary.opacity(0.065), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(store.isInstalling)
                    .accessibilityLabel("\(actionTitle)\(item.presentation.name)")
                    .panelRegion("store.card.\(item.id).action")
                    Text(item.plugin == nil ? "适用于 Mac" : (item.plugin?.isEnabled == false ? "已停用" : "已安装"))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 62).panelRegion("store.card.\(item.id).header")
            Button(action: select) { PluginPromotionView(presentation: item.presentation) }
                .buttonStyle(.plain).accessibilityLabel("\(item.presentation.name)，查看说明")
                .panelRegion("store.card.\(item.id).preview")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelRegion("store.card.\(item.id)")
    }
}
