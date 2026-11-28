import Combine
import Foundation

struct HostPermissionID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    static let screenRecording = Self(rawValue: "system.screenRecording")
    static let accessibility = Self(rawValue: "system.accessibility")
    static let inputMonitoring = Self(rawValue: "system.inputMonitoring")
    static let camera = Self(rawValue: "system.camera")
    static let microphone = Self(rawValue: "system.microphone")
    static let notifications = Self(rawValue: "system.notifications")
}

struct PluginPermissionDeclaration: Codable, Equatable, Sendable {
    let id: HostPermissionID
    let reason: String
    var optional: Bool?
    var isOptional: Bool { optional == true }
}

enum HostPermissionStatus: Equatable {
    case authorized, notDetermined, notGranted, denied, restricted, unknown
    var title: String {
        switch self {
        case .authorized: "已授权"
        case .notDetermined: "尚未请求"
        case .notGranted: "未授权"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .unknown: "状态未知"
        }
    }
}

struct HostPermissionDescriptor: Identifiable {
    let id: HostPermissionID
    let title: String
    let summary: String
    let symbol: String
}

@MainActor struct HostPermissionDriver {
    let descriptor: HostPermissionDescriptor
    let status: () -> HostPermissionStatus
    let request: () async -> Void
    let openSettings: () -> Void
    var asyncStatus: (() async -> HostPermissionStatus)? = nil
}

enum HostSettingsPage: String, CaseIterable { case general, softwareUpdate, permissions }

struct HostPermissionRequest: Identifiable, Equatable {
    let pluginID: String
    let pluginName: String
    let permissions: Set<HostPermissionID>
    var id: String { pluginID }
}

enum HostPermissionError: LocalizedError {
    case missing
    var errorDescription: String? { "请在插件的“权限与能力”中完成授权后重试。" }
}

/// No native module owns OS authorization. All status, prompting and settings links pass through this broker.
@MainActor final class HostPermissionCenter: ObservableObject {
    let drivers: [HostPermissionDriver]
    private let byID: [HostPermissionID: HostPermissionDriver]
    private let legacyDeclarations: (PluginManifest) -> [PluginPermissionDeclaration]
    private var statusQueries: [HostPermissionID: UUID] = [:]
    @Published private(set) var statuses: [HostPermissionID: HostPermissionStatus] = [:]
    @Published private(set) var requesting: HostPermissionID?
    @Published private(set) var messages: [HostPermissionID: String] = [:]
    @Published var pendingRequest: HostPermissionRequest?
    @Published var settingsPage: HostSettingsPage = .general
    var presentManagement: () -> Void = {}
    var presentPluginManagement: ((String) -> Void)?

    init(
        drivers: [HostPermissionDriver],
        legacyDeclarations: @escaping (PluginManifest) -> [PluginPermissionDeclaration] = { _ in [] }
    ) {
        precondition(Set(drivers.map { $0.descriptor.id }).count == drivers.count)
        self.drivers = drivers
        self.byID = Dictionary(uniqueKeysWithValues: drivers.map { ($0.descriptor.id, $0) })
        self.legacyDeclarations = legacyDeclarations
        refresh()
    }

    func declarations(for manifest: PluginManifest) -> [PluginPermissionDeclaration] {
        manifest.permissions ?? legacyDeclarations(manifest)
    }
    func validate(_ manifest: PluginManifest) throws {
        let declarations = declarations(for: manifest)
        guard Set(declarations.map(\.id)).count == declarations.count,
            declarations.allSatisfy({ byID[$0.id] != nil })
        else {
            throw PluginError.invalid("插件声明了重复或宿主尚未支持的权限，请更新主应用。")
        }
    }
    func status(_ id: HostPermissionID) -> HostPermissionStatus { statuses[id] ?? .unknown }
    func refresh(_ ids: Set<HostPermissionID>? = nil) {
        var next = statuses
        for driver in drivers where driver.asyncStatus == nil && (ids?.contains(driver.descriptor.id) ?? true) {
            next[driver.descriptor.id] = driver.status()
        }
        if next != statuses { statuses = next }
    }
    func refreshForDisplay(_ ids: Set<HostPermissionID>? = nil) async {
        refresh(ids)
        for driver in drivers where driver.asyncStatus != nil && (ids?.contains(driver.descriptor.id) ?? true) {
            _ = await systemStatus(driver.descriptor.id)
        }
    }
    func systemStatus(_ id: HostPermissionID) async -> HostPermissionStatus {
        guard let query = byID[id]?.asyncStatus else {
            refresh([id])
            return status(id)
        }
        let token = UUID()
        statusQueries[id] = token
        let result = await query()
        if statusQueries[id] == token {
            statusQueries[id] = nil
            if statuses[id] != result { statuses[id] = result }
        }
        return result
    }
    func reveal() {
        settingsPage = .permissions
        refresh()
        presentManagement()
    }
    func require(_ ids: Set<HostPermissionID>, for plugin: InstalledPlugin) throws {
        try validateRequest(ids, for: plugin)
        guard ids.allSatisfy({ byID[$0]?.asyncStatus == nil }) else {
            throw PluginError.invalid("此权限需要异步检查。")
        }
        guard !ids.isEmpty else { return }
        // Always query the OS again: permissions can be revoked while the app is running.
        refresh(ids)
        let missing = ids.filter { status($0) != .authorized }
        guard !missing.isEmpty else { return }
        try reportMissing(missing, for: plugin)
    }
    func requireAsynchronously(_ id: HostPermissionID, currentPlugin: () throws -> InstalledPlugin) async throws {
        try validateRequest([id], for: currentPlugin())
        let status = await systemStatus(id)
        try Task.checkCancellation()
        let plugin = try currentPlugin()
        try validateRequest([id], for: plugin)
        if status != .authorized { try reportMissing([id], for: plugin) }
    }

    private func validateRequest(_ ids: Set<HostPermissionID>, for plugin: InstalledPlugin) throws {
        guard plugin.isEnabled else { throw PluginError.invalid("插件已停用。") }
        let declared = Set(declarations(for: plugin.manifest).map(\.id))
        guard ids.isSubset(of: declared), ids.allSatisfy({ byID[$0] != nil }) else {
            throw PluginError.invalid("插件请求了未声明或不支持的权限。")
        }
    }

    private func reportMissing(_ ids: Set<HostPermissionID>, for plugin: InstalledPlugin) throws -> Never {
        let name = PluginPresentationIndex.bundled.appearance(id: plugin.id, repository: plugin.manifest.repository,
                                                              version: plugin.manifest.version)?.name ?? plugin.manifest.name
        pendingRequest = .init(pluginID: plugin.id, pluginName: name, permissions: ids)
        if let presentPluginManagement { presentPluginManagement(plugin.id) }
        else { reveal() }
        throw HostPermissionError.missing
    }
    func request(_ id: HostPermissionID) async {
        guard requesting == nil, let driver = byID[id] else { return }
        requesting = id
        defer { requesting = nil }
        let before = await systemStatus(id)
        guard before == .notGranted || before == .notDetermined else { return }
        await driver.request()
        let after = await systemStatus(id)
        messages[id] = after == .authorized ? nil : "请在系统设置中允许 \(HostInfo.name)；部分权限更改后需要重新启动应用。"
    }
    func openSettings(_ id: HostPermissionID) { byID[id]?.openSettings() }

}

/// A plugin receives this client from the host; it cannot manufacture an OS grant.
@MainActor struct PluginPermissionClient {
    let require: (Set<HostPermissionID>) throws -> Void
}
