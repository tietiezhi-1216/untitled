import AppKit
import UntitledPluginSDK
import Combine
import Foundation

@MainActor
package final class PluginStore: ObservableObject {
    @Published package private(set) var installed: [InstalledPlugin] = []
    @Published package private(set) var catalog: [CatalogEntry] = []
    @Published package private(set) var isRefreshing = false
    @Published package private(set) var isInstalling = false
    @Published package private(set) var catalogError: String?
    @Published package private(set) var hotKeyErrors: [UUID: String] = [:]
    private var windowShortcuts: [String: [ActionKind: [HotKey]]] = [:]
    @Published package private(set) var hotKeysPaused = false
    @Published package private(set) var priorityHotKeysEnabled = false
    @Published package private(set) var priorityHotKeyStatus: String?
    @Published package private(set) var priorityHotKeyRecoveryNeeded = false
    @Published package private(set) var sideButtonRecoveryNeeded = false
    @Published package private(set) var modifierRecoveryNeeded = false
    package var shortcutRecoveryNeeded: Bool { priorityHotKeyRecoveryNeeded || sideButtonRecoveryNeeded || modifierRecoveryNeeded }
    @Published package var errorMessage: String?
    private var shortcutRegistrationNotice:(commandID:UUID,message:String)?
    @Published package var requestedPluginID: String?
    package var showMainWindow: () -> Void = {}
    package let runtime: PluginRuntimeRegistry
    package let uiRegistry: PluginUIRegistry
    package let permissions: HostPermissionCenter
    struct AccessSelection: Identifiable { let id: String }
    @Published var accessSelection: AccessSelection?
    private var nativeFilePicker: NativeFilePicker?
    private var nativeCapabilityLeases: [String: UUID] = [:]
    private var isPreparingForQuit = false
    package var allowsPluginActivity: Bool { !isPreparingForQuit }

    package func enabledPlugin(_ pluginID: String, allowing action: ActionKind) -> InstalledPlugin? {
        guard allowsPluginActivity else { return nil }
        return installed.first { $0.id == pluginID && $0.isEnabled && $0.allowsAction(action) }
    }
    package func publishRuntimeEvent(_ event: PluginRuntimeEvent) { runtime.receive(event, in: self) }
    package var pluginPreferencesDirectory: URL { directory.appendingPathComponent("Preferences", isDirectory: true) }

    package func matchesWindowShortcut(keyCode: UInt32, modifiers: UInt32, action: ActionKind, pluginID: String) -> Bool {
        guard allowsPluginActivity else { return false }
        return windowShortcuts[pluginID]?[action]?.contains { $0.keyCode == keyCode && $0.modifiers == modifiers } == true
    }

    package func launch(arguments: [String]) async {
        guard allowsPluginActivity else { return }
        publishRuntimeEvent(.willLaunch(arguments))
        if let i = arguments.firstIndex(of: "--install-plugin"), arguments.indices.contains(i + 1) {
            await importPackage(URL(fileURLWithPath: arguments[i + 1]))
        }
        if allowsPluginActivity { publishRuntimeEvent(.didLaunch(arguments)) }
    }

    deinit {
        priorityRecoveryTask?.cancel()
        if let isolatedShortcutDomain { UserDefaults.standard.removePersistentDomain(forName: isolatedShortcutDomain) }
    }

    package func prepareForQuit() async -> Bool {
        isPreparingForQuit = true
        nativeCapabilityLeases.removeAll()
        nativeFilePicker?.cancel()
        cancelPriorityRecovery(); priorityHotKeyRecoveryNeeded = false
        hotKeys.clear(); priorityHotKeys.shutdown(); sideButtons.shutdown(); modifierKeys.clear()
        let ready = await runtime.prepareForQuit()
        if !ready {
            isPreparingForQuit = false
            reloadHotKeys()
            publishRuntimeEvent(.installedPluginsChanged)
        }
        return ready
    }

    private let directory: URL
    package let presentations: PluginPresentationIndex
    private var documentationCache: [(key: String, text: String)] = []
    private let startupError: String?
    private let hotKeys: HotKeyManager
    private let shortcutDefaults: UserDefaults
    private let isolatedShortcutDomain: String?
    private let priorityDriver: PriorityHotKeyDriver
    private let sideButtonDriver: PriorityHotKeyDriver
    private var priorityFailure: String?
    private var sideButtonFailure: String?
    private let modifierDriver: PriorityHotKeyDriver
    private var modifierFailure: String?
    private lazy var modifierKeys = ModifierShortcutMonitor(driver: modifierDriver, access: { [weak self] in
        self?.permissions.hasShortcutRoutingAccess() == true
    }, ignoreEvent: { [weak self] event in
        self?.runtime.ignoresShortcutEvent(event) == true
    }, failed: { [weak self] reason in
        self?.modifierFailure = reason; self?.reloadHotKeys()
    })
    private lazy var sideButtons = PriorityHotKeyMonitor(driver: sideButtonDriver, channel: .sideButtons, accessAllowed: { [weak self] in
        self?.permissions.hasShortcutRoutingAccess() == true
    }, ignoreEvent: { [weak self] event in
        event.getIntegerValueField(.eventSourceUnixProcessID) != 0 || self?.runtime.ignoresShortcutEvent(event) == true
    }, noteOwnership: { [weak self] code, _ in
        self?.publishRuntimeEvent(.shortcutOwned(code, mouse: true))
    }, ownershipChanged: { [weak self] in
        self?.publishRuntimeEvent(.shortcutOwnershipChanged)
    }, failed: { [weak self] message in
        self?.sideButtonFailure = message; self?.reloadHotKeys()
    })
    private lazy var priorityHotKeys = PriorityHotKeyMonitor(driver: priorityDriver, accessAllowed: { [weak self] in
        self?.permissions.hasShortcutRoutingAccess() == true
    }, ignoreEvent: { [weak self] event in
        event.getIntegerValueField(.eventSourceUnixProcessID) != 0 || self?.runtime.ignoresShortcutEvent(event) == true
    }, noteOwnership: { [weak self] code, _ in
        self?.publishRuntimeEvent(.shortcutOwned(code, mouse: false))
    }, ownershipChanged: { [weak self] in
        self?.publishRuntimeEvent(.shortcutOwnershipChanged)
    }, failed: { [weak self] message in
        self?.priorityFailure = message; self?.reloadHotKeys()
    })
    private var recordingObserver: AnyCancellable?
    private var shortcutPermissionObserver: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var workspaceRecoveryObserver: AnyCancellable?
    private let priorityRecoverySleep: @MainActor (Duration) async throws -> Void
    private var priorityRecoveryTask: Task<Void,Never>?
    private var priorityRecoveryGeneration: UInt64 = 0
    package static let priorityRecoveryDelays: [Duration] = [.milliseconds(250),.milliseconds(500),.seconds(1),.seconds(2),.seconds(4),.seconds(8),.seconds(16),.seconds(30)]
    package var priorityRecoveryIsScheduled:Bool { priorityRecoveryTask != nil }

    package init(runtime: PluginRuntimeRegistry, directory: URL?, startupError: String?,
         uiRegistry: PluginUIRegistry, permissions: HostPermissionCenter, shortcutDefaults: UserDefaults?,
         priorityHotKeyDriver: PriorityHotKeyDriver?, ordinaryHotKeyDriver: HotKeyManager.Driver?,
         sideButtonDriver: PriorityHotKeyDriver?, modifierDriver: PriorityHotKeyDriver?,
         priorityRecoverySleep: @escaping @MainActor (Duration) async throws -> Void,
         presentations: PluginPresentationIndex, initialCatalog: [CatalogEntry]) {
        self.runtime = runtime
        self.hotKeys = HotKeyManager(driver: ordinaryHotKeyDriver)
        self.priorityRecoverySleep = priorityRecoverySleep
        self.presentations = presentations
        self.catalog = initialCatalog
        self.startupError = startupError
        if let shortcutDefaults {
            self.shortcutDefaults = shortcutDefaults
            isolatedShortcutDomain = nil
        } else if directory != nil {
            let domain = HostInfo.bundleIdentifier + ".shortcuts.isolated." + UUID().uuidString
            self.shortcutDefaults = UserDefaults(suiteName: domain)!
            isolatedShortcutDomain = domain
        } else {
            self.shortcutDefaults = .standard
            isolatedShortcutDomain = nil
        }
        self.priorityDriver = priorityHotKeyDriver ?? (directory == nil ? .native : .unavailable)
        self.sideButtonDriver = sideButtonDriver ?? (directory == nil ? .native(for: .sideButtons) : .unavailable)
        self.modifierDriver = modifierDriver ?? (directory == nil ? .native(for: .modifierOnly) : .unavailable)
        self.priorityHotKeysEnabled = self.shortcutDefaults.bool(forKey: "shortcuts.priorityEnabled")
        self.uiRegistry = uiRegistry
        self.permissions = permissions
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.untitled.app/Plugins", isDirectory: true)
        do {
            if let startupError { throw PluginError.invalid(startupError) }
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let record = try JSONDecoder().decode(InstalledPlugin.self, from: Data(contentsOf: file))
                    try record.manifest.validate()
                    try runtime.validate(record.manifest)
                    try self.uiRegistry.validate(record.manifest)
                    try self.permissions.validate(record.manifest)
                    guard file.lastPathComponent == record.id + ".json",
                          Set(record.commands.map(\.id)).count == record.commands.count else {
                        throw PluginError.invalid("插件配置标识不一致。")
                    }
                    for command in record.commands where command.isEnabled {
                        try command.validate(allowedActions: record.manifest.actions)
                    }
                    installed.append(record)
                } catch {
                    errorMessage = "部分插件配置无法读取，原文件已保留：\(file.lastPathComponent)\n\(error.localizedDescription)"
                }
            }
            reloadHotKeys()
            publishRuntimeEvent(.installedPluginsChanged)
        } catch { errorMessage = "无法读取插件目录：\(error.localizedDescription)" }
        recordingObserver = NotificationCenter.default.publisher(for: HotKeyRecordingSession.changed).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadHotKeys() }
        }
        shortcutPermissionObserver = self.permissions.$statuses.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.usesTapRouting else { return }
                    if self.shortcutRecoveryNeeded || !self.permissions.hasShortcutRoutingAccess() { self.retryHotKeys() }
                }
            }
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self, self.usesTapRouting else { return }
                self.permissions.refresh(HostPermissionCenter.shortcutRoutingPermissions)
                self.recoverPriorityHotKeysIfNeeded()
            } }
        let workspace=NSWorkspace.shared.notificationCenter
        workspaceRecoveryObserver=workspace.publisher(for:NSWorkspace.sessionDidBecomeActiveNotification)
            .merge(with:workspace.publisher(for:NSWorkspace.didWakeNotification))
            .receive(on:DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self,self.usesTapRouting else { return }
                self.permissions.refresh(HostPermissionCenter.shortcutRoutingPermissions)
                self.recoverPriorityHotKeysIfNeeded()
            } }
    }

    package func setPriorityHotKeysEnabled(_ value: Bool) {
        priorityHotKeysEnabled = value
        shortcutDefaults.set(value, forKey: "shortcuts.priorityEnabled")
        retryHotKeys()
        if value, !permissions.hasShortcutRoutingAccess() { permissions.revealShortcutRoutingPermissions() }
    }
    package func setHotKeysPaused(_ value: Bool) {
        hotKeysPaused = value
        reloadHotKeys()
    }
    private var usesTapRouting: Bool { priorityHotKeysEnabled || shortcutRecoveryNeeded || sideButtons.isRunning || modifierKeys.isRunning }
    private var routeHasOutstandingKeys: Bool {
        sideButtons.hasOutstandingKeys || priorityHotKeys.hasOutstandingKeys || modifierKeys.hasOutstandingKeys
    }
    private var recoveryIsSecure: Bool {
        (priorityHotKeyRecoveryNeeded && priorityDriver.secureInput()) || (sideButtonRecoveryNeeded && sideButtonDriver.secureInput()) ||
            (modifierRecoveryNeeded && modifierDriver.secureInput())
    }
    package func retryHotKeys() {
        priorityFailure = nil; sideButtonFailure = nil; modifierFailure = nil
        reloadHotKeys()
    }
    /// Permission snapshots can remain unchanged when Secure Input ends. A
    /// lifecycle event must still recover a failed route, but never churn a
    /// healthy tap or cancel an in-flight priority stroke.
    package func recoverPriorityHotKeysIfNeeded() {
        guard shortcutRecoveryNeeded,!hotKeysPaused,
              !isPreparingForQuit,!HotKeyRecordingSession.isRecording else { return }
        if permissions.hasShortcutRoutingAccess(), !recoveryIsSecure, !routeHasOutstandingKeys { retryHotKeys() }
        else { schedulePriorityRecovery() }
    }
    private func cancelPriorityRecovery() {
        priorityRecoveryGeneration &+= 1
        priorityRecoveryTask?.cancel();priorityRecoveryTask=nil
    }
    private func schedulePriorityRecovery() {
        guard priorityRecoveryTask == nil,shortcutRecoveryNeeded,
              !hotKeysPaused,!isPreparingForQuit,!HotKeyRecordingSession.isRecording,
              permissions.hasShortcutRoutingAccess() else { return }
        let generation=priorityRecoveryGeneration,sleep=priorityRecoverySleep
        priorityRecoveryTask=Task { @MainActor [weak self] in
            defer { if self?.priorityRecoveryGeneration == generation { self?.priorityRecoveryTask=nil } }
            // One finite episode: eight readiness checks over 61.75s. After it
            // ends, activation/unlock/wake or explicit retry can start another.
            for delay in Self.priorityRecoveryDelays {
                do { try await sleep(delay) } catch { return }
                guard !Task.isCancelled,let self,self.priorityRecoveryGeneration == generation,
                      self.shortcutRecoveryNeeded,!self.hotKeysPaused,
                      !self.isPreparingForQuit,!HotKeyRecordingSession.isRecording,
                      self.permissions.hasShortcutRoutingAccess() else { return }
                if self.recoveryIsSecure || self.routeHasOutstandingKeys { continue }
                self.priorityFailure=nil; self.sideButtonFailure=nil; self.modifierFailure=nil
                self.reloadHotKeys(automaticRecovery:true)
                if !self.shortcutRecoveryNeeded { return }
            }
        }
    }

    package func refreshCatalog() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        catalogError = nil
        defer { isRefreshing = false }
        do {
            let data = try await Self.fetch(HostInfo.catalog, maximumBytes: 2 * 1024 * 1024)
            let catalog = try JSONDecoder().decode(PluginCatalog.self, from: data)
            try catalog.validate()
            let entries = catalog.plugins.map(IdentityMigration.catalogEntry)
            try PluginCatalog(schemaVersion: catalog.schemaVersion, plugins: entries).validate()
            self.catalog = entries
        } catch { catalogError = "无法加载插件商店：\(error.localizedDescription)" }
    }

    package func install(_ entry: CatalogEntry) async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            try entry.validate()
            let data = try await Self.fetch(entry.downloadURL, maximumBytes: PluginArchive.maximumPackageSize)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            let contents = try await Task.detached {
                try PluginArchive.readContents(temporary, expectedSHA256: entry.sha256)
            }.value
            let manifest = IdentityMigration.manifest(contents.manifest)
            guard manifest.id == IdentityMigration.catalogEntry(entry).id, manifest.version == entry.version else {
                throw PluginError.invalid("插件包与商店记录不一致。")
            }
            try installManifest(manifest, readme: contents.readme)
        } catch { errorMessage = "安装失败：\(error.localizedDescription)" }
    }

    package func importPackage(_ url: URL) async {
        guard !isInstalling else { return }
        isInstalling = true
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            isInstalling = false
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let contents = try await Task.detached { try PluginArchive.readContents(url) }.value
            let manifest = IdentityMigration.manifest(contents.manifest)
            try installManifest(manifest, readme: contents.readme)
            requestedPluginID = manifest.id
        } catch { errorMessage = "安装失败：\(error.localizedDescription)" }
    }

    package func installManifest(_ source: PluginManifest, readme: String? = nil) throws {
        guard readme.map({ $0.utf8.count <= PluginArchive.maximumReadmeSize }) ?? true else {
            throw PluginError.invalid("插件说明超过 128 KiB 限制。")
        }
        let manifest = IdentityMigration.manifest(source)
        try manifest.validate()
        try runtime.validate(manifest)
        try uiRegistry.validate(manifest)
        try permissions.validate(manifest)
        if let previous = installed.first(where: { $0.id == manifest.id }) {
            var record = previous
            guard Version(manifest.version)! >= Version(record.manifest.version)! else {
                throw PluginError.invalid("不能安装更早版本的插件。")
            }
            uiRegistry.migrateBindings(in: &record, to: manifest, occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            guard record.commands.allSatisfy({ manifest.actions.contains($0.action) }) else {
                throw PluginError.invalid("新版本不再支持部分已有操作，请先移除这些操作。")
            }
            if manifest.version != record.manifest.version || readme != nil { record.readme = readme }
            record.manifest = manifest
            let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            // A failed write must not interrupt the currently running module.
            try save(record, reloadBindings: false)
            invalidateNativeCapabilities(for: record.id)
            runtime.didReplace(previous, with: record, in: self)
            reloadHotKeys()
            reportDefaultConflicts(conflicts)
        } else {
            var record = InstalledPlugin(manifest: manifest, commands: [])
            record.readme = readme
            let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            try save(record)
            reportDefaultConflicts(conflicts)
        }
        publishRuntimeEvent(.installedPluginsChanged)
    }

    package func presentation(for action: ActionKind) -> PluginActionPresentation { runtime.presentation(for: action) }
    package func title(for command: PluginCommand) -> String {
        command.title(actionTitle: presentation(for: command.action).title)
    }

    package func presentation(for manifest: PluginManifest) -> PluginPresentation {
        let bundled = presentations.appearance(id: manifest.id, repository: manifest.repository, version: manifest.version)
        return PluginPresentation(id: manifest.id, repository: manifest.repository, version: manifest.version,
            name: bundled?.name ?? manifest.name, summary: bundled?.summary ?? manifest.summary,
            icon: bundled?.icon ?? manifest.icon ?? PluginIcon(symbol: uiRegistry.interface(for: manifest).icon ?? "puzzlepiece.extension", tint: "#5875E7"), readmeURL: bundled?.readmeURL,
            storefront: bundled?.storefront ?? manifest.storefront)
    }

    package func presentation(for entry: CatalogEntry) -> PluginPresentation {
        let repository = URL(string: "https://github.com/" + entry.downloadURL.pathComponents.dropFirst().prefix(2).joined(separator: "/"))!
        let bundled = presentations.appearance(id: entry.id, repository: repository, version: entry.version)
        return PluginPresentation(id: entry.id, repository: repository, version: entry.version,
            name: bundled?.name ?? entry.name, summary: bundled?.summary ?? entry.summary, icon: bundled?.icon ?? entry.icon,
            readmeURL: bundled?.readmeURL, storefront: bundled?.storefront ?? entry.storefront)
    }

    package func documentation(for entry: CatalogEntry) async throws -> String? {
        if let plugin = installed.first(where: { $0.id == entry.id && $0.manifest.version == entry.version }), let readme = plugin.readme {
            return readme
        }
        let key = entry.id + ":" + entry.version + ":" + entry.sha256
        if let cached = documentationCache.first(where: { $0.key == key }) { return cached.text }
        try entry.validate()
        let data = try await Self.fetch(entry.downloadURL, maximumBytes: PluginArchive.maximumPackageSize)
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let contents = try await Task.detached { try PluginArchive.readContents(temporary, expectedSHA256: entry.sha256) }.value
        try Task.checkCancellation()
        let manifest = IdentityMigration.manifest(contents.manifest)
        guard manifest.id == entry.id, manifest.version == entry.version else {
            throw PluginError.invalid("插件说明与商店记录不一致。")
        }
        if let text = contents.readme {
            documentationCache.removeAll { $0.key == key }
            documentationCache.append((key, text))
            if documentationCache.count > 8 { documentationCache.removeFirst() }
            if var record = installed.first(where: { $0.id == entry.id && $0.manifest.version == entry.version }) {
                record.readme = text
                try save(record, reloadBindings: false)
            }
        }
        return contents.readme
    }

    package func restoreDefaultCommands(pluginID: String) throws {
        guard var record = installed.first(where: { $0.id == pluginID }) else { throw PluginError.invalid("插件已卸载。") }
        let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: pluginID), restoring: true)
        try save(record)
        reportDefaultConflicts(conflicts)
    }

    private func occupiedHotKeys(excluding pluginID: String) -> Set<String> {
        Set(installed.filter { $0.id != pluginID && $0.isEnabled }.flatMap(\.commands)
            .filter(\.isEnabled).compactMap { $0.hotKey?.identity })
    }

    private func reportDefaultConflicts(_ titles: [String]) {
        if !titles.isEmpty {
            errorMessage = "这些操作的默认快捷键已被占用，已保留原绑定；可在快捷键页重新设置：" + titles.joined(separator: "、")
        }
    }

    package func setEnabled(_ enabled: Bool, pluginID: String) {
        guard var record = installed.first(where: { $0.id == pluginID }) else { return }
        record.isEnabled = enabled
        do { try save(record) }
        catch { errorMessage = error.localizedDescription; return }
        if !enabled { invalidateNativeCapabilities(for: pluginID) }
        runtime.didSetEnabled(record, in: self)
        publishRuntimeEvent(.installedPluginsChanged)
    }

    func showPluginAccess(_ pluginID: String) {
        guard installed.contains(where: { $0.id == pluginID }) else { return }
        requestedPluginID = pluginID
        accessSelection = .init(id: pluginID)
        showMainWindow()
    }

    func setNativeActionAllowed(_ allowed: Bool, action: ActionKind, pluginID: String) {
        guard action.isNativeUtility, var record = installed.first(where: { $0.id == pluginID }),
              record.manifest.actions.contains(action), record.allowsAction(action) != allowed else { return }
        var blocked = record.blockedNativeActions ?? []
        if allowed { blocked.remove(action) } else { blocked.insert(action) }
        record.blockedNativeActions = blocked.isEmpty ? nil : blocked
        do {
            try save(record)
            invalidateNativeCapabilities(for: pluginID)
        } catch { errorMessage = error.localizedDescription }
    }

    package func saveCommand(_ command: PluginCommand, pluginID: String) throws {
        guard var record = installed.first(where: { $0.id == pluginID }) else { throw PluginError.invalid("插件已卸载。") }
        try command.validate(allowedActions: record.manifest.actions)
        try uiRegistry.validateBinding(command, in: record)
        if command.isEnabled, record.isEnabled, let hotKey = command.hotKey {
            for plugin in installed where plugin.isEnabled {
                for other in plugin.commands where other.isEnabled && other.id != command.id {
                    if other.hotKey?.identity == hotKey.identity {
                        throw PluginError.invalid("\(hotKey.display) 已绑定到「\(title(for: other))」。")
                    }
                }
            }
        }
        if let index = record.commands.firstIndex(where: { $0.id == command.id }) { record.commands[index] = command }
        else { record.commands.append(command) }
        try save(record)
        if let failure = hotKeyErrors[command.id] {
            let message="操作已保存，但快捷键未生效：\(failure)"
            shortcutRegistrationNotice=(command.id,message)
            errorMessage=message
        }
    }

    package func removeCommand(_ commandID: UUID, pluginID: String) {
        guard var record = installed.first(where: { $0.id == pluginID }) else { return }
        record.commands.removeAll { $0.id == commandID }
        do { try save(record) } catch { errorMessage = error.localizedDescription }
    }

    package func uninstall(_ pluginID: String) {
        guard let plugin = installed.first(where: { $0.id == pluginID }) else { return }
        do {
            try runtime.willUninstall(plugin, in: self)
            try FileManager.default.removeItem(at: directory.appendingPathComponent(pluginID + ".json"))
            installed.removeAll { $0.id == pluginID }
            invalidateNativeCapabilities(for: pluginID)
            if accessSelection?.id == pluginID { accessSelection = nil }
            reloadHotKeys()
        } catch { errorMessage = "卸载失败：\(error.localizedDescription)" }
        publishRuntimeEvent(.installedPluginsChanged)
    }

    package func execute(_ command: PluginCommand, pluginID: String) async {
        guard commandIsAvailable(command, pluginID: pluginID) else { return }
        do {
            try command.action.validateTarget(command.target)
            if let owner = runtime.owner(of: command.action) {
                try await owner.perform(command, for: pluginID, in: self)
            } else {
                try await ActionExecutor.execute(command, showMainWindow: showMainWindow) { [self] command in
                    try await nativeCapabilities(for: pluginID).execute(command)
                }
            }
        } catch { handleExecutionError(error) }
    }
    private func commandIsAvailable(_ command: PluginCommand, pluginID: String) -> Bool {
        command.isEnabled && enabledPlugin(pluginID, allowing: command.action)?.commands.contains(command) == true
    }

    package func refreshShortcutBindings() { reloadHotKeys(); objectWillChange.send() }
    package func routeShortcutInput(_ type: CGEventType, _ event: CGEvent) -> Bool {
        priorityHotKeys.handle(type, event) || sideButtons.handle(type, event)
    }
    package func ownsShortcutInput(_ code: UInt32, mouse: Bool) -> Bool {
        mouse ? sideButtons.ownsKey(code) : priorityHotKeys.ownsKey(code)
    }
    package var hasOutstandingShortcutInput: Bool { priorityHotKeys.hasOutstandingKeys || sideButtons.hasOutstandingKeys }

    package func registerTemporaryShortcut(_ key: HotKey, pluginID: String, action: ActionKind,
                                   onPress: @escaping () -> Void) -> (() -> Void)? {
        guard !hotKeysPaused, !HotKeyRecordingSession.isRecording, enabledPlugin(pluginID, allowing: action) != nil,
              !runtime.reservesShortcut(key),
              !installed.contains(where: { plugin in
                  plugin.isEnabled && plugin.commands.contains { $0.isEnabled && $0.hotKey?.identity == key.identity }
              }) else { return nil }
        return try? hotKeys.registerScoped(key, action: onPress)
    }

    package func permissionClient(for pluginID: String) -> PluginPermissionClient {
        PluginPermissionClient(isAuthorized: { [weak self] id in
            guard let self, let plugin = self.installed.first(where: { $0.id == pluginID }) else { return false }
            return self.permissions.isAuthorized(id, for: plugin)
        }) { [weak self] ids in
            guard let self, let plugin = self.installed.first(where: { $0.id == pluginID }) else {
                throw PluginError.invalid("插件已卸载。")
            }
            try self.permissions.require(ids, for: plugin, displayName: self.presentation(for: plugin.manifest).name)
        }
    }

    func nativeCapabilities(for pluginID: String) -> PluginNativeCapabilityClient {
        let lease = nativeCapabilityLeases[pluginID] ?? UUID()
        if installed.contains(where: { $0.id == pluginID }) { nativeCapabilityLeases[pluginID] = lease }
        let picker = nativeFilePicker ?? NativeFilePicker()
        nativeFilePicker = picker
        return PluginNativeCapabilityClient(
            pluginID: pluginID, permissions: permissions, filePicker: picker,
            currentPlugin: { [weak self] action in
                guard let self, !self.isPreparingForQuit,
                      let plugin = self.installed.first(where: { $0.id == pluginID }), plugin.isEnabled else {
                    throw PluginError.invalid("请先启用插件。")
                }
                guard self.nativeCapabilityLeases[pluginID] == lease else { throw CancellationError() }
                guard plugin.allowsAction(action) else { throw PluginError.invalid("此能力尚未声明或已在插件设置中停用。") }
                return plugin
            }, presentFilePicker: { [weak self] in self?.showMainWindow() })
    }

    private func invalidateNativeCapabilities(for pluginID: String) {
        nativeCapabilityLeases.removeValue(forKey: pluginID)
        nativeFilePicker?.cancel(for: pluginID)
    }

    package func handleExecutionError(_ error: Error) {
        if error is HostPermissionError || error is CancellationError { return }
        errorMessage = "执行失败：\(error.localizedDescription)"
        showMainWindow()
    }

    private func save(_ record: InstalledPlugin, reloadBindings: Bool = true) throws {
        if let startupError { throw PluginError.invalid(startupError) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent(record.id + ".json"), options: .atomic)
        if let index = installed.firstIndex(where: { $0.id == record.id }) { installed[index] = record }
        else { installed.append(record) }
        installed.sort { presentation(for: $0.manifest).name.localizedStandardCompare(presentation(for: $1.manifest).name) == .orderedAscending }
        if reloadBindings { reloadHotKeys() }
    }

    private func reloadHotKeys(automaticRecovery:Bool=false) {
        defer {
            publishRuntimeEvent(.didReloadShortcuts)
            reconcileShortcutRegistrationNotice()
            if !automaticRecovery { schedulePriorityRecovery() }
        }
        if !automaticRecovery { cancelPriorityRecovery() }
        priorityHotKeyRecoveryNeeded=false; sideButtonRecoveryNeeded=false; modifierRecoveryNeeded=false
        publishRuntimeEvent(.willReloadShortcuts)
        hotKeys.clear(); priorityHotKeys.clear(); sideButtons.clear(); modifierKeys.clear()
        hotKeyErrors = [:]
        windowShortcuts.removeAll()
        priorityHotKeyStatus = hotKeysPaused ? "所有快捷键已暂停" : (HotKeyRecordingSession.isRecording ? "正在录制快捷键，已暂停全局触发" : nil)
        guard !hotKeysPaused, !isPreparingForQuit, !HotKeyRecordingSession.isRecording else { return }
        var identities = Set<String>()
        var bindings: [(pluginID: String, command: PluginCommand, key: HotKey, exclusive: Bool)] = []
        for plugin in installed where plugin.isEnabled {
            for command in plugin.commands where command.isEnabled && plugin.allowsAction(command.action) {
                guard runtime.includesShortcut(command, in: plugin), let key = command.hotKey else { continue }
                do {
                    try command.validate(allowedActions: plugin.manifest.actions)
                    try uiRegistry.validateBinding(command, in: plugin)
                    guard identities.insert(key.identity).inserted else {
                        throw PluginError.invalid("这个快捷键已绑定到其他操作。")
                    }
                    let registration = runtime.owner(of: command.action)?.shortcutRegistration(for: command, key: key) ?? .exclusive
                    if registration == .window {
                        windowShortcuts[plugin.id, default: [:]][command.action, default: []].append(key)
                    } else {
                        bindings.append((plugin.id, command, key, registration == .exclusive))
                    }
                } catch { hotKeyErrors[command.id] = error.localizedDescription }
            }
        }
        // Carbon handles keyboard bindings without a tap. Only configured side buttons
        // use the mouse-only channel, independent of keyboard priority mode.
        let solo = bindings.filter { $0.key.isStandaloneModifier }
        bindings.removeAll { $0.key.isStandaloneModifier }
        if solo.isEmpty { modifierFailure = nil }
        for (pluginID, command, key, _) in solo {
            do {
                if let modifierFailure { throw PluginError.invalid(modifierFailure) }
                let gesture = runtime.owner(of: command.action)?.shortcutGesture(for: command, pluginID: pluginID,
                                                                               channel: .modifier, in: self)
                try modifierKeys.register(key, allowed: { [weak self] in self?.allowsEventShortcut(command, pluginID: pluginID) == true },
                    onRelease: gesture?.release, onCancel: gesture?.cancel) { [weak self] in
                    self?.shortcutPressed(command, pluginID: pluginID, gesture: gesture)
                }
            } catch { modifierRecoveryNeeded = true; hotKeyErrors[command.id] = error.localizedDescription }
        }
        let mouseBindings = bindings.filter { $0.key.mouseButton != nil }
        bindings.removeAll { $0.key.mouseButton != nil }
        if mouseBindings.isEmpty { sideButtonFailure = nil }
        for binding in mouseBindings {
            do {
                if let sideButtonFailure { throw PluginError.invalid(sideButtonFailure) }
                guard permissions.hasShortcutRoutingAccess() else {
                    throw PluginError.invalid("鼠标侧键需要辅助功能权限。请在菜单栏「快捷键」中授权后重试。")
                }
                try registerEventShortcut(binding.key, via: sideButtons, command: binding.command, pluginID: binding.pluginID)
            } catch { sideButtonRecoveryNeeded = true; hotKeyErrors[binding.command.id] = error.localizedDescription }
        }
        if priorityHotKeysEnabled {
            do {
                guard !bindings.isEmpty else {
                    priorityFailure=nil
                    priorityHotKeyStatus = mouseBindings.isEmpty && solo.isEmpty ? "优先模式已开启，暂无已启用的快捷键" : "优先模式已开启，暂无需要优先注册的键盘快捷键"
                    return
                }
                if let priorityFailure { throw PluginError.invalid(priorityFailure) }
                guard permissions.hasShortcutRoutingAccess() else { throw HostPermissionError.missing }
                for binding in bindings {
                    try registerEventShortcut(binding.key, via: priorityHotKeys, command: binding.command, pluginID: binding.pluginID)
                }
                priorityHotKeyStatus = "优先模式已启用 · \(bindings.count) 个快捷键"
                return
            } catch {
                priorityHotKeys.clear()
                priorityHotKeyRecoveryNeeded=true
                priorityHotKeyStatus = "优先模式未生效，已回退普通注册：\(error.localizedDescription)"
            }
        }
        for binding in bindings {
            do {
                let gesture = runtime.owner(of: binding.command.action)?.shortcutGesture(for: binding.command,
                    pluginID: binding.pluginID, channel: .ordinary, in: self)
                try hotKeys.register(binding.key, exclusive: binding.exclusive, onRelease: gesture?.release) { [weak self] in
                    self?.shortcutPressed(binding.command, pluginID: binding.pluginID, gesture: gesture)
                }
            } catch { hotKeyErrors[binding.command.id] = error.localizedDescription }
        }
    }

    private func reconcileShortcutRegistrationNotice() {
        guard let notice=shortcutRegistrationNotice else { return }
        // A later output/save/permission error belongs to another operation.
        guard errorMessage == notice.message else { shortcutRegistrationNotice=nil;return }
        guard !hotKeysPaused,!isPreparingForQuit,!HotKeyRecordingSession.isRecording else { return }
        if let failure=hotKeyErrors[notice.commandID] {
            let message="操作已保存，但快捷键未生效：\(failure)"
            shortcutRegistrationNotice=(notice.commandID,message);errorMessage=message
        } else {
            shortcutRegistrationNotice=nil;errorMessage=nil
        }
    }

    private func registerEventShortcut(_ key: HotKey, via monitor: PriorityHotKeyMonitor, command: PluginCommand, pluginID: String) throws {
        let gesture = runtime.owner(of: command.action)?.shortcutGesture(for: command, pluginID: pluginID, channel: .eventTap, in: self)
        try monitor.register(key, allowed: { [weak self] in self?.allowsEventShortcut(command, pluginID: pluginID) == true },
                             onRelease: gesture?.release, onCancel: gesture?.cancel) { [weak self] in
            self?.shortcutPressed(command, pluginID: pluginID, gesture: gesture)
        }
    }
    private func shortcutPressed(_ command: PluginCommand, pluginID: String, gesture: PluginShortcutGesture?) {
        guard !hotKeysPaused, commandIsAvailable(command, pluginID: pluginID) else { return }
        if let gesture {
            do { try gesture.press() } catch { handleExecutionError(error) }
        } else { Task { [weak self] in await self?.execute(command, pluginID: pluginID) } }
    }
    package func allowsEventShortcut(_ command: PluginCommand, pluginID: String) -> Bool {
        (priorityHotKeysEnabled || command.hotKey?.mouseButton != nil || command.hotKey?.isStandaloneModifier == true)
            && !hotKeysPaused && !HotKeyRecordingSession.isRecording && commandIsAvailable(command, pluginID: pluginID)
            && runtime.permitsShortcut(command)
    }

    private static func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Untitled/\(HostInfo.version)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw PluginError.invalid("服务器暂时无法提供下载，请稍后重试。")
        }
        guard response.expectedContentLength <= maximumBytes else { throw PluginError.invalid("下载文件超过大小限制。") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maximumBytes else { throw PluginError.invalid("下载文件超过大小限制。") }
        }
        return data
    }
}
