import CoreGraphics
import UntitledPluginSDK
import Foundation

/// Host-to-plugin notifications do not acquire a service or deliver raw input by
/// themselves. Only the owner of a feature decides when to create its controller.
package enum PluginRuntimeEvent {
    case installedPluginsChanged
    case willLaunch([String]), didLaunch([String])
    case willReloadShortcuts, didReloadShortcuts, shortcutPolicyChanged
    case shortcutOwned(UInt32, mouse: Bool), shortcutOwnershipChanged
    case copiedImage(Data, changeCount: Int)
}

package enum PluginShortcutChannel { case ordinary, modifier, eventTap }
package enum PluginShortcutRegistration { case exclusive, shared, window }

/// A module may opt into a press/release gesture instead of a one-shot command.
/// The host still owns the system binding, activation checks and cancellation.
package struct PluginShortcutGesture {
    package init(press: @escaping () throws -> Void, release: (() -> Void)? = nil, cancel: (() -> Void)? = nil) {
        self.press = press; self.release = release; self.cancel = cancel
    }
    package let press: () throws -> Void
    package var release: (() -> Void)? = nil
    package var cancel: (() -> Void)? = nil
}

/// The bridge for the app's trusted, statically linked modules. This is not an
/// executable ZIP format or a security boundary between processes.
@MainActor package protocol NativePluginRuntime: AnyObject {
    var actions: Set<ActionKind> { get }
    var actionPresentation: [ActionKind: PluginActionPresentation] { get }
    var styleNames: Set<String> { get }
    func registerUI(in registry: PluginUIRegistry)
    func legacyPermissions(for manifest: PluginManifest) -> [PluginPermissionDeclaration]
    func validateStyles(in manifest: PluginManifest) throws
    func perform(_ command: PluginCommand, for pluginID: String, in host: PluginStore) async throws
    func shortcutGesture(for command: PluginCommand, pluginID: String, channel: PluginShortcutChannel,
                         in host: PluginStore) -> PluginShortcutGesture?
    func includesShortcut(_ command: PluginCommand, in plugin: InstalledPlugin) -> Bool
    func shortcutRegistration(for command: PluginCommand, key: HotKey) -> PluginShortcutRegistration
    func permitsShortcut(_ command: PluginCommand) -> Bool
    func reservesShortcut(_ key: HotKey) -> Bool
    func ignoresShortcutEvent(_ event: CGEvent) -> Bool
    func receive(_ event: PluginRuntimeEvent, in host: PluginStore)
    func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore)
    func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore)
    func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws
    func prepareForQuit() async -> Bool
}

package extension NativePluginRuntime {
    var actionPresentation: [ActionKind: PluginActionPresentation] { [:] }
    var styleNames: Set<String> { [] }
    func registerUI(in registry: PluginUIRegistry) {}
    func legacyPermissions(for manifest: PluginManifest) -> [PluginPermissionDeclaration] { [] }
    func validateStyles(in manifest: PluginManifest) throws {}
    func shortcutGesture(for command: PluginCommand, pluginID: String, channel: PluginShortcutChannel,
                         in host: PluginStore) -> PluginShortcutGesture? { nil }
    func includesShortcut(_ command: PluginCommand, in plugin: InstalledPlugin) -> Bool { true }
    func shortcutRegistration(for command: PluginCommand, key: HotKey) -> PluginShortcutRegistration { .exclusive }
    func permitsShortcut(_ command: PluginCommand) -> Bool { true }
    func reservesShortcut(_ key: HotKey) -> Bool { false }
    func ignoresShortcutEvent(_ event: CGEvent) -> Bool { false }
    func receive(_ event: PluginRuntimeEvent, in host: PluginStore) {}
    func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore) {}
    func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore) {}
    func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws {}
    func prepareForQuit() async -> Bool { true }
}

