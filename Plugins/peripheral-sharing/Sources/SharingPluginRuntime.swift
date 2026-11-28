import Combine
import UntitledPluginSDK
import UntitledHost
import CoreGraphics
import Foundation

extension ActionKind {
    static let sharePeripherals = Self(rawValue: "sharePeripherals")
    static let switchPeripheralControl = Self(rawValue: "switchPeripheralControl")
    static let stopPeripheralSharing = Self(rawValue: "stopPeripheralSharing")
}

/// Owns the sharing session and the policy for yielding host shortcuts while
/// input is being handed off. The host supplies generic key ownership events.
@MainActor package final class SharingPluginRuntime: NativePluginRuntime {
    private nonisolated static let labels: [ActionKind: PluginActionPresentation] = [
        .sharePeripherals: .init(title: "启动或停止键鼠共享", symbol: "network"),
        .switchPeripheralControl: .init(title: "切换键鼠控制目标", symbol: "keyboard"),
        .stopPeripheralSharing: .init(title: "停止全部键鼠共享", symbol: "stop.circle")
    ]
    nonisolated static let presentation = labels.mapValues { label in
        var value = label
        value.detail = "已配对 Mac 的键鼠共享操作"
        value.bindingHelp = "使用键鼠共享插件中已配对的设备。切换控制需要两端明确开启键鼠共享；停止操作始终释放键鼠和麦克风。"
        return value
    }
    package let actions = Set(SharingPluginRuntime.presentation.keys)
    package var actionPresentation: [ActionKind: PluginActionPresentation] { Self.presentation }
    package func registerUI(in registry: PluginUIRegistry) { registry.register(SharingPluginUIProvider(runtime: self)) }

    private let forwardCopiedImage: (PeripheralSharingController, Data, Int) -> Void
    private let builtInDefaults: UserDefaults
    private let isolationPrefix: String?
    private var ownedDomains = Set<String>()
    private var controllers: [String: PeripheralSharingController] = [:]
    private var policyObservers: [String: AnyCancellable] = [:]
    private var setup: SharingSetupSession?
    #if DEBUG
    private var acceptance: SharingAcceptance?
    #endif

    package convenience init(defaults: UserDefaults?, isolated: Bool) {
        self.init(defaults: defaults, isolated: isolated, forwardCopiedImage: {
            $0.shareCopiedScreenshot($1, changeCount: $2)
        })
    }
    package static func isolatedDirectoryForLaunch() -> URL? {
        #if DEBUG
        SharingAcceptance.pluginDirectoryForLaunch()
        #else
        nil
        #endif
    }

    init(defaults: UserDefaults?, isolated: Bool, forwardCopiedImage: @escaping (PeripheralSharingController, Data, Int) -> Void) {
        self.forwardCopiedImage = forwardCopiedImage
        let prefix = isolated ? HostInfo.bundleIdentifier + ".sharing.isolated." + UUID().uuidString : nil
        isolationPrefix = prefix
        if let defaults { builtInDefaults = defaults }
        else if let prefix {
            builtInDefaults = UserDefaults(suiteName: prefix)!
            ownedDomains.insert(prefix)
        } else { builtInDefaults = .standard }
    }
    deinit {
        for domain in ownedDomains { UserDefaults.standard.removePersistentDomain(forName: domain) }
    }

    func defaults(for pluginID: String) -> UserDefaults {
        // Only the historical built-in identity uses its existing preference domain.
        guard pluginID != PeripheralSharingController.pluginID else { return builtInDefaults }
        let domain = (isolationPrefix ?? HostInfo.bundleIdentifier + ".sharing") + ".plugin." + pluginID
        if isolationPrefix != nil { ownedDomains.insert(domain) }
        return UserDefaults(suiteName: domain)!
    }

    func controller(for pluginID: String, in host: PluginStore) -> PeripheralSharingController {
        if let controller = controllers[pluginID] { return controller }
        let controller = PeripheralSharingController(defaults: defaults(for: pluginID), pairingPluginID: pluginID)
        controller.isAllowed = { [weak self, weak host, weak controller] in
            guard let self, let controller, self.controllers[pluginID] === controller,
                  host?.enabledPlugin(pluginID, allowing: .sharePeripherals) != nil else { return false }
            // Cursor/keyboard/audio routing is exclusive, even if multiple
            // separately paired builds of the module are installed.
            return !self.controllers.contains { $0.key != pluginID && $0.value.isRunning }
        }
        controller.requirePermissions = { [weak host] ids in
            guard let host else { throw PluginError.invalid("宿主已关闭。") }
            try host.permissionClient(for: pluginID).require(ids)
        }
        controller.reportError = { [weak host] in host?.handleExecutionError($0) }
        controller.configurePriorityShortcutRouting(route: { [weak host] type, event in
            host?.routeShortcutInput(type, event) ?? false
        }, ownsKey: { [weak host] in host?.ownsShortcutInput($0, mouse: false) ?? false },
           ownsButton: { [weak host] in host?.ownsShortcutInput($0, mouse: true) ?? false },
           hasKeys: { [weak host] in host?.hasOutstandingShortcutInput ?? false })
        policyObservers[pluginID] = Publishers.CombineLatest(
            controller.$control.removeDuplicates(), controller.$keyboardMouseEnabled.removeDuplicates()
        ).dropFirst().sink { [weak host] _ in
            // Published emits before assignment; consult the settled routing policy.
            Task { @MainActor [weak host] in host?.publishRuntimeEvent(.shortcutPolicyChanged) }
        }
        controllers[pluginID] = controller
        return controller
    }

    package func receive(_ event: PluginRuntimeEvent, in host: PluginStore) {
        switch event {
        case .shortcutOwned(let code, let mouse):
            controllers.values.forEach { $0.notePriorityShortcutOwnership(code, mouse: mouse) }
        case .shortcutOwnershipChanged:
            controllers.values.forEach { $0.priorityShortcutOwnershipChanged() }
        case .copiedImage(let data, let count):
            // A copy never creates a sharing controller or network session.
            for (pluginID, controller) in controllers where
                controller.isRunning && host.enabledPlugin(pluginID, allowing: .sharePeripherals) != nil {
                forwardCopiedImage(controller, data, count)
            }
        case .didLaunch(let arguments):
            do {
                #if DEBUG
                if let directory = Self.argument("--sharing-acceptance", in: arguments), acceptance == nil {
                    acceptance = try SharingAcceptance(store: host, runtime: self, directory: directory)
                    return
                }
                #endif
                if let profile = Self.argument("--sharing-setup", in: arguments) {
                    guard setup == nil else { return }
                    let session = try SharingSetupSession(store: host, runtime: self, profileURL: profile)
                    setup = session
                    try session.confirmAndStart(profileURL: profile)
                } else if !arguments.contains("--sharing-acceptance") {
                    for plugin in host.installed where host.enabledPlugin(plugin.id, allowing: .sharePeripherals) != nil {
                        guard defaults(for: plugin.id).bool(forKey: "sharing.sessionEnabled") else { continue }
                        let session = controller(for: plugin.id, in: host)
                        try session.restoreUserSessionIfRequested()
                        if session.isRunning { break }
                    }
                }
            } catch { host.handleExecutionError(error) }
        default: break
        }
    }

    func setupPluginID(in host: PluginStore) throws -> String {
        let available = host.installed.filter { $0.manifest.actions.contains(.sharePeripherals) }
        if let builtIn = available.first(where: { $0.id == PeripheralSharingController.pluginID }) { return builtIn.id }
        guard available.count == 1, let id = available.first?.id else {
            throw PluginError.invalid("请在要使用的键鼠共享插件中手动配置配对。")
        }
        return id
    }

    private static func argument(_ flag: String, in args: [String]) -> URL? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: flag == "--sharing-acceptance")
    }

    package func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore) {
        guard plugin.isEnabled, plugin.manifest.actions.contains(.sharePeripherals) else {
            deactivate(plugin.id, removeController: !plugin.manifest.actions.contains(.sharePeripherals))
            return
        }
        guard let controller = controllers[plugin.id] else { return }
        let resume = controller.isRunning && defaults(for: plugin.id).bool(forKey: "sharing.sessionEnabled")
        controller.stop(reason: "正在更新插件。")
        if resume {
            do { try controller.restoreUserSessionIfRequested() } catch { host.handleExecutionError(error) }
        }
    }
    package func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore) {
        if !plugin.isEnabled { deactivate(plugin.id, removeController: false) }
    }
    package func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws {
        deactivate(plugin.id, removeController: true)
    }
    private func deactivate(_ pluginID: String, removeController: Bool) {
        defaults(for: pluginID).set(false, forKey: "sharing.sessionEnabled")
        if setup?.pluginID == pluginID { setup?.stopReporting(); setup = nil }
        #if DEBUG
        if acceptance?.pluginID == pluginID { acceptance?.stop(); acceptance = nil }
        #endif
        controllers[pluginID]?.stopUserSession()
        if removeController {
            policyObservers.removeValue(forKey: pluginID)?.cancel()
            controllers.removeValue(forKey: pluginID)
        }
    }
    package func prepareForQuit() async -> Bool {
        #if DEBUG
        acceptance?.stop(); acceptance = nil
        #endif
        setup?.stopReporting(); setup = nil
        controllers.values.forEach { $0.stop() }
        return true
    }

    package func ignoresShortcutEvent(_ event: CGEvent) -> Bool { SharingInput.isHostShortcutReplay(event) }
    package func reservesShortcut(_ key: HotKey) -> Bool { controllers.values.contains { $0.reservesPriorityShortcut(key) } }
    package func permitsShortcut(_ command: PluginCommand) -> Bool {
        guard !controllers.values.contains(where: { $0.reservesPriorityShortcut(command.hotKey) }) else { return false }
        return command.action == .stopPeripheralSharing || controllers.values.allSatisfy(\.allowsLocalPriorityShortcuts)
    }
    package func shortcutGesture(for command: PluginCommand, pluginID: String, channel: PluginShortcutChannel,
                         in host: PluginStore) -> PluginShortcutGesture? {
        guard channel == .eventTap, command.action == .switchPeripheralControl else { return nil }
        var armed = false
        return PluginShortcutGesture(press: { armed = true }, release: { [weak self, weak host] in
            guard armed else { return }
            armed = false
            guard let self, let host, host.allowsEventShortcut(command, pluginID: pluginID) else { return }
            do { try self.perform(command.action, for: pluginID, in: host) }
            catch { host.handleExecutionError(error) }
        }, cancel: { armed = false })
    }

    package func perform(_ command: PluginCommand, for pluginID: String, in host: PluginStore) async throws {
        try perform(command.action, for: pluginID, in: host)
    }
    package func perform(_ action: ActionKind, for pluginID: String, in host: PluginStore) throws {
        guard let plugin = host.enabledPlugin(pluginID, allowing: action), plugin.manifest.actions.contains(.sharePeripherals) else {
            throw PluginError.invalid("请先启用并授权键鼠共享插件。")
        }
        let controller = controller(for: pluginID, in: host)
        switch action {
        case .sharePeripherals: if controller.isRunning { controller.stopUserSession() } else { try controller.startUserSession() }
        case .switchPeripheralControl: controller.toggleControl()
        case .stopPeripheralSharing: controller.stopUserSession()
        default: throw PluginError.invalid("不支持的键鼠共享操作。")
        }
    }
}
