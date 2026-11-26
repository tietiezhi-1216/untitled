import Combine
import SwiftUI

/// The host renders slots. Providers supply components and commands; manifests arrange them.
struct PluginWorkspaceView: View {
    @EnvironmentObject private var store: PluginStore
    @StateObject private var navigation = PluginUINavigation()
    let pluginID: String

    var body: some View {
        let context = PluginUIContext(pluginID: pluginID, store: store, navigation: navigation)
        if let ui = context.interface {
            PluginUILayoutView(slots: ui.slots, context: context, root: true)
                .sheet(item: $navigation.sheet) { sheet in
                    PluginPanelSheet(panelID: sheet.id, context: context)
                }
        }
    }
}

private struct PluginContentHasInsetsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PluginHeaderUsesIconsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PluginTrailingScrollGutterKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var pluginTrailingScrollGutter: CGFloat {
        get { self[PluginTrailingScrollGutterKey.self] }
        set { self[PluginTrailingScrollGutterKey.self] = newValue }
    }

    var pluginHeaderUsesIcons: Bool {
        get { self[PluginHeaderUsesIconsKey.self] }
        set { self[PluginHeaderUsesIconsKey.self] = newValue }
    }

    var pluginContentHasInsets: Bool {
        get { self[PluginContentHasInsetsKey.self] }
        set { self[PluginContentHasInsetsKey.self] = newValue }
    }
}

/// The host owns the content rectangle, including clipping. By default, providers
/// cannot draw into the gutters. A native, single-component root can use a
/// bounded trailing gutter for an overlay scroller, without moving its content.
/// Nested tabs/inline layouts inherit the rectangle instead of adding margins again.
struct PluginContentViewport<Content: View>: View {
    @Environment(\.pluginContentHasInsets) private var hasInsets
    let forceInsets: Bool
    let region: String
    let usesTrailingScrollGutter: Bool
    let content: Content

    init(forceInsets: Bool = false, region: String = "plugin.content", usesTrailingScrollGutter: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.forceInsets = forceInsets
        self.region = region
        self.usesTrailingScrollGutter = usesTrailingScrollGutter
        self.content = content()
    }

    var body: some View {
        let inset = forceInsets || !hasInsets
        let horizontal: CGFloat = inset ? PanelLayout.contentInset : 0
        let vertical: CGFloat = inset ? PanelLayout.contentVerticalInset : 0
        let trailing = usesTrailingScrollGutter ? 0 : horizontal
        GeometryReader { geometry in
            content
                .environment(\.pluginContentHasInsets, true)
                .environment(\.pluginTrailingScrollGutter, horizontal - trailing)
                .frame(width: max(0, geometry.size.width - horizontal - trailing),
                       height: max(0, geometry.size.height - 2 * vertical), alignment: .topLeading)
                .contentShape(Rectangle())
                .clipped()
                .panelRegion("\(region).bounds")
                .padding(.leading, horizontal)
                .padding(.trailing, trailing)
                .padding(.vertical, vertical)
        }
        .panelRegion("\(region).viewport")
    }
}

struct PluginUILayoutView: View {
    let slots: [String: [PluginUIItem]]
    let context: PluginUIContext
    var root = false
    @ObservedObject private var navigation: PluginUINavigation
    @Environment(\.pluginContentHasInsets) private var hasInsets
    private var horizontalInset: CGFloat { hasInsets ? 0 : PanelLayout.contentInset }

