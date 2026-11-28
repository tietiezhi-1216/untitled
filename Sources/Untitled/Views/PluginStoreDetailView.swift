import SwiftUI
import UntitledPluginSDK

struct PluginStoreDetailView: View {
    @EnvironmentObject private var store: PluginStore
    @ViewState private var tab = "说明"
    @ViewState private var readme: String?
    @ViewState private var isLoading = false
    @ViewState private var loadError: String?
    @ViewState private var confirmUninstall = false
    let item: PluginStoreItem
    let goBack: () -> Void
    let openPlugin: (String) -> Void

    private var installed: InstalledPlugin? { store.installed.first { $0.id == item.id } }
    private var hasUpdate: Bool {
        guard let entry = item.entry, let installed, let latest = Version(entry.version), let current = Version(installed.manifest.version) else { return false }
        return latest > current
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: goBack) { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Link(destination: item.presentation.repository) {
                    Label("源码", systemImage: "arrow.up.right").foregroundStyle(.secondary)
                }
            }
            .font(.callout).padding(.horizontal, PanelLayout.contentInset).frame(height: 58)

            HStack(alignment: .top, spacing: 20) {
                PluginIconView(icon: item.presentation.icon, size: 64)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.presentation.name).font(.system(size: 24, weight: .semibold)).layoutPriority(1)
                        Text(item.author).font(.callout).foregroundStyle(.secondary)
                    }.lineLimit(1)
                    Text(item.presentation.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 10) {
                        Text("v\(item.version)")
                        if let installed, hasUpdate { Text("已安装 v\(installed.manifest.version)") }
                    }.font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, PanelLayout.contentInset).padding(.top, 8).padding(.bottom, 22)

            HStack(spacing: 12) {
                if let installed {
                    if hasUpdate, let entry = item.entry {
                        Button("更新") { Task { await store.install(entry) } }.panelGlassButton(prominent: true)
                            .disabled(store.isInstalling)
                    }
                    Button("打开插件") { openPlugin(item.id) }.panelGlassButton(prominent: !hasUpdate)
                    Toggle("启用", isOn: Binding(get: { installed.isEnabled }, set: { store.setEnabled($0, pluginID: item.id) }))
                        .toggleStyle(.switch).controlSize(.small).fixedSize().padding(.leading, 4)
                    Menu {
                        Button("卸载插件…", role: .destructive) { confirmUninstall = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("插件管理")
                } else if let entry = item.entry {
                    Button("安装") { Task { await store.install(entry) } }.panelGlassButton(prominent: true)
                        .disabled(store.isInstalling)
                }
                if store.isInstalling { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 24).panelRegion("store.detail.actions")

            HStack {
                Picker("插件详情", selection: $tab) {
                    Text("说明").tag("说明")
                    Text("信息").tag("信息")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Spacer()
            }
            .padding(.horizontal, PanelLayout.contentInset).padding(.bottom, 16)
            PanelDivider()

            ScrollView {
                Group {
                    if tab == "信息" { information }
                    else if isLoading { ProgressView("正在加载说明…").frame(maxWidth: .infinity).padding(.top, 40) }
                    else if let readme, !readme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        PluginReadmeView(markdown: readme, repository: item.presentation.repository, readmeURL: item.presentation.readmeURL)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(loadError ?? "这个版本尚未提供说明文档。").foregroundStyle(.secondary)
                            if loadError != nil { Button("重新加载") { Task { await loadDocumentation() } }.panelGlassButton() }
                            Link("前往源码仓库", destination: item.presentation.repository)
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(PanelLayout.contentInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).panelRegion("store.detail.documentation")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id + item.version) { await loadDocumentation() }
        .confirmationDialog("卸载「\(item.presentation.name)」？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) {
                store.uninstall(item.id)
                if item.entry == nil { goBack() }
            }
        } message: { Text("将移除插件的本地配置，并释放它的快捷键。") }
    }

    private var information: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 18) {
            infoRow("作者", item.author)
            infoRow("插件标识", item.id)
            infoRow("版本", item.version)
            if let installed {
                infoRow("已安装版本", installed.manifest.version)
                infoRow("最低宿主", installed.manifest.minimumHostVersion)
                infoRow("状态", installed.isEnabled ? "已启用" : "已停用")
            }
        }
        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value) }
    }

    private func loadDocumentation() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            if let entry = item.entry, !item.prefersInstalledVersion || entry.version == installed?.manifest.version {
                readme = try await store.documentation(for: entry)
            }
            else { readme = installed?.readme }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { loadError = "无法加载说明：\(error.localizedDescription)" } }
    }
}
