import AppKit
import SwiftUI
import UntitledPluginSDK

struct PluginAccessView: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.dismiss) private var dismiss
    let pluginID: String

    var body: some View {
        if let plugin = store.installed.first(where: { $0.id == pluginID }) {
            let declarations = store.permissions.declarations(for: plugin.manifest)
            let permissionIDs = Set(declarations.map(\.id))
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("权限与能力").font(.title2.weight(.semibold))
                        Text(store.presentation(for: plugin.manifest).name)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(PanelLayout.contentInset)
                Divider()
                Form {
                    Section("系统权限") {
                        if declarations.isEmpty {
                            Text("此插件无需系统权限").foregroundStyle(.secondary)
                        }
                        ForEach(declarations, id: \.id) { declaration in
                            if let descriptor = store.permissions.drivers.first(where: { $0.descriptor.id == declaration.id })?.descriptor {
                                PermissionRow(permissions: store.permissions, descriptor: descriptor,
                                              declaration: declaration, pluginID: plugin.id)
                            }
                        }
                    }
                    Section("原生能力") {
                        ForEach(plugin.manifest.actions, id: \.self) { action in
                            if action.isNativeUtility {
                                Toggle(isOn: Binding(
                                    get: { plugin.allowsAction(action) },
                                    set: { store.setNativeActionAllowed($0, action: action, pluginID: plugin.id) }
                                )) {
                                    Label(action.title, systemImage: action.symbol)
                                }
                                .accessibilityIdentifier("plugin.capability.\(action.rawValue)")
                            } else {
                                Label(action.title, systemImage: action.symbol)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(width: 600, height: 510)
            .accessibilityIdentifier("plugin.access")
            .task(id: permissionIDs) { await store.permissions.refreshForDisplay(permissionIDs) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await store.permissions.refreshForDisplay(permissionIDs) }
            }
            .onDisappear {
                if store.permissions.pendingRequest?.pluginID == pluginID { store.permissions.pendingRequest = nil }
            }
        }
    }
}
