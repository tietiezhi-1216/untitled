import Combine
import UntitledPluginSDK
import Foundation

package enum HostPermissionStatus: Equatable {
    case authorized, notDetermined, notGranted, denied, restricted
    package var title: String {
        switch self {
        case .authorized: "已授权"
        case .notDetermined: "尚未请求"
        case .notGranted: "未授权"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        }
    }
}

package struct HostPermissionDescriptor: Identifiable {
    package let id: HostPermissionID
    package let title: String
    package let summary: String
    package let symbol: String
}

@MainActor package struct HostPermissionDriver {
    package let descriptor: HostPermissionDescriptor
    package let status: () -> HostPermissionStatus
    package let request: () async -> Void
    package let openSettings: () -> Void
}

package enum HostSettingsPage: String, CaseIterable { case general, permissions }

struct HostPermissionRequest: Identifiable, Equatable {
    enum Source: Equatable { case plugin(id: String, name: String), hostShortcutRouting }
    let source: Source
    let permissions: Set<HostPermissionID>
    var pluginID: String? {
        if case .plugin(let id, _) = source { return id }
        return nil
    }
    var name: String {
        switch source {
        case .plugin(_, let name): name
        case .hostShortcutRouting: "全局快捷键"
        }
    }
    var id: String { pluginID ?? "host.shortcutRouting" }
    init(pluginID: String, pluginName: String, permissions: Set<HostPermissionID>) {
        source = .plugin(id: pluginID, name: pluginName); self.permissions = permissions
    }
    init(hostShortcutRouting permissions: Set<HostPermissionID>) {
        source = .hostShortcutRouting; self.permissions = permissions
    }
}

package enum HostPermissionError: LocalizedError {
    case missing
    package var errorDescription: String? { "所需权限尚未开启，请在应用设置的“权限管理”中授权后重新执行。" }
}

/// No native module owns OS authorization. All status, prompting and settings links pass through this broker.
@MainActor package final class HostPermissionCenter: ObservableObject {
    package let drivers: [HostPermissionDriver]
    private let byID: [HostPermissionID: HostPermissionDriver]
    private let legacyDeclarations: (PluginManifest) -> [PluginPermissionDeclaration]
    @Published package private(set) var statuses: [HostPermissionID: HostPermissionStatus] = [:]
    @Published package private(set) var requesting: HostPermissionID?
    @Published package private(set) var messages: [HostPermissionID: String] = [:]
    @Published var pendingRequest: HostPermissionRequest?
    @Published package var settingsPage: HostSettingsPage = .general
    package var presentManagement: () -> Void = {}

    package init(
        drivers: [HostPermissionDriver],
        legacyDeclarations: @escaping (PluginManifest) -> [PluginPermissionDeclaration] = { _ in [] }
    ) {
        precondition(Set(drivers.map { $0.descriptor.id }).count == drivers.count)
        self.drivers = drivers
        self.byID = Dictionary(uniqueKeysWithValues: drivers.map { ($0.descriptor.id, $0) })
        self.legacyDeclarations = legacyDeclarations
        refresh()
    }

    package func declarations(for manifest: PluginManifest) -> [PluginPermissionDeclaration] {
        manifest.permissions ?? legacyDeclarations(manifest)
    }
    package func validate(_ manifest: PluginManifest) throws {
        let declarations = declarations(for: manifest)
        guard Set(declarations.map(\.id)).count == declarations.count,
            declarations.allSatisfy({ byID[$0.id] != nil })
        else {
            throw PluginError.invalid("插件声明了重复或宿主尚未支持的权限，请更新主应用。")
        }
    }
    package func status(_ id: HostPermissionID) -> HostPermissionStatus { statuses[id] ?? .notGranted }
    package func refresh(_ ids: Set<HostPermissionID>? = nil) {
        var next = statuses
        for driver in drivers where ids?.contains(driver.descriptor.id) ?? true {
            next[driver.descriptor.id] = driver.status()
        }
        if next != statuses { statuses = next }
    }
    package func reveal() {
        settingsPage = .permissions
        refresh()
        presentManagement()
    }
    package func require(_ ids: Set<HostPermissionID>, for plugin: InstalledPlugin, displayName: String? = nil) throws {
        guard plugin.isEnabled else { throw PluginError.invalid("插件已停用。") }
        let declared = Set(declarations(for: plugin.manifest).map(\.id))
        guard ids.isSubset(of: declared), ids.allSatisfy({ byID[$0] != nil }) else {
            throw PluginError.invalid("插件请求了未声明或不支持的权限。")
        }
        guard !ids.isEmpty else { return }
        // Always query the OS again: permissions can be revoked while the app is running.
        refresh(ids)
        let missing = ids.filter { status($0) != .authorized }
        guard !missing.isEmpty else { return }
        pendingRequest = .init(pluginID: plugin.id, pluginName: displayName ?? plugin.manifest.name, permissions: Set(missing))
        reveal()
        throw HostPermissionError.missing
    }
    /// Optional capabilities must not present permission management or steal the user's
    /// insertion focus. Check the live driver, declaration and plugin state without prompting.
    package func isAuthorized(_ id: HostPermissionID, for plugin: InstalledPlugin) -> Bool {
        plugin.isEnabled && declarations(for: plugin.manifest).contains { $0.id == id } && byID[id]?.status() == .authorized
    }
    package func request(_ id: HostPermissionID) async {
        guard requesting == nil, let driver = byID[id] else { return }
        refresh()
        guard status(id) != .authorized else { return }
        guard status(id) != .restricted, status(id) != .denied else { return }
        requesting = id
        defer { requesting = nil }
        await driver.request()
        refresh()
        messages[id] = status(id) == .authorized ? nil : "请在系统隐私设置中允许 \(HostInfo.name)；部分权限更改后需要重新启动应用。"
    }
    package func openSettings(_ id: HostPermissionID) { byID[id]?.openSettings() }

    package static let shortcutRoutingPermissions: Set<HostPermissionID> = [.accessibility]

    /// This grant is for the host's explicit shortcut-routing mode, not plugin input access.
    /// Query without publishing from a tap callback; plugins still use declaration-checked require.
    package func hasShortcutRoutingAccess() -> Bool {
        Self.shortcutRoutingPermissions.allSatisfy { byID[$0]?.status() == .authorized }
    }
    package func revealShortcutRoutingPermissions() {
        refresh(Self.shortcutRoutingPermissions)
        pendingRequest = .init(hostShortcutRouting: Self.shortcutRoutingPermissions)
        reveal()
    }
}