@MainActor package final class PluginRuntimeRegistry {
    private let modules: [any NativePluginRuntime]
    private let owners: [ActionKind: any NativePluginRuntime]
    private let catalog: [ActionKind: PluginActionPresentation]

    package init(_ modules: [any NativePluginRuntime] = []) {
        var owners: [ActionKind: any NativePluginRuntime] = [:]
        var catalog = ActionKind.hostPresentation
        var styleNames = Set<String>()
        for module in modules {
            precondition(styleNames.isDisjoint(with: module.styleNames), "Duplicate plugin style owner")
            styleNames.formUnion(module.styleNames)
            for action in module.actions {
                precondition(!ActionExecutor.actions.contains(action) && owners[action] == nil,
                             "Duplicate provider for plugin action: \(action.rawValue)")
                owners[action] = module
                if let descriptor = module.actionPresentation[action] { catalog[action] = descriptor }
            }
        }
        self.modules = modules
        self.owners = owners
        self.catalog = catalog
    }

    package func registerUI(in registry: PluginUIRegistry) {
        for module in modules { module.registerUI(in: registry) }
    }
    package func legacyPermissions(for manifest: PluginManifest) -> [PluginPermissionDeclaration] {
        modules.filter { !$0.actions.isDisjoint(with: manifest.actions) }.flatMap { $0.legacyPermissions(for: manifest) }
    }
    package func presentation(for action: ActionKind) -> PluginActionPresentation {
        catalog[action] ?? .init(title: action.rawValue, symbol: "puzzlepiece.extension")
    }
    package func owner(of action: ActionKind) -> (any NativePluginRuntime)? { owners[action] }
    package func validate(_ manifest: PluginManifest) throws {
        for action in manifest.actions {
            guard owners[action] != nil || ActionExecutor.actions.contains(action) else {
                throw PluginError.invalid("宿主未提供此插件操作：\(action.rawValue)")
            }
            if let descriptor = catalog[action], let version = descriptor.minimumHostVersion,
               let introduced = Version(version), let minimum = Version(manifest.minimumHostVersion), minimum < introduced {
                throw PluginError.invalid("操作「\(descriptor.title)」需要 \(version) 或更高版本宿主。")
            }
        }
        guard let styles = manifest.styles else { return }
        let actions = Set(manifest.actions)
        let providers = modules.filter { !$0.actions.isDisjoint(with: actions) }
        let allowed = Set(providers.flatMap(\.styleNames))
        for name in styles.keys where !allowed.contains(name) {
            throw PluginError.invalid("插件声明了未知或未授权的样式：\(name)")
        }
        for provider in providers { try provider.validateStyles(in: manifest) }
    }
    package func includesShortcut(_ command: PluginCommand, in plugin: InstalledPlugin) -> Bool {
        modules(for: plugin).allSatisfy { $0.includesShortcut(command, in: plugin) }
    }
    package func permitsShortcut(_ command: PluginCommand) -> Bool { modules.allSatisfy { $0.permitsShortcut(command) } }
    package func reservesShortcut(_ key: HotKey) -> Bool { modules.contains { $0.reservesShortcut(key) } }
    package func ignoresShortcutEvent(_ event: CGEvent) -> Bool { modules.contains { $0.ignoresShortcutEvent(event) } }
    package func receive(_ event: PluginRuntimeEvent, in host: PluginStore) {
        for module in modules { module.receive(event, in: host) }
    }
    private func modules(for plugin: InstalledPlugin) -> [any NativePluginRuntime] {
        modules.filter { !$0.actions.isDisjoint(with: plugin.manifest.actions) }
    }
    package func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore) {
        let affected = Set(previous.manifest.actions).union(plugin.manifest.actions)
        for module in modules where !module.actions.isDisjoint(with: affected) {
            module.didReplace(previous, with: plugin, in: host)
        }
    }
    package func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore) {
        for module in modules(for: plugin) { module.didSetEnabled(plugin, in: host) }
    }
    package func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws {
        for module in modules(for: plugin) { try module.willUninstall(plugin, in: host) }
    }
    package func prepareForQuit() async -> Bool {
        for module in modules { if !(await module.prepareForQuit()) { return false } }
        return true
    }
}
