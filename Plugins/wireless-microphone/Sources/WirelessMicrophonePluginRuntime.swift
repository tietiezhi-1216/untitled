import Foundation
import UntitledHost
import UntitledPluginSDK

extension ActionKind {
    static let shareWirelessMicrophone = Self(rawValue: "shareWirelessMicrophone")
}

@MainActor package final class WirelessMicrophonePluginRuntime: NativePluginRuntime {
    package let actions: Set<ActionKind> = [.shareWirelessMicrophone]
    package var actionPresentation: [ActionKind: PluginActionPresentation] {
        [.shareWirelessMicrophone: .init(title: "启动或停止无线麦", symbol: "mic",
          detail: "启动或停止无线麦连接", bindingHelp: "发送和接收需要在无线麦面板开启。", minimumHostVersion: "0.13.51")]
    }

    private let defaults: UserDefaults
    private let ownedDomain: String?
    private let factory: (String, UserDefaults) -> WirelessMicrophoneController
    private var controllers: [String: WirelessMicrophoneController] = [:]

    package init(defaults: UserDefaults?, isolated: Bool, factory: ((String, UserDefaults) -> WirelessMicrophoneController)? = nil) {
        if let defaults {
            self.defaults = defaults
            ownedDomain = nil
        } else if isolated {
            let domain = HostInfo.bundleIdentifier + ".wireless-microphone.isolated." + UUID().uuidString
            self.defaults = UserDefaults(suiteName: domain)!
            ownedDomain = domain
        } else {
            self.defaults = .standard
            ownedDomain = nil
        }
        self.factory = factory ?? { WirelessMicrophoneController(pluginID: $0, defaults: $1) }
    }

    deinit {
        if let ownedDomain { UserDefaults.standard.removePersistentDomain(forName: ownedDomain) }
    }

    package func registerUI(in registry: PluginUIRegistry) {
        registry.register(WirelessMicrophonePluginUIProvider(runtime: self))
    }

    func controller(for pluginID: String, in host: PluginStore) -> WirelessMicrophoneController {
        if let controller = controllers[pluginID] { return controller }
        let controller = factory(pluginID, defaults)
        controller.isAllowed = { [weak host] in host?.enabledPlugin(pluginID, allowing: .shareWirelessMicrophone) != nil }
        controller.requireMicrophone = { [weak host] in
            guard let host else { throw PluginError.invalid("宿主已关闭。") }
            try host.permissionClient(for: pluginID).require([.microphone])
        }
        controllers[pluginID] = controller
        return controller
    }

    func toggle(pluginID: String, in host: PluginStore) throws {
        guard host.enabledPlugin(pluginID, allowing: .shareWirelessMicrophone) != nil else {
            throw PluginError.invalid("请先安装并启用无线麦。")
        }
        let controller = controller(for: pluginID, in: host)
        if controller.isRunning { controller.stop() }
        else { try controller.start() }
    }

    package func perform(_ command: PluginCommand, for pluginID: String, in host: PluginStore) async throws {
        try toggle(pluginID: pluginID, in: host)
    }

    package func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore) {
        if plugin.manifest.actions.contains(.shareWirelessMicrophone) { controllers[plugin.id]?.stop() }
        else { controllers.removeValue(forKey: plugin.id)?.stop() }
    }

    package func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore) {
        if !plugin.isEnabled { controllers[plugin.id]?.stop() }
    }

    package func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws {
        controllers.removeValue(forKey: plugin.id)?.stop()
    }

    package func prepareForQuit() async -> Bool {
        for controller in controllers.values { controller.stop() }
        return true
    }
}
