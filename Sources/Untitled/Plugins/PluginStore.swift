import AppKit
import Carbon
import Combine
import Foundation

@MainActor
final class PluginStore: ObservableObject {
    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var catalog: [CatalogEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isInstalling = false
    @Published private(set) var catalogError: String?
    @Published private(set) var hotKeyErrors: [UUID: String] = [:]
    @Published private(set) var captureHotKeysPaused = false
    @Published private(set) var hotKeysPaused = false
    @Published private(set) var priorityHotKeysEnabled = false
    @Published private(set) var priorityHotKeyStatus: String?
    @Published private(set) var priorityHotKeyRecoveryNeeded = false
    @Published private(set) var sideButtonRecoveryNeeded = false
    @Published private(set) var modifierRecoveryNeeded = false
    var shortcutRecoveryNeeded: Bool { priorityHotKeyRecoveryNeeded || sideButtonRecoveryNeeded || modifierRecoveryNeeded }
    @Published var errorMessage: String?
    private var shortcutRegistrationNotice:(commandID:UUID,message:String)?
    @Published var requestedPluginID: String?
    var showMainWindow: () -> Void = {}
    private let captureDirectory: URL?
    private var captureController: ScreenshotController?
    private let captureFactory: (URL?) -> ScreenshotController
    private var sharingControllers: [String: PeripheralSharingController] = [:]
    private var sharingPriorityObservers: [String: AnyCancellable] = [:]
    private var dictationControllers: [String: DoubaoDictationController] = [:]
    private let dictationFactory: (URL) -> DoubaoDictationController
    private var isPreparingForQuit = false
    func doubaoDictation(for pluginID: String) -> DoubaoDictationController {
        if let controller = dictationControllers[pluginID] { return controller }
        let controller = dictationFactory(dictationPreferencesURL(pluginID))
        controller.isAllowed = { [weak self] in
            guard let self, !self.isPreparingForQuit else { return false }
            return self.installed.contains(where: { $0.id == pluginID && $0.isEnabled && $0.manifest.actions.contains(.toggleDoubaoDictation) })
        }
        controller.requirePermissions = { [weak self] ids in
            guard let self else { throw PluginError.invalid("宿主已关闭。") }
            try self.permissionClient(for: pluginID).require(ids)
        }
        controller.hasInsertionAccess = { [weak self] in self?.permissionClient(for: pluginID).isAuthorized(.accessibility) == true }
        controller.registerEscape = { [weak self] gesture, cancel in
            self?.registerDictationEscape(for: pluginID, gesture: gesture, cancel: cancel)
        }
        dictationControllers[pluginID] = controller
        return controller
    }
    private func registerDictationEscape(for pluginID: String, gesture: DictationGesture,
                                         cancel: @escaping () -> Void) -> (() -> Void)? {
        let escape = HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, key: "⎋")
        guard pluginID == DoubaoDictationController.pluginID,
              !hotKeysPaused, !isPreparingForQuit, !HotKeyRecordingSession.isRecording,
              !sharingControllers.values.contains(where: { $0.reservesPriorityShortcut(escape) }),
              let plugin = installed.first(where: { $0.id == pluginID && $0.isEnabled && $0.manifest.actions.contains(.cancelDoubaoDictation) }) else { return nil }
        var modifiers: [UInt32] = [0]
        if case .hold(let commandID) = gesture,
           let key = plugin.commands.first(where: { $0.id == commandID && $0.isEnabled })?.hotKey {
            let mask = key.isRightCommand ? UInt32(cmdKey) : key.isRightControl ? UInt32(controlKey) : key.modifiers
            // Never try to reserve the system's Force Quit shortcut.
            if mask != 0, mask != UInt32(cmdKey | optionKey) { modifiers.append(mask) }
        }
        let configured = Set(installed.filter(\.isEnabled).flatMap { $0.commands.compactMap { $0.isEnabled ? $0.hotKey?.identity : nil } })
        let stops = modifiers.compactMap { modifier -> (() -> Void)? in
            let key = HotKey(keyCode: UInt32(kVK_Escape), modifiers: modifier, key: "⎋")
            // A saved binding (even in priority mode), sharing's emergency key,
            // or a chord reserved by macOS/another app keeps precedence.
            guard !configured.contains(key.identity) else { return nil }
            return try? hotKeys.registerScoped(key, action: cancel)
        }
        guard !stops.isEmpty else { return nil }
        return { stops.forEach { $0() } }
    }

