import AppKit
import UntitledPluginSDK
import UntitledHost
import SwiftUI

/// The Xcode application and SwiftPM executable call this same entry.
public enum UntitledLauncher {
    @MainActor public static func launch() { UntitledApp.main() }
}

struct UntitledApp: App {
    @NSApplicationDelegateAdaptor(UntitledAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @StateObject private var store: PluginStore

    init() {
        let isolatedDirectory = PluginComposition.isolatedDirectoryForLaunch()
        let startupError: String?
        do {
            if isolatedDirectory == nil { try IdentityMigration.prepare() }
            startupError = nil
        } catch { startupError = "数据迁移未完成，原文件已保留：\(error.localizedDescription)" }
        _store = StateObject(wrappedValue: PluginStore(directory: isolatedDirectory, startupError: startupError))
    }

    var body: some Scene {
        Window(HostInfo.name, id: "main") {
            ContentView()
                .environmentObject(store)
                .onAppear { [store, appDelegate] in
                    appDelegate.prepareForQuit = { [weak store] in await store?.prepareForQuit() ?? true }
                    appDelegate.showMainWindow = { [weak store] in store?.showMainWindow() }
                    guard !appDelegate.handledLaunchArguments else { return }
                    appDelegate.handledLaunchArguments = true
                    let arguments = ProcessInfo.processInfo.arguments
                    Task { await store.launch(arguments: arguments) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 720)
        .onChange(of: appearance, initial: true) { _, appearance in
            // 在应用层统一更新窗口与 SwiftUI 内容；nil 会恢复系统外观继承。
            NSApplication.shared.appearance = appearance.appKitAppearance
        }

        Settings {
            SettingsView(permissions: store.permissions)
        }

        MenuBarExtra(HostInfo.name, systemImage: "scribble") {
            AppMenuView().environmentObject(store)
        }
    }
}

@MainActor final class UntitledAppDelegate: NSObject, NSApplicationDelegate {
    var prepareForQuit: (() async -> Bool)?
    var showMainWindow: (() -> Void)?
    var handledLaunchArguments = false
    private var finishing = false
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let showMainWindow else { return true }
        // Other windows (such as Settings) can keep the default reopen behavior
        // from restoring the main scene. Always target the same scene as the menu.
        showMainWindow()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForQuit else { return .terminateNow }
        guard !finishing else { return .terminateLater }
        finishing = true
        Task {
            let ready = await prepareForQuit()
            if !ready { finishing = false }
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}

private struct AppMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var store: PluginStore

    var body: some View {
        Button("打开主面板") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("设置…") }
        shortcutsMenu
        Button("权限管理…") {
            store.permissions.settingsPage = .permissions
            store.permissions.refresh()
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        ForEach(store.installed.filter { $0.isEnabled && !store.uiRegistry.interface(for: $0.manifest).items(in: .menuBar).isEmpty }) { plugin in
            Divider()
            PluginMenuContributions(plugin: plugin).environmentObject(store)
        }
        Divider()
        Button("退出 Untitled") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var shortcutsMenu: some View {
        Menu("快捷键") {
            Button(store.hotKeysPaused ? "恢复插件快捷键" : "暂停插件快捷键") {
                store.setHotKeysPaused(!store.hotKeysPaused)
            }
            Button(store.priorityHotKeysEnabled ? "不再优先使用插件快捷键" : "优先使用插件快捷键…") {
                if store.priorityHotKeysEnabled {
                    store.setPriorityHotKeysEnabled(false)
                } else {
                    confirmPriorityShortcuts()
                }
            }
            if store.shortcutRecoveryNeeded {
                Divider()
                if store.permissions.hasShortcutRoutingAccess() {
                    Button("重试快捷键") { store.retryHotKeys() }
                } else {
                    Button("前往辅助功能授权…") { store.permissions.revealShortcutRoutingPermissions() }
                }
            }
        }
    }

    private func confirmPriorityShortcuts() {
        let alert = NSAlert()
        alert.messageText = "优先使用插件快捷键？"
        alert.informativeText = "快捷键冲突时，Untitled 会尝试优先执行插件操作，其他应用或系统可能收不到这个快捷键。此选项需要辅助功能权限。"
        alert.addButton(withTitle: "开启")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.setPriorityHotKeysEnabled(true)
    }
}

private struct PluginMenuContributions: View {
    @EnvironmentObject private var store: PluginStore
    @StateObject private var navigation = PluginUINavigation()
    let plugin: InstalledPlugin
    var body: some View {
        let context = PluginUIContext(pluginID: plugin.id, store: store, navigation: navigation)
        Menu(store.presentation(for: plugin.manifest).name) {
            ForEach(store.uiRegistry.interface(for: plugin.manifest).items(in: .menuBar)) { item in
                PluginSlotItemView(item: item, context: context, menuItem: true)
            }
        }
    }
}
