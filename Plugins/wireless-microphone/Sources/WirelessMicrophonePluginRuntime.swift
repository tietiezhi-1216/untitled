import Foundation
import UntitledHost
import UntitledPluginSDK

extension ActionKind {
    static let shareWirelessMicrophone = Self(rawValue: "shareWirelessMicrophone")
}

@MainActor package final class WirelessMicrophonePluginRuntime: NativePluginRuntime {
    package let actions: Set<ActionKind> = [.shareWirelessMicrophone]
    package var actionPresentation: [ActionKind: PluginActionPresentation] {
        [.shareWirelessMicrophone: .init(title: "查找或断开小米遥控器", symbol: "mic",
          detail: "查找或断开小米遥控器", bindingHelp: "在无线麦中查找小米蓝牙遥控器，或断开现有连接。",
          minimumHostVersion: "0.13.51")]
    }

    private let factory: () -> WirelessMicrophoneController
    private var controllers: [String: WirelessMicrophoneController] = [:]

    package init(factory: (() -> WirelessMicrophoneController)? = nil) {
        self.factory = factory ?? { WirelessMicrophoneController() }
    }

    package func registerUI(in registry: PluginUIRegistry) {
        registry.register(WirelessMicrophonePluginUIProvider(runtime: self))
    }

    func controller(for pluginID: String, in host: PluginStore) -> WirelessMicrophoneController {
        if let controller = controllers[pluginID] { return controller }
        let controller = factory()
        controller.isAllowed = { [weak host] in host?.enabledPlugin(pluginID, allowing: .shareWirelessMicrophone) != nil }
        controller.requireBluetooth = { [weak host] in
            guard let host else { throw PluginError.invalid("宿主已关闭。") }
            try host.permissionClient(for: pluginID).require([.bluetooth])
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
        else { try controller.discover() }
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