    private func dictationPreferencesURL(_ pluginID: String) -> URL {
        directory.appendingPathComponent("Preferences", isDirectory: true).appendingPathComponent(pluginID + ".dictation.json")
    }
    func performDictationAction(_ action: ActionKind, pluginID: String, holdCommandID: UUID? = nil) throws {
        guard let plugin = installed.first(where: { $0.id == pluginID }), plugin.isEnabled,
              plugin.manifest.actions.contains(action), plugin.manifest.actions.contains(.toggleDoubaoDictation) else {
            throw PluginError.invalid("请先启用并授权语音输入插件。")
        }
        let controller = doubaoDictation(for: pluginID)
        switch action {
        case .toggleDoubaoDictation: try controller.toggle()
        case .holdDoubaoDictation:
            if let holdCommandID { try controller.holdPressed(holdCommandID) }
            else { try controller.toggle() } // The command list's Run button is a toggle, not a stuck hold.
        case .cancelDoubaoDictation: controller.cancel()
        default: throw PluginError.invalid("不支持的语音输入操作。")
        }
    }
    private let sharingDefaults: UserDefaults
    private let isolatedSharingDomain: String?
    deinit {
        priorityRecoveryTask?.cancel()
        if let isolatedSharingDomain { UserDefaults.standard.removePersistentDomain(forName: isolatedSharingDomain) }
    }
    func restorePeripheralSharingSessionIfRequested() throws {
        guard installed.contains(where: { $0.id == PeripheralSharingController.pluginID && $0.isEnabled }) else { return }
        try peripheralSharing(for: PeripheralSharingController.pluginID).restoreUserSessionIfRequested()
    }
    private var sharingSetup: SharingSetupSession?
    func startSharingSetup(at url: URL) throws {
        guard sharingSetup == nil else { return }
        let session = try SharingSetupSession(store: self, profileURL: url)
        sharingSetup = session
        try session.confirmAndStart(profileURL: url)
    }
    #if DEBUG
    private var sharingAcceptance: SharingAcceptance?
    func startSharingAcceptance(at directory: URL) throws {
        guard sharingAcceptance == nil else { return }
        sharingAcceptance = try SharingAcceptance(store: self, directory: directory)
    }
    #endif
    func peripheralSharing(for pluginID: String) -> PeripheralSharingController {
        if let controller = sharingControllers[pluginID] { return controller }
        let controller = PeripheralSharingController(defaults: sharingDefaults)
        controller.isAllowed = { [weak self] in
            self?.installed.contains(where: { $0.id == pluginID && $0.isEnabled && $0.manifest.actions.contains(.sharePeripherals) }) == true
        }
        controller.requirePermissions = { [weak self] ids in
            guard let self else { throw PluginError.invalid("宿主已关闭。") }
            try self.permissionClient(for: pluginID).require(ids)
        }
        controller.reportError = { [weak self] in self?.handleExecutionError($0) }
        controller.configurePriorityShortcutRouting(route: { [weak self] type, event in
            guard let self else { return false }
            return self.priorityHotKeys.handle(type, event) || self.sideButtons.handle(type, event)
        }, ownsKey: { [weak self] in self?.priorityHotKeys.ownsKey($0) ?? false },
        ownsButton: { [weak self] in self?.sideButtons.ownsKey($0) ?? false }, hasKeys: { [weak self] in
            guard let self else { return false }
            return self.priorityHotKeys.hasOutstandingKeys || self.sideButtons.hasOutstandingKeys
        })
        sharingPriorityObservers[pluginID] = Publishers.CombineLatest(
            controller.$control.removeDuplicates(), controller.$keyboardMouseEnabled.removeDuplicates()
        ).dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
            // @Published emits before assignment; read the settled sharing state
            // next turn before arming any Esc that sharing no longer reserves.
            Task { @MainActor [weak self] in
                self?.dictationControllers[DoubaoDictationController.pluginID]?.refreshEscapeShortcut()
            }
        }
        sharingControllers[pluginID] = controller
        return controller
    }
    let uiRegistry: PluginUIRegistry
    let permissions: HostPermissionCenter
    var screenshots: ScreenshotController {
        if let captureController { return captureController }
        let controller = captureFactory(captureDirectory)
        controller.didCopyPNG = { [weak self] data, count in
            // No controller/listener is created by copying a screenshot.
            self?.sharingControllers[PeripheralSharingController.pluginID]?.shareCopiedScreenshot(data, changeCount: count)
        }
        controller.reportError = { [weak self] in self?.errorMessage = $0 }
        if let error = controller.errorMessage { errorMessage = error }
        controller.canUseFeatures = { [weak self] in
            self?.installed.contains(where: { $0.isEnabled && $0.manifest.actions.contains(where: \.isScreenshotAction) }) == true
        }
        captureController = controller
        if let plugin = installed.first(where: { $0.isEnabled && $0.manifest.hasCaptureCapability }) {
            controller.configureGlobalMouse(permissions: permissionClient(for: plugin.id), allowed: { [weak self] in self?.captureHotKeysPaused == false && !HotKeyRecordingSession.isRecording })
        }
        controller.pinManager.activate()
        return controller
    }

    private func refreshCaptureHistoryCleanup() {
        let active = usesLiveCaptureHistory && !isPreparingForQuit &&
            installed.contains { $0.isEnabled && $0.manifest.actions.contains(.captureHistory) }
        if active { screenshots.setHistoryCleanupActive(true) }
        else { captureController?.setHistoryCleanupActive(false) }
    }

    func prepareForQuit() async -> Bool {
        isPreparingForQuit = true
        cancelPriorityRecovery();priorityHotKeyRecoveryNeeded=false
        hotKeys.clear(); priorityHotKeys.shutdown(); sideButtons.shutdown(); modifierKeys.clear()
        #if DEBUG
        sharingAcceptance?.stop(); sharingAcceptance = nil
        #endif
        sharingSetup?.stopReporting(); sharingSetup = nil
        for controller in sharingControllers.values { controller.stop() }
        for controller in dictationControllers.values { controller.cancel(message: "应用正在退出，听写已停止。") }
        for history in dictationControllers.values.map(\.history) { await history.finishPendingIO() }
        let ready = await captureController?.prepareForQuit() ?? true
        if !ready {
            isPreparingForQuit = false
            reloadHotKeys()
            refreshCaptureHistoryCleanup()
        }
        return ready
    }

    private let directory: URL
    private let usesLiveCaptureHistory: Bool
    let presentations: PluginPresentationIndex
    private var documentationCache: [(key: String, text: String)] = []
    private let startupError: String?
    private let hotKeys: HotKeyManager
    private let shortcutDefaults: UserDefaults
    private let priorityDriver: PriorityHotKeyDriver
    private let sideButtonDriver: PriorityHotKeyDriver
    private var priorityFailure: String?
    private var sideButtonFailure: String?
    private let modifierDriver: PriorityHotKeyDriver
    private var modifierFailure: String?
    private lazy var modifierKeys = ModifierShortcutMonitor(driver: modifierDriver, access: { [weak self] in
        self?.permissions.hasShortcutRoutingAccess() == true
    }, failed: { [weak self] reason in
        self?.modifierFailure = reason; self?.reloadHotKeys()
    })
    private lazy var sideButtons = PriorityHotKeyMonitor(driver: sideButtonDriver, channel: .sideButtons, accessAllowed: { [weak self] in
        self?.permissions.hasShortcutRoutingAccess() == true
    }, ignoreEvent: { $0.getIntegerValueField(.eventSourceUnixProcessID) != 0 || SharingInput.isHostShortcutReplay($0) },
    noteOwnership: { [weak self] code, _ in
        self?.sharingControllers.values.forEach { $0.notePriorityShortcutOwnership(code, mouse: true) }
    }, ownershipChanged: { [weak self] in
        self?.sharingControllers.values.forEach { $0.priorityShortcutOwnershipChanged() }
    }, failed: { [weak self] message in
        self?.sideButtonFailure = message
        self?.reloadHotKeys()
    })
    private lazy var priorityHotKeys = PriorityHotKeyMonitor(driver: priorityDriver, accessAllowed: { [weak self] in
        guard let self else { return false }
        return self.permissions.hasShortcutRoutingAccess()
    }, ignoreEvent: { $0.getIntegerValueField(.eventSourceUnixProcessID) != 0 || SharingInput.isHostShortcutReplay($0) },
    noteOwnership: { [weak self] code, _ in
        self?.sharingControllers.values.forEach { $0.notePriorityShortcutOwnership(code) }
    }, ownershipChanged: { [weak self] in
        self?.sharingControllers.values.forEach { $0.priorityShortcutOwnershipChanged() }
    }, failed: { [weak self] message in
        self?.priorityFailure = message
        self?.reloadHotKeys()
    })
    private var recordingObserver: AnyCancellable?
    private var shortcutPermissionObserver: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var workspaceRecoveryObserver: AnyCancellable?
    private let priorityRecoverySleep: @MainActor (Duration) async throws -> Void
    private var priorityRecoveryTask: Task<Void,Never>?
    private var priorityRecoveryGeneration: UInt64 = 0
    static let priorityRecoveryDelays: [Duration] = [.milliseconds(250),.milliseconds(500),.seconds(1),.seconds(2),.seconds(4),.seconds(8),.seconds(16),.seconds(30)]
    var priorityRecoveryIsScheduled:Bool { priorityRecoveryTask != nil }

    init(directory: URL? = nil, captureDirectory: URL? = nil, startupError: String? = nil, uiRegistry: PluginUIRegistry? = nil, permissions: HostPermissionCenter? = nil, sharingDefaults: UserDefaults? = nil,
         shortcutDefaults: UserDefaults? = nil, priorityHotKeyDriver: PriorityHotKeyDriver? = nil,
         ordinaryHotKeyDriver: HotKeyManager.Driver? = nil, sideButtonDriver: PriorityHotKeyDriver? = nil, modifierDriver: PriorityHotKeyDriver? = nil,
         priorityRecoverySleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for:$0) },
         presentations: PluginPresentationIndex = .bundled, initialCatalog: [CatalogEntry] = [],
         dictationFactory: @escaping (URL) -> DoubaoDictationController = { DoubaoDictationController(preferencesURL: $0) },
        captureFactory: @escaping (URL?) -> ScreenshotController = { ScreenshotController(directory: $0) }) {
        self.hotKeys=HotKeyManager(driver:ordinaryHotKeyDriver)
        self.priorityRecoverySleep=priorityRecoverySleep
        self.captureFactory=captureFactory
        self.presentations = presentations
        self.catalog = initialCatalog
        self.dictationFactory = dictationFactory
        self.startupError = startupError
        if let sharingDefaults { self.sharingDefaults = sharingDefaults; isolatedSharingDomain = nil }
        else if directory != nil {
            let domain = "com.untitled.app.sharing.isolated." + UUID().uuidString
            self.sharingDefaults = UserDefaults(suiteName: domain)!; isolatedSharingDomain = domain
        } else { self.sharingDefaults = .standard; isolatedSharingDomain = nil }
        self.shortcutDefaults = shortcutDefaults ?? self.sharingDefaults
        self.priorityDriver = priorityHotKeyDriver ?? (directory == nil ? .native : .unavailable)
        self.sideButtonDriver = sideButtonDriver ?? (directory == nil ? .native(for: .sideButtons) : .unavailable)
        self.modifierDriver = modifierDriver ?? (directory == nil ? .native(for: .modifierOnly) : .unavailable)
        self.priorityHotKeysEnabled = self.shortcutDefaults.bool(forKey: "shortcuts.priorityEnabled")
        self.captureDirectory = captureDirectory
        self.usesLiveCaptureHistory = directory == nil && captureDirectory == nil
        self.uiRegistry = uiRegistry ?? PluginComposition.makeUIRegistry()
        self.permissions = permissions ?? PluginComposition.makePermissionCenter()
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
            refreshCaptureHistoryCleanup()
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

    func setPriorityHotKeysEnabled(_ value: Bool) {
        priorityHotKeysEnabled = value
        shortcutDefaults.set(value, forKey: "shortcuts.priorityEnabled")
        retryHotKeys()
        if value, !permissions.hasShortcutRoutingAccess() { permissions.revealShortcutRoutingPermissions() }
    }
    func setHotKeysPaused(_ value: Bool) {
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
    func retryHotKeys() {
        priorityFailure = nil; sideButtonFailure = nil; modifierFailure = nil
        reloadHotKeys()
    }
    /// Permission snapshots can remain unchanged when Secure Input ends. A
    /// lifecycle event must still recover a failed route, but never churn a
    /// healthy tap or cancel an in-flight priority stroke.
    func recoverPriorityHotKeysIfNeeded() {
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

    func refreshCatalog() async {
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

    func install(_ entry: CatalogEntry) async {
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

    func importPackage(_ url: URL) async {
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

    func installManifest(_ source: PluginManifest, readme: String? = nil) throws {
        guard readme.map({ $0.utf8.count <= PluginArchive.maximumReadmeSize }) ?? true else {
            throw PluginError.invalid("插件说明超过 128 KiB 限制。")
        }
        let manifest = IdentityMigration.manifest(source)
        try manifest.validate()
        try uiRegistry.validate(manifest)
        try permissions.validate(manifest)
        if var record = installed.first(where: { $0.id == manifest.id }) {
            guard Version(manifest.version)! >= Version(record.manifest.version)! else {
                throw PluginError.invalid("不能安装更早版本的插件。")
            }
            uiRegistry.migrateBindings(in: &record, to: manifest, occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            guard record.commands.allSatisfy({ manifest.actions.contains($0.action) }) else {
                throw PluginError.invalid("新版本不再支持部分已有操作，请先移除这些操作。")
            }
            dictationControllers[manifest.id]?.cancel(message: "本次听写因插件更新而中断。")
            let resumeSharing = sharingControllers[manifest.id]?.isRunning == true && sharingDefaults.bool(forKey: "sharing.sessionEnabled")
            sharingControllers[manifest.id]?.stop(reason: "正在更新插件。")
            if manifest.version != record.manifest.version || readme != nil { record.readme = readme }
            record.manifest = manifest
            let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            try save(record)
            reportDefaultConflicts(conflicts)
            if resumeSharing { do { try sharingControllers[manifest.id]?.restoreUserSessionIfRequested() } catch { handleExecutionError(error) } }
        } else {
            var record = InstalledPlugin(manifest: manifest, commands: [])
            record.readme = readme
            let conflicts = record.initializeDefaultCommands(occupiedHotKeys: occupiedHotKeys(excluding: manifest.id))
            try save(record)
            reportDefaultConflicts(conflicts)
        }
        refreshCaptureHistoryCleanup()
    }

    func presentation(for manifest: PluginManifest) -> PluginPresentation {
        let bundled = presentations.appearance(id: manifest.id, repository: manifest.repository, version: manifest.version)
        return PluginPresentation(id: manifest.id, repository: manifest.repository, version: manifest.version,
            name: bundled?.name ?? manifest.name, summary: bundled?.summary ?? manifest.summary,
            icon: bundled?.icon ?? manifest.icon ?? PluginIcon(symbol: uiRegistry.interface(for: manifest).icon ?? "puzzlepiece.extension", tint: "#5875E7"), readmeURL: bundled?.readmeURL,
            storefront: bundled?.storefront ?? manifest.storefront)
    }

    func presentation(for entry: CatalogEntry) -> PluginPresentation {
        let repository = URL(string: "https://github.com/" + entry.downloadURL.pathComponents.dropFirst().prefix(2).joined(separator: "/"))!
        let bundled = presentations.appearance(id: entry.id, repository: repository, version: entry.version)
        return PluginPresentation(id: entry.id, repository: repository, version: entry.version,
            name: bundled?.name ?? entry.name, summary: bundled?.summary ?? entry.summary, icon: bundled?.icon ?? entry.icon,
            readmeURL: bundled?.readmeURL, storefront: bundled?.storefront ?? entry.storefront)
    }

    func documentation(for entry: CatalogEntry) async throws -> String? {
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

    func restoreDefaultCommands(pluginID: String) throws {
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

    func setEnabled(_ enabled: Bool, pluginID: String) {
        guard var record = installed.first(where: { $0.id == pluginID }) else { return }
        record.isEnabled = enabled
        do { try save(record) }
        catch { errorMessage = error.localizedDescription; return }
        if !enabled {
            dictationControllers[pluginID]?.cancel(message: "插件已停用。")
            if pluginID == PeripheralSharingController.pluginID { sharingDefaults.set(false, forKey: "sharing.sessionEnabled") }
            sharingControllers[pluginID]?.stopUserSession()
        }
        if record.manifest.hasCaptureCapability {
            if !enabled { screenshots.deactivate() }
            else { captureController?.pinManager.activate(); captureController?.objectWillChange.send() }
            refreshCaptureHistoryCleanup()
        }
    }

    func saveCommand(_ command: PluginCommand, pluginID: String) throws {
        guard var record = installed.first(where: { $0.id == pluginID }) else { throw PluginError.invalid("插件已卸载。") }
        try command.validate(allowedActions: record.manifest.actions)
        try uiRegistry.validateBinding(command, in: record)
        if command.isEnabled, record.isEnabled, let hotKey = command.hotKey {
            for plugin in installed where plugin.isEnabled {
                for other in plugin.commands where other.isEnabled && other.id != command.id {
                    if other.hotKey?.identity == hotKey.identity {
                        throw PluginError.invalid("\(hotKey.display) 已绑定到「\(other.title)」。")
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

    func removeCommand(_ commandID: UUID, pluginID: String) {
        guard var record = installed.first(where: { $0.id == pluginID }) else { return }
        record.commands.removeAll { $0.id == commandID }
        do { try save(record) } catch { errorMessage = error.localizedDescription }
    }

    func uninstall(_ pluginID: String) {
        guard installed.contains(where: { $0.id == pluginID }) else { return }
        do {
            if installed.first(where: { $0.id == pluginID })?.manifest.hasCaptureCapability == true { screenshots.deactivate() }
            if pluginID == PeripheralSharingController.pluginID { sharingDefaults.set(false, forKey: "sharing.sessionEnabled") }
            sharingPriorityObservers.removeValue(forKey: pluginID)?.cancel()
            sharingControllers.removeValue(forKey: pluginID)?.stopUserSession()
            if let dictation = dictationControllers.removeValue(forKey: pluginID) {
                dictation.cancel(message: "插件已卸载。")
                dictation.history.invalidateForUninstall()
            }
            let preferences = dictationPreferencesURL(pluginID)
            let history = DictationHistory.directory(for: preferences)
            if FileManager.default.fileExists(atPath: history.path) { try FileManager.default.removeItem(at: history) }
            if FileManager.default.fileExists(atPath: preferences.path) { try FileManager.default.removeItem(at: preferences) }
            try FileManager.default.removeItem(at: directory.appendingPathComponent(pluginID + ".json"))
            installed.removeAll { $0.id == pluginID }
            reloadHotKeys()
        } catch { errorMessage = "卸载失败：\(error.localizedDescription)" }
        refreshCaptureHistoryCleanup()
    }

    func execute(_ command: PluginCommand, pluginID: String) async {
        guard !isPreparingForQuit else { return }
        guard let plugin = installed.first(where: { $0.id == pluginID }), plugin.isEnabled, command.isEnabled,
              plugin.commands.contains(command), plugin.manifest.actions.contains(command.action) else { return }
        do {
            try await ActionExecutor.execute(command, showMainWindow: showMainWindow, peripheralAction: { [self] action in
                try performPeripheralAction(action, pluginID: pluginID)
            }, dictationAction: { [self] action in
                try performDictationAction(action, pluginID: pluginID)
            }) { [self] action in
                try await performScreenshot(action, pluginID: pluginID)
            }
        }
        catch { handleExecutionError(error) }
    }

    func performPeripheralAction(_ action: ActionKind, pluginID: String) throws {
        guard let plugin = installed.first(where: { $0.id == pluginID }), plugin.isEnabled,
              plugin.manifest.actions.contains(action), plugin.manifest.actions.contains(.sharePeripherals) else {
            throw PluginError.invalid("请先启用并授权键鼠共享插件。")
        }
        let controller = peripheralSharing(for: pluginID)
        switch action {
        case .sharePeripherals: if controller.isRunning { controller.stopUserSession() } else { try controller.startUserSession() }
        case .switchPeripheralControl: controller.toggleControl()
        case .stopPeripheralSharing: controller.stopUserSession()
        default: throw PluginError.invalid("不支持的键鼠共享操作。")
        }
    }

    func performScreenshot(_ action: ActionKind, pluginID: String) async throws {
        guard action.isScreenshotAction,
              let plugin = installed.first(where: { $0.id == pluginID }), plugin.isEnabled,
              plugin.manifest.actions.contains(action) else { throw PluginError.invalid("请先启用截图插件。") }
        if action == .toggleCaptureHotKeys {
            captureHotKeysPaused.toggle()
            reloadHotKeys()
            return
        }
        // Repeated capture keys are a no-op, before any permission work or UI.
        guard captureController?.shouldIgnoreCaptureRequest(action) != true else { return }
        let client = permissionClient(for: pluginID)
        if !(action == .captureRecording && screenshots.isRecording) {
            try client.require(CapturePermissionRequirements.permissions(for: action))
        }
        screenshots.showHistory = { [weak self] in
            self?.requestedPluginID = pluginID
            self?.showMainWindow()
        }
        let liveActions = Set(CaptureSelectionLiveAction.allCases.filter { plugin.manifest.actions.contains($0.action) })
        try await screenshots.perform(action, permissions: client, liveActions: liveActions) { [weak self] action in
            guard let self, !self.isPreparingForQuit else { return false }
            return self.installed.contains { $0.id == pluginID && $0.isEnabled && $0.manifest.actions.contains(action) }
        }
    }

    func permissionClient(for pluginID: String) -> PluginPermissionClient {
        PluginPermissionClient(isAuthorized: { [weak self] id in
            guard let self, let plugin = self.installed.first(where: { $0.id == pluginID }) else { return false }
            return self.permissions.isAuthorized(id, for: plugin)
        }) { [weak self] ids in
            guard let self, let plugin = self.installed.first(where: { $0.id == pluginID }) else {
                throw PluginError.invalid("插件已卸载。")
            }
            try self.permissions.require(ids, for: plugin)
        }
    }

    func handleExecutionError(_ error: Error) {
        if error is HostPermissionError { return } // The host has already opened permission management.
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
            for controller in dictationControllers.values { controller.refreshEscapeShortcut() }
            reconcileShortcutRegistrationNotice()
            if !automaticRecovery { schedulePriorityRecovery() }
        }
        if !automaticRecovery { cancelPriorityRecovery() }
        priorityHotKeyRecoveryNeeded=false; sideButtonRecoveryNeeded=false; modifierRecoveryNeeded=false
        if let plugin = installed.first(where: { $0.isEnabled && $0.manifest.hasCaptureCapability }) {
            if let controller = captureController {
                controller.configureGlobalMouse(permissions: permissionClient(for: plugin.id), allowed: { [weak self] in self?.captureHotKeysPaused == false && !HotKeyRecordingSession.isRecording })
            } else if UserDefaults.standard.bool(forKey: "capture.mouse.enabled") { _ = screenshots }
        } else { captureController?.globalMouse.stop() }
        hotKeys.clear(); priorityHotKeys.clear(); sideButtons.clear(); modifierKeys.clear()
        hotKeyErrors = [:]
        priorityHotKeyStatus = hotKeysPaused ? "所有快捷键已暂停" : (HotKeyRecordingSession.isRecording ? "正在录制快捷键，已暂停全局触发" : nil)
        guard !hotKeysPaused, !isPreparingForQuit, !HotKeyRecordingSession.isRecording else { return }
        var identities = Set<String>()
        var bindings: [(pluginID: String, command: PluginCommand, key: HotKey)] = []
        for plugin in installed where plugin.isEnabled {
            for command in plugin.commands where command.isEnabled {
                if captureHotKeysPaused, plugin.manifest.hasCaptureCapability, command.action != .toggleCaptureHotKeys { continue }
                guard let key = command.hotKey else { continue }
                do {
                    try command.validate(allowedActions: plugin.manifest.actions)
                    try uiRegistry.validateBinding(command, in: plugin)
                    guard identities.insert(key.identity).inserted else {
                        throw PluginError.invalid("这个快捷键已绑定到其他操作。")
                    }
                    bindings.append((plugin.id, command, key))
                } catch { hotKeyErrors[command.id] = error.localizedDescription }
            }
        }
        // Carbon handles keyboard bindings without a tap. Only configured side buttons
        // use the mouse-only channel, independent of keyboard priority mode.
        let solo = bindings.filter { $0.key.isStandaloneModifier }
        bindings.removeAll { $0.key.isStandaloneModifier }
        if solo.isEmpty { modifierFailure = nil }
        for (pluginID, command, key) in solo {
            do {
                if let modifierFailure { throw PluginError.invalid(modifierFailure) }
                let release = hotKeyRelease(command, pluginID: pluginID)
                try modifierKeys.register(key, allowed: { [weak self] in self?.allowsPriorityHotKey(command, pluginID: pluginID) == true },
                    onRelease: release, onCancel: { [weak self] in self?.dictationControllers[pluginID]?.holdCancelled(command.id) }) { [weak self] in
                    self?.hotKeyPressed(command, pluginID: pluginID)
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
                try hotKeys.register(binding.key, onRelease: hotKeyRelease(binding.command, pluginID: binding.pluginID)) { [weak self] in
                    self?.hotKeyPressed(binding.command, pluginID: binding.pluginID)
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

    var priorityShortcutsYieldToSharing: Bool {
        sharingControllers.values.contains { !$0.allowsLocalPriorityShortcuts }
    }
    private func registerEventShortcut(_ key: HotKey, via monitor: PriorityHotKeyMonitor, command: PluginCommand, pluginID: String) throws {
        let allowed = { [weak self] in self?.allowsPriorityHotKey(command, pluginID: pluginID) == true }
        if command.action == .switchPeripheralControl {
            // A local-to-remote request waits for this shortcut's physical release.
            // Cancellation must never turn into a new handoff or reverse a queued intent.
            var armed = false
            try monitor.register(key, allowed: allowed, onRelease: { [weak self] in
                guard armed else { return }
                armed = false
                guard let self, self.allowsPriorityHotKey(command, pluginID: pluginID) else { return }
                do { try self.performPeripheralAction(.switchPeripheralControl, pluginID: pluginID) }
                catch { self.handleExecutionError(error) }
            }, onCancel: { armed = false }, action: { armed = true })
        } else {
            try monitor.register(key, allowed: allowed, onRelease: hotKeyRelease(command, pluginID: pluginID)) { [weak self] in
                self?.hotKeyPressed(command, pluginID: pluginID)
            }
        }
    }
    private func hotKeyRelease(_ command: PluginCommand, pluginID: String) -> (() -> Void)? {
        guard command.action == .holdDoubaoDictation else { return nil }
        return { [weak self] in self?.dictationControllers[pluginID]?.holdReleased(command.id) }
    }
    private func hotKeyPressed(_ command: PluginCommand, pluginID: String) {
        guard !isPreparingForQuit, !hotKeysPaused,
              installed.contains(where: { $0.id == pluginID && $0.isEnabled && $0.commands.contains(command) && command.isEnabled }) else { return }
        if command.action == .holdDoubaoDictation {
            do { try performDictationAction(command.action, pluginID: pluginID, holdCommandID: command.id) }
            catch { handleExecutionError(error) }
        } else { Task { [weak self] in await self?.execute(command, pluginID: pluginID) } }
    }
    private func allowsPriorityHotKey(_ command: PluginCommand, pluginID: String) -> Bool {
        guard (priorityHotKeysEnabled || command.hotKey?.mouseButton != nil || command.hotKey?.isStandaloneModifier == true), !isPreparingForQuit, !hotKeysPaused, !HotKeyRecordingSession.isRecording,
              installed.contains(where: { $0.id == pluginID && $0.isEnabled && $0.commands.contains(command) && command.isEnabled }) else { return false }
        if sharingControllers.values.contains(where: { $0.reservesPriorityShortcut(command.hotKey) }) { return false }
        if command.action == .stopPeripheralSharing { return true }
        return sharingControllers.values.allSatisfy(\.allowsLocalPriorityShortcuts)
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
