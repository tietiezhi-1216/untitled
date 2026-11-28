import Combine
import UntitledPluginSDK
import SwiftUI

@MainActor package protocol PluginUIProvider {
    func register(in registry: PluginUIRegistry)
    func legacyInterface(for manifest: PluginManifest) -> PluginInterface?
    func validateBinding(_ command: PluginCommand, in plugin: InstalledPlugin) throws
    func migrateBindings(in plugin: inout InstalledPlugin, to manifest: PluginManifest, occupiedHotKeys: Set<String>)
}

package extension PluginUIProvider {
    func validateBinding(_ command: PluginCommand, in plugin: InstalledPlugin) throws {}
    func migrateBindings(in plugin: inout InstalledPlugin, to manifest: PluginManifest, occupiedHotKeys: Set<String>) {}
    func legacyInterface(for manifest: PluginManifest) -> PluginInterface? { nil }
}

@MainActor package struct PluginUIContext {
    package init(pluginID: String, store: PluginStore, navigation: PluginUINavigation) {
        self.pluginID = pluginID; self.store = store; self.navigation = navigation
    }
    package let pluginID: String
    package let store: PluginStore
    package let navigation: PluginUINavigation
    package var plugin: InstalledPlugin? { store.installed.first { $0.id == pluginID } }
    package var interface: PluginInterface? { plugin.map { store.uiRegistry.interface(for: $0.manifest) } }
    package var permissions: PluginPermissionClient { store.permissionClient(for: pluginID) }
    package var nativeCapabilities: PluginNativeCapabilityClient { store.nativeCapabilities(for: pluginID) }
}

package struct PluginCommandPresentation {
    package init(title: String, symbol: String? = nil, isEnabled: Bool = true) {
        self.title = title; self.symbol = symbol; self.isEnabled = isEnabled
    }
    package var title: String
    package var symbol: String?
    package var isEnabled = true
}

@MainActor package final class PluginUIRegistry {
    package init() {}
    package struct Component {
        let requiredActions: Set<ActionKind>
        let usesTrailingScrollGutter: Bool
        let makeView: (PluginUIContext) -> AnyView
    }
    package struct Command {
        let requiredActions: Set<ActionKind>
        let presentation: (PluginUIContext) -> PluginCommandPresentation
        let updates: ((PluginUIContext) -> AnyPublisher<Void, Never>)?
        let perform: (PluginUIContext) async throws -> Void
    }
    package private(set) var components: [String: Component] = [:]
    package private(set) var commands: [String: Command] = [:]
    private var providers: [any PluginUIProvider] = []

    package func register(_ provider: some PluginUIProvider) {
        providers.append(provider)
        provider.register(in: self)
    }
    package func component(
        _ name: String, requiredActions: Set<ActionKind> = [], usesTrailingScrollGutter: Bool = false,
        makeView: @escaping (PluginUIContext) -> AnyView
    ) {
        precondition(components[name] == nil, "Duplicate plugin component: \(name)")
        components[name] = Component(requiredActions: requiredActions, usesTrailingScrollGutter: usesTrailingScrollGutter,
                                     makeView: makeView)
    }
    package func command(
        _ name: String, requiredActions: Set<ActionKind> = [],
        presentation: @escaping (PluginUIContext) -> PluginCommandPresentation,
        updates: ((PluginUIContext) -> AnyPublisher<Void, Never>)? = nil,
        perform: @escaping (PluginUIContext) async throws -> Void
    ) {
        precondition(commands[name] == nil, "Duplicate plugin command: \(name)")
        commands[name] = Command(
            requiredActions: requiredActions, presentation: presentation, updates: updates, perform: perform)
    }
    package func validateBinding(_ command: PluginCommand, in plugin: InstalledPlugin) throws {
        if command.isEnabled { try command.hotKey?.validate(allowedInputs: plugin.manifest.allowedShortcutInputs) }
        for provider in providers { try provider.validateBinding(command, in: plugin) }
    }
    package func migrateBindings(in plugin: inout InstalledPlugin, to manifest: PluginManifest, occupiedHotKeys: Set<String>) {
        for provider in providers { provider.migrateBindings(in: &plugin, to: manifest, occupiedHotKeys: occupiedHotKeys) }
    }
    package func interface(for manifest: PluginManifest) -> PluginInterface {
        if let ui = manifest.ui { return ui }
        guard manifest.schemaVersion == 1 else { return PluginInterface(slots: [:]) }
        for provider in providers {
            if let ui = provider.legacyInterface(for: manifest) { return ui }
        }
        return Self.legacyCommands
    }
    package func validate(_ manifest: PluginManifest) throws {
        let ui = interface(for: manifest)
        try ui.validate()
        let actions = Set(manifest.actions)
        for item in ui.allItems {
            if let reference = item.component { try validateComponent(reference, actions: actions) }
            if let reference = item.command {
                guard let command = commands[reference], command.requiredActions.isSubset(of: actions) else {
                    throw PluginError.invalid("插件引用了未知或未授权的界面命令：\(reference)")
                }
            }
        }
        for panel in ui.panels ?? [] {
            if let component = panel.component { try validateComponent(component, actions: actions) }
        }
    }
    private func validateComponent(_ name: String, actions: Set<ActionKind>) throws {
        guard let component = components[name], component.requiredActions.isSubset(of: actions) else {
            throw PluginError.invalid("插件引用了未知或未授权的界面组件：\(name)")
        }
    }
    package func execute(_ commandID: String, context: PluginUIContext) async throws {
        guard let plugin = context.plugin, plugin.isEnabled,
            let command = commands[commandID],
            command.requiredActions.allSatisfy(plugin.allowsAction),
            command.presentation(context).isEnabled
        else { throw PluginError.invalid("此插件操作当前不可用。") }
        try await command.perform(context)
    }
    package static var legacyCommands: PluginInterface {
        PluginInterface(slots: [
            PluginUISlot.headerLeading.rawValue: [
                .component("icon", "host.icon"), .component("identity", "host.identity"),
            ],
            PluginUISlot.headerTrailing.rawValue: [
                .component("enabled", "host.enabled"), .component("more", "host.more"), .component("info", "host.info"),
            ],
            PluginUISlot.toolbarLeading.rawValue: [.component("commandHeading", "host.commandHeading")],
            PluginUISlot.toolbarTrailing.rawValue: [.component("addCommand", "host.addCommand")],
            PluginUISlot.content.rawValue: [.component("commands", "host.commands")],
            PluginUISlot.footerLeading.rawValue: [.component("commandStatus", "host.commandStatus")],
        ])
    }
}

@MainActor package final class PluginUINavigation: ObservableObject {
    package init() {}
    struct Sheet: Identifiable { let id: String }
    @Published var sheet: Sheet?
    @Published var inlinePanel: String?
    @Published var selectedTabs: [String: String] = [:]

    func open(_ panel: String, presentation: PluginUIItem.Presentation, interface: PluginInterface) {
        guard interface.panel(panel) != nil else { return }
        if presentation == .sheet {
            sheet = Sheet(id: panel)
        } else {
            if let tabs = interface.allItems.first(where: { $0.kind == .tabs && ($0.panels ?? []).contains(panel) }) {
                selectedTabs[tabs.id] = panel
                inlinePanel = nil
            } else {
                inlinePanel = panel
            }
        }
    }
}
