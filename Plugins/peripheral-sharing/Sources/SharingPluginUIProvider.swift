import Combine
import UntitledHost
import SwiftUI

struct SharingPluginUIProvider: PluginUIProvider {
    let runtime: SharingPluginRuntime
    @MainActor func register(in registry: PluginUIRegistry) {
        registry.component("sharing.dashboard", requiredActions: [.sharePeripherals]) { context in
            AnyView(SharingPluginView(controller: runtime.controller(for: context.pluginID, in: context.store)))
        }
        registry.component("sharing.status", requiredActions: [.sharePeripherals]) { context in
            AnyView(SharingStatusView(controller: runtime.controller(for: context.pluginID, in: context.store)))
        }
        registry.command("sharing.toggle", requiredActions: [.sharePeripherals], presentation: { context in
            .init(title: runtime.controller(for: context.pluginID, in: context.store).isRunning ? "停止共享" : "启动共享", symbol: "network")
        }, updates: { runtime.controller(for: $0.pluginID, in: $0.store).objectWillChange.eraseToAnyPublisher() }) { context in
            try runtime.perform(.sharePeripherals, for: context.pluginID, in: context.store)
        }
        registry.command("sharing.switch", requiredActions: [.sharePeripherals, .switchPeripheralControl], presentation: { context in
            let controller = runtime.controller(for: context.pluginID, in: context.store)
            return .init(title: controller.control == .local ? "控制另一台 Mac" : "返回本机", symbol: "keyboard",
                         isEnabled: controller.keyboardMouseEnabled && controller.peerName != nil)
        }, updates: { runtime.controller(for: $0.pluginID, in: $0.store).objectWillChange.eraseToAnyPublisher() }) { context in
            try runtime.perform(.switchPeripheralControl, for: context.pluginID, in: context.store)
        }
        registry.command("sharing.stop", requiredActions: [.sharePeripherals, .stopPeripheralSharing], presentation: { context in
            .init(title: "停止全部共享", symbol: "stop.circle", isEnabled: runtime.controller(for: context.pluginID, in: context.store).isRunning)
        }, updates: { runtime.controller(for: $0.pluginID, in: $0.store).objectWillChange.eraseToAnyPublisher() }) { context in
            try runtime.perform(.stopPeripheralSharing, for: context.pluginID, in: context.store)
        }
    }
}

private struct SharingStatusView: View {
    @ObservedObject var controller: PeripheralSharingController
    var body: some View {
        Label(controller.isRunning ? "\(controller.peerName ?? "等待连接") · \(controller.control.rawValue)" : "共享已关闭",
              systemImage: controller.isRunning ? "circle.fill" : "circle")
            .font(.caption).foregroundStyle(.secondary)
    }
}
