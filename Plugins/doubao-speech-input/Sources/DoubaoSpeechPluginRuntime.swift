import Carbon
import UntitledPluginSDK
import UntitledHost
import Foundation

extension ActionKind {
    static let toggleDoubaoDictation = Self(rawValue: "toggleDoubaoDictation")
    static let holdDoubaoDictation = Self(rawValue: "holdDoubaoDictation")
    static let cancelDoubaoDictation = Self(rawValue: "cancelDoubaoDictation")
}

/// Owns each listening session, its temporary cancel gestures, history and
/// cleanup. The host knows only a scoped shortcut tied to a declared action.
@MainActor package final class DoubaoSpeechPluginRuntime: NativePluginRuntime {
    nonisolated static let presentation: [ActionKind: PluginActionPresentation] = [
        .toggleDoubaoDictation: .init(title: "开始或结束豆包听写", symbol: "mic", detail: "语音输入", minimumHostVersion: "0.9.8"),
        .holdDoubaoDictation: .init(title: "按住说话（豆包）", symbol: "mic.fill", detail: "按住说话，松开结束",
                                    bindingHelp: "按住开始听写，松开结束。", minimumHostVersion: "0.9.8"),
        .cancelDoubaoDictation: .init(title: "取消豆包听写", symbol: "xmark.circle", detail: "语音输入", minimumHostVersion: "0.9.8")
    ]
    package let actions = Set(DoubaoSpeechPluginRuntime.presentation.keys)
    package var actionPresentation: [ActionKind: PluginActionPresentation] { Self.presentation }
    package var capabilityGroup: PluginCapabilityGroup? {
        .init(title: "麦克风与听写", symbol: "mic", summary: "语音输入插件可用麦克风听写并处理定稿。",
              actions: [.toggleDoubaoDictation, .holdDoubaoDictation, .cancelDoubaoDictation])
    }
    package func registerUI(in registry: PluginUIRegistry) { registry.register(DoubaoSpeechPluginUIProvider(runtime: self)) }
    package let styleNames: Set<String> = [DictationHUDStyle.name]

    package func validateStyles(in manifest: PluginManifest) throws {
        if manifest.styles?[DictationHUDStyle.name] != nil {
            guard manifest.actions.contains(.toggleDoubaoDictation) else {
                throw PluginError.invalid("声明浮条样式需要听写操作。")
            }
            _ = try DictationHUDStyle(in: manifest)
        }
    }
    private var controllers: [String: DoubaoDictationController] = [:]
    private let factory: (URL) -> DoubaoDictationController

    package init(factory: ((URL) -> DoubaoDictationController)? = nil) {
        self.factory = factory ?? { DoubaoDictationController(preferencesURL: $0) }
    }

    private func preferences(for pluginID: String, in host: PluginStore) -> URL {
        host.pluginPreferencesDirectory.appendingPathComponent(pluginID + ".dictation.json")
    }
    func controller(for pluginID: String, in host: PluginStore) -> DoubaoDictationController {
        if let controller = controllers[pluginID] { return controller }
        let controller = factory(preferences(for: pluginID, in: host))
        controller.isAllowed = { [weak host] in host?.enabledPlugin(pluginID, allowing: .toggleDoubaoDictation) != nil }
        controller.hudStyle = { [weak host] in
            guard let manifest = host?.enabledPlugin(pluginID, allowing: .toggleDoubaoDictation)?.manifest else { return .defaults }
            // The host validates styles before saving or loading an installed record.
            return (try? DictationHUDStyle(in: manifest)) ?? .defaults
        }
        controller.requirePermissions = { [weak host] ids in
            guard let host else { throw PluginError.invalid("宿主已关闭。") }
            try host.permissionClient(for: pluginID).require(ids)
        }
        controller.hasInsertionAccess = { [weak host] in host?.permissionClient(for: pluginID).isAuthorized(.accessibility) == true }
        controller.registerEscape = { [weak self, weak host] gesture, cancel in
            guard let self, let host else { return nil }
            return self.registerEscape(for: pluginID, gesture: gesture, in: host, cancel: cancel)
        }
        controllers[pluginID] = controller
        return controller
    }

    private func registerEscape(for pluginID: String, gesture: DictationGesture, in host: PluginStore,
                                cancel: @escaping () -> Void) -> (() -> Void)? {
        let escape = HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, key: "⎋")
        guard !host.runtime.reservesShortcut(escape),
              let plugin = host.enabledPlugin(pluginID, allowing: .cancelDoubaoDictation) else { return nil }
        var modifiers: [UInt32] = [0]
        if case .hold(let commandID) = gesture,
           let key = plugin.commands.first(where: { $0.id == commandID && $0.isEnabled })?.hotKey {
            let mask = key.isRightCommand ? UInt32(cmdKey) : key.isRightControl ? UInt32(controlKey) : key.modifiers
            // Never try to reserve the system's Force Quit shortcut.
            if mask != 0, mask != UInt32(cmdKey | optionKey) { modifiers.append(mask) }
        }
        let stops = modifiers.compactMap { modifier in
            host.registerTemporaryShortcut(HotKey(keyCode: UInt32(kVK_Escape), modifiers: modifier, key: "⎋"),
                                           pluginID: pluginID, action: .cancelDoubaoDictation, onPress: cancel)
        }
        guard !stops.isEmpty else { return nil }
        return { stops.forEach { $0() } }
    }

    package func receive(_ event: PluginRuntimeEvent, in host: PluginStore) {
        switch event {
        case .didReloadShortcuts, .shortcutPolicyChanged:
            controllers.values.forEach { $0.refreshEscapeShortcut() }
        default: break
        }
    }
    package func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore) {
        controllers[plugin.id]?.cancel(message: "本次听写因插件更新而中断。")
    }
    package func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore) {
        if !plugin.isEnabled { controllers[plugin.id]?.cancel(message: "插件已停用。") }
    }
    package func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws {
        if let controller = controllers.removeValue(forKey: plugin.id) {
            controller.cancel(message: "插件已卸载。")
            controller.history.invalidateForUninstall()
        }
        let preferences = preferences(for: plugin.id, in: host), history = DictationHistory.directory(for: preferences)
        for url in [history, preferences] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    package func prepareForQuit() async -> Bool {
        controllers.values.forEach { $0.cancel(message: "应用正在退出，听写已停止。") }
        for history in controllers.values.map(\.history) { await history.finishPendingIO() }
        return true
    }
    package func shortcutGesture(for command: PluginCommand, pluginID: String, channel: PluginShortcutChannel,
                         in host: PluginStore) -> PluginShortcutGesture? {
        guard command.action == .holdDoubaoDictation else { return nil }
        return .init(press: { [weak self, weak host] in
            guard let self, let host else { return }
            try self.perform(command.action, for: pluginID, holdCommandID: command.id, in: host)
        }, release: { [weak self] in self?.controllers[pluginID]?.holdReleased(command.id) },
           cancel: channel == .modifier ? { [weak self] in self?.controllers[pluginID]?.holdCancelled(command.id) } : nil)
    }

    package func perform(_ command: PluginCommand, for pluginID: String, in host: PluginStore) async throws {
        try perform(command.action, for: pluginID, in: host)
    }
    package func perform(_ action: ActionKind, for pluginID: String, holdCommandID: UUID? = nil, in host: PluginStore) throws {
        guard let plugin = host.enabledPlugin(pluginID, allowing: action), plugin.manifest.actions.contains(.toggleDoubaoDictation) else {
            throw PluginError.invalid("请先启用并授权语音输入插件。")
        }
        let controller = controller(for: pluginID, in: host)
        switch action {
        case .toggleDoubaoDictation: try controller.toggle()
        case .holdDoubaoDictation:
            if let holdCommandID { try controller.holdPressed(holdCommandID) }
            else { try controller.toggle() } // An explicit Run click is not a full hotkey gesture.
        case .cancelDoubaoDictation: controller.cancel()
        default: throw PluginError.invalid("不支持的语音输入操作。")
        }
    }
}