    init(slots: [String: [PluginUIItem]], context: PluginUIContext, root: Bool = false) {
        self.slots = slots
        self.context = context
        self.root = root
        navigation = context.navigation
    }
    private func items(_ slot: PluginUISlot) -> [PluginUIItem] { slots[slot.rawValue] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if !items(.headerLeading).isEmpty || !items(.headerTrailing).isEmpty {
                heading
                    .panelRegion(root ? "panel.heading" : "plugin.panel.heading")
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 24)
                    .frame(minHeight: 96)
                    .panelRegion(root ? "panel.header" : "plugin.panel.header")
            }
            if !items(.toolbarLeading).isEmpty || !items(.toolbarTrailing).isEmpty {
                row(.toolbarLeading, .toolbarTrailing, spacing: 12)
                    .padding(.horizontal, horizontalInset)
                    .frame(minHeight: 52)
                    .padding(.bottom, 8)
                    .panelRegion(root ? "plugin.toolbar" : "plugin.panel.toolbar")
            }
            PluginContentViewport(forceInsets: root, region: root ? "plugin.content" : "plugin.panel.content",
                                  usesTrailingScrollGutter: usesTrailingScrollGutter) {
                VStack(spacing: 0) {
                    if root, let panelID = navigation.inlinePanel {
                        HStack {
                            Button {
                                navigation.inlinePanel = nil
                            } label: {
                                Label("返回", systemImage: "chevron.left")
                            }
                            Spacer()
                        }.padding(.bottom, 12)
                        PluginPanelContent(panelID: panelID, context: context)
                    } else {
                        ForEach(items(.content)) { item in
                            PluginSlotItemView(item: item, context: context)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !items(.footerLeading).isEmpty || !items(.footerTrailing).isEmpty {
                row(.footerLeading, .footerTrailing, spacing: 12)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalInset)
                    .frame(minHeight: 44)
                    .panelRegion(root ? "plugin.footer" : "plugin.panel.footer")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelRegion(root ? "plugin.workspace" : "plugin.panel")
    }

    private var usesTrailingScrollGutter: Bool {
        let content = items(.content)
        guard root, navigation.inlinePanel == nil, content.count == 1,
              content[0].kind == .component, let name = content[0].component else { return false }
        return context.store.uiRegistry.components[name]?.usesTrailingScrollGutter == true
    }

    private var headerActions: [PluginUIItem] {
        let trailing = items(.headerTrailing)
        let more = trailing.filter { $0.component == "host.more" }
        let hasManagement = !more.isEmpty || items(.headerLeading).contains { $0.component == "host.more" }
        // Existing manifests may declare a separate switch next to More.
        // Keep the same lifecycle action, without putting two controls in the header.
        return trailing.filter {
            $0.component != "host.more" && (!hasManagement || $0.component != "host.enabled")
        } + more
    }

    @ViewBuilder private var heading: some View {
        if root {
            HStack(spacing: 16) {
                ForEach(items(.headerLeading)) { PluginSlotItemView(item: $0, context: context) }
                Spacer(minLength: 8)
                if !headerActions.isEmpty {
                    HStack(spacing: PanelLayout.headerActionSpacing) {
                        ForEach(headerActions) {
                            PluginSlotItemView(item: $0, context: context, headerAction: true)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .panelRegion("plugin.header.actions")
                }
            }
        } else {
            row(.headerLeading, .headerTrailing, spacing: 16)
        }
    }

    private func row(_ leading: PluginUISlot, _ trailing: PluginUISlot, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(items(leading)) { PluginSlotItemView(item: $0, context: context) }
            Spacer(minLength: 8)
            ForEach(items(trailing)) { PluginSlotItemView(item: $0, context: context) }
        }
    }
}

struct PluginSlotItemView: View {
    @EnvironmentObject private var store: PluginStore
    let item: PluginUIItem
    let context: PluginUIContext
    var menuItem = false
    var headerAction = false

    var body: some View {
        rendered.panelRegion("plugin.ui.\(item.id)")
    }
    private var rendered: AnyView {
        switch item.kind {
        case .component:
            let view = store.uiRegistry.components[item.component ?? ""]?.makeView(context) ?? AnyView(EmptyView())
            return AnyView(view.environment(\.pluginHeaderUsesIcons, headerAction))
        case .button:
            return AnyView(PluginSlotButton(item: item, context: context, menuItem: menuItem, headerAction: headerAction))
        case .menu:
            let menu = Menu {
                ForEach(item.items ?? []) { PluginSlotItemView(item: $0, context: context, menuItem: true) }
            } label: {
                if headerAction {
                    Image(systemName: item.symbol ?? "list.bullet")
                } else {
                    PluginItemLabel(title: item.title ?? "", symbol: item.symbol)
                }
            }
            if menuItem { return AnyView(menu) }
            if headerAction {
                let title = item.title ?? "更多操作"
                return AnyView(menu
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(PluginHeaderIconStyle(prominent: item.style == .prominent))
                    .accessibilityLabel(title)
                    .pluginHeaderHint(title))
            }
            return AnyView(menu.panelGlassButton(prominent: item.style == .prominent).fixedSize())
        case .panel:
            return AnyView(PluginPanelContent(panelID: item.panel ?? "", context: context))
        case .tabs:
            return AnyView(PluginSlotTabs(item: item, context: context))
        }
    }
}

private struct PluginItemLabel: View {
    let title: String
    let symbol: String?
    var body: some View {
        if let symbol {
            if title.isEmpty {
                Image(systemName: symbol).frame(width: 18, height: 18)
            } else {
                Label(title, systemImage: symbol)
            }
        } else {
            Text(title)
        }
    }
}

/// Observes command state independently of the component currently visible in the content slot.
@MainActor private final class PluginCommandObservation: ObservableObject {
    private var subscription: AnyCancellable?
    init(commandID: String?, context: PluginUIContext) {
        subscription = commandID.flatMap { context.store.uiRegistry.commands[$0]?.updates?(context) }?
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.objectWillChange.send() }
    }
}

private struct PluginSlotButton: View {
    @EnvironmentObject private var store: PluginStore
    let item: PluginUIItem
    let context: PluginUIContext
    let menuItem: Bool
    let headerAction: Bool
    @StateObject private var observation: PluginCommandObservation
    @ViewState private var showingPopover = false

    init(item: PluginUIItem, context: PluginUIContext, menuItem: Bool, headerAction: Bool) {
        self.item = item
        self.context = context
        self.menuItem = menuItem
        self.headerAction = headerAction
        _observation = StateObject(wrappedValue: PluginCommandObservation(commandID: item.command, context: context))
    }
    private var state: PluginCommandPresentation? {
        item.command.flatMap { store.uiRegistry.commands[$0]?.presentation(context) }
    }
    private var title: String { item.title ?? state?.title ?? "" }
    private var accessibleTitle: String {
        if !title.isEmpty { return title }
        return item.panel.flatMap { context.interface?.panel($0)?.title } ?? state?.title ?? "插件操作"
    }
    var body: some View {
        let control = styledButton
            .disabled(item.command != nil && (store.installed.first { $0.id == context.pluginID }?.isEnabled != true || state?.isEnabled == false))
            .accessibilityLabel(accessibleTitle)
            .popover(isPresented: $showingPopover) {
                if let panelID = item.panel {
                    PluginPanelSheet(panelID: panelID, context: context)
                }
            }
        if headerAction {
            control.pluginHeaderHint(accessibleTitle)
        } else {
            control.help(accessibleTitle)
        }
    }
    private var button: some View {
        Button {
            if let command = item.command {
                Task {
                    do { try await context.store.uiRegistry.execute(command, context: context) } catch {
                        context.store.handleExecutionError(error)
                    }
                }
            } else if let panel = item.panel, let ui = context.interface {
                if item.presentation == .popover {
                    showingPopover = true
                } else {
                    context.navigation.open(panel, presentation: item.presentation ?? .sheet, interface: ui)
                }
            }
        } label: {
            if headerAction {
                Image(systemName: item.symbol ?? state?.symbol ?? (item.panel == nil ? "bolt" : "slider.horizontal.3"))
            } else {
                PluginItemLabel(title: title, symbol: item.symbol ?? state?.symbol)
            }
        }
    }
    @ViewBuilder private var styledButton: some View {
        if menuItem {
            button
        } else if headerAction {
            button.buttonStyle(PluginHeaderIconStyle(prominent: item.style == .prominent))
        } else if item.style == .plain {
            button.buttonStyle(.plain).fixedSize()
        } else {
            button.panelGlassButton(prominent: item.style == .prominent, circular: title.isEmpty).fixedSize()
        }
    }
}

private struct PluginSlotTabs: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.pluginContentHasInsets) private var hasInsets
    let item: PluginUIItem
    let context: PluginUIContext
    @ObservedObject private var navigation: PluginUINavigation
    init(item: PluginUIItem, context: PluginUIContext) {
        self.item = item
        self.context = context
        navigation = context.navigation
    }
    private var selected: Binding<String> {
        Binding(
            get: { navigation.selectedTabs[item.id] ?? item.panels?.first ?? "" },
            set: { navigation.selectedTabs[item.id] = $0 })
    }
    var body: some View {
        VStack(spacing: item.style == .plain ? 12 : 16) {
            if item.style == .plain {
                ViewThatFits(in: .horizontal) {
                    picker.fixedSize(horizontal: true, vertical: false)
                    picker
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, hasInsets ? 0 : PanelLayout.contentInset)
            } else {
                picker.padding(.horizontal, hasInsets ? 0 : PanelLayout.contentInset)
            }
            PluginPanelContent(panelID: selected.wrappedValue, context: context)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        let ui = store.installed.first { $0.id == context.pluginID }.map { store.uiRegistry.interface(for: $0.manifest) }
        return Picker(item.title ?? "插件页面", selection: selected) {
            ForEach(item.panels ?? [], id: \.self) { id in
                Text(ui?.panel(id)?.title ?? id).tag(id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .panelRegion("plugin.ui.\(item.id).tabs")
    }
}

struct PluginPanelContent: View {
    @EnvironmentObject private var store: PluginStore
    let panelID: String
    let context: PluginUIContext
    var body: some View {
        if let manifest = store.installed.first(where: { $0.id == context.pluginID })?.manifest,
           let panel = store.uiRegistry.interface(for: manifest).panel(panelID) {
            if let component = panel.component {
                context.store.uiRegistry.components[component]?.makeView(context)
            } else if let slots = panel.slots {
                // Type erasure also allows providers to compose nested layouts.
                AnyView(PluginUILayoutView(slots: slots, context: context))
            }
        }
    }
}

struct PluginPanelSheet: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.dismiss) private var dismiss
    let panelID: String
    let context: PluginUIContext
    var body: some View {
        let panel = store.installed.first { $0.id == context.pluginID }
            .flatMap { store.uiRegistry.interface(for: $0.manifest).panel(panelID) }
        VStack(spacing: 0) {
            HStack {
                Text(panel?.title ?? "插件面板").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.panelRegion("plugin.sheet.heading")
                .padding(.horizontal, PanelLayout.contentInset).padding(.vertical, 20)
            PluginContentViewport(forceInsets: true, region: "plugin.sheet.content") {
                PluginPanelContent(panelID: panelID, context: context)
            }
        }
        .frame(width: panel?.width ?? 660, height: panel?.height ?? 560)
    }
}
