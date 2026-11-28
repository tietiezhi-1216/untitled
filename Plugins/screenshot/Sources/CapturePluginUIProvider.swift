import Combine
import UntitledPluginSDK
import UntitledHost
import SwiftUI

extension PluginManifest {
    // Capability lifecycle check; this never selects a v2 plugin's layout.
    var hasCaptureCapability: Bool { actions.contains(where: \.isScreenshotAction) }
}

/// Deliberate migration of the built-in screenshot plugin to three configurable
/// commands. Leave every other plugin and all non-shortcut capture capabilities alone.
enum CaptureShortcutProfile {
    static let pluginID = "com.untitled.screenshot"
    static let actions: [ActionKind] = [.captureRegion, .pinSelection, .restorePin]

    static func applies(to manifest: PluginManifest) -> Bool {
        manifest.id == pluginID && manifest.actions.contains(.pinSelection)
    }

    static func retainBindings(in record: inout InstalledPlugin, for manifest: PluginManifest) {
        let templates = manifest.templates.filter { actions.contains($0.action) && $0.installByDefault == true }
        let before = record.commands
        record.commands = templates.compactMap { template in
            let matches = before.filter {
                $0.action == template.action || (template.action == .pinSelection && $0.action == .pinClipboard)
            }
            guard var command = matches.first(where: { $0.templateID == template.id }) ?? matches.first else { return nil }
            command.action = template.action
            command.templateID = template.id
            return command
        }
        let ids = Set(templates.map(\.id))
        record.initializedDefaultTemplateIDs = record.initializedDefaultTemplateIDs?.filter { ids.contains($0) }
    }
}

struct CapturePluginUIProvider: PluginUIProvider {
    let runtime: CapturePluginRuntime
    func validateBinding(_ command: PluginCommand, in plugin: InstalledPlugin) throws {
        guard CaptureShortcutProfile.applies(to: plugin.manifest) else { return }
        guard CaptureShortcutProfile.actions.contains(command.action),
              plugin.manifest.templates.contains(where: { $0.id == command.templateID && $0.action == command.action }),
              !plugin.commands.contains(where: { $0.id != command.id && $0.templateID == command.templateID }) else {
            throw PluginError.invalid("截图只支持修改已有的三个快捷键。")
        }
    }
    func migrateBindings(in plugin: inout InstalledPlugin, to manifest: PluginManifest, occupiedHotKeys: Set<String>) {
        if CaptureShortcutProfile.applies(to: manifest) { CaptureShortcutProfile.retainBindings(in: &plugin, for: manifest) }
    }

    func register(in registry: PluginUIRegistry) {
        registry.component("capture.history", requiredActions: [.captureHistory], usesTrailingScrollGutter: true) { context in
            let hasFooterStatus = [PluginUISlot.footerLeading, .footerTrailing].contains { slot in
                context.interface?.items(in: slot).contains { $0.component == "capture.status" } == true
            }
            return AnyView(CaptureHistoryView(pluginID: context.pluginID, capture: runtime.screenshots(in: context.store),
                                              showSummary: !hasFooterStatus))
        }
        registry.component("capture.pins", requiredActions: [.pinClipboard]) { context in
            AnyView(CapturePinsView(manager: runtime.screenshots(in: context.store).pinManager))
        }
        registry.component("capture.pinLibrary", requiredActions: [.restorePin]) { context in
            AnyView(CapturePinsView(manager: runtime.screenshots(in: context.store).pinManager))
        }
        registry.component("capture.shortcuts", requiredActions: Set(CaptureShortcutProfile.actions)) { context in
            AnyView(CaptureGlobalShortcutSettingsView(pluginID: context.pluginID))
        }
        registry.component("capture.preferences", requiredActions: [.captureRegion]) { context in
            let capture = runtime.screenshots(in: context.store)
            return AnyView(ScreenshotSettingsView(mouse: capture.globalMouse, capture: capture))
        }
        registry.component("capture.options", requiredActions: [.captureRegion]) { context in
            let capture = runtime.screenshots(in: context.store)
            return AnyView(ScreenshotSettingsView(mouse: capture.globalMouse, capture: capture, showLocalShortcuts: false))
        }
        registry.component("capture.localShortcuts", requiredActions: [.captureRegion]) { _ in
            AnyView(
                ScrollView {
                    CaptureLocalShortcutSettingsView().padding(.trailing, 12)
                }
                .panelRegion("capture.settings.localShortcuts")
            )
        }
        registry.component("capture.status", requiredActions: [.captureHistory]) { context in
            AnyView(CaptureStatusView(capture: runtime.screenshots(in: context.store)))
        }
        let actions: [(String, ActionKind)] = [
            ("region", .captureRegion), ("window", .captureWindow), ("screen", .captureScreen),
            ("scrollVertical", .captureScrolling), ("scrollHorizontal", .captureScrolling),
            ("record", .captureRecording), ("pinSelection", .pinSelection), ("pinClipboard", .pinClipboard),
            ("togglePins", .togglePins), ("history", .captureHistory),
            ("delayed", .captureDelayed), ("copy", .captureAndCopy), ("repeatRegion", .captureLastRegion),
            ("restorePin", .restorePin), ("closePins", .closePins), ("hideOtherPins", .hideOtherPins),
            ("clickThrough", .togglePinClickThrough), ("cycleGroup", .cyclePinGroup), ("pinFiles", .pinFiles),
            ("toggleHotKeys", .toggleCaptureHotKeys),
        ]
        for (name, action) in actions {
            registry.command(
                "capture.\(name)", requiredActions: [action],
                presentation: { context in
                    let capture = runtime.screenshots(in: context.store)
                    if #unavailable(macOS 15), action == .captureRecording {
                        return .init(title: "录屏（需要 macOS 15）", symbol: runtime.actionPresentation[action]?.symbol ?? "camera", isEnabled: false)
                    }
                    let title: String =
                        switch name {
                        case "scrollVertical": "纵向长截图"
                        case "scrollHorizontal": "横向长截图"
                        case "record": capture.isRecording ? "停止录屏" : "录屏"
                        case "toggleHotKeys": runtime.shortcutsPaused ? "恢复截图快捷键" : "暂停截图快捷键"
                        default: runtime.actionPresentation[action]?.title ?? action.rawValue
                        }
                    return .init(
                        title: title,
                        symbol: name == "record" && capture.isRecording ? "stop.circle.fill" : runtime.actionPresentation[action]?.symbol ?? "camera",
                        isEnabled: !capture.busy || (action == .captureRecording && capture.isRecording))
                },
                updates: { context in
                    runtime.screenshots(in: context.store).objectWillChange.eraseToAnyPublisher()
                }
            ) { context in
                if name == "scrollVertical" || name == "scrollHorizontal" {
                    UserDefaults.standard.set(
                        name == "scrollVertical" ? StitchAxis.vertical.rawValue : StitchAxis.horizontal.rawValue,
                        forKey: "capture.scrollAxis")
                }
                try await runtime.perform(action, for: context.pluginID, in: context.store)
            }
        }
        registry.command(
            "capture.importImage", requiredActions: [.captureRegion],
            presentation: { context in
                .init(title: "导入…", symbol: "square.and.arrow.down", isEnabled: !runtime.screenshots(in: context.store).busy)
            }, updates: { runtime.screenshots(in: $0.store).objectWillChange.eraseToAnyPublisher() }
        ) { context in
            runtime.screenshots(in: context.store).importImage()
        }
    }

    func legacyInterface(for manifest: PluginManifest) -> PluginInterface? {
        // Only v1 packages need this compatibility adapter. v2 uses its own declaration verbatim.
        guard manifest.schemaVersion == 1, manifest.actions.contains(.captureRegion),
            manifest.actions.contains(.captureHistory)
        else { return nil }
        var ui = PluginUIRegistry.legacyCommands
        ui.icon = "camera.viewfinder"
        ui.slots[PluginUISlot.headerTrailing.rawValue, default: []].append(
            PluginUIItem(
                id: "preferencesButton", kind: .button, symbol: "gearshape",
                panel: "preferences", presentation: .sheet)
        )
        ui.slots[PluginUISlot.toolbarLeading.rawValue] = [
            .command("region", "capture.region"), .command("record", "capture.record"),
        ].filter { item in
            item.command != "capture.record" || manifest.actions.contains(.captureRecording)
        }
        ui.slots[PluginUISlot.toolbarTrailing.rawValue] = [.command("import", "capture.importImage")]
        ui.slots[PluginUISlot.content.rawValue] = [
            PluginUIItem(id: "pages", kind: .tabs, panels: ["history", "shortcuts"])
        ]
        ui.slots[PluginUISlot.footerLeading.rawValue] = [.component("status", "capture.status")]
        ui.panels = [
            .init(id: "history", title: "历史记录", component: "capture.history"),
            .init(
                id: "shortcuts", title: "快捷键",
                slots: [
                    PluginUISlot.toolbarLeading.rawValue: [.component("shortcutHeading", "host.commandHeading")],
                    PluginUISlot.toolbarTrailing.rawValue: [.component("shortcutAdd", "host.addCommand")],
                    PluginUISlot.content.rawValue: [.component("shortcutCommands", "host.commands")],
                    PluginUISlot.footerLeading.rawValue: [.component("shortcutStatus", "host.commandStatus")],
                ]),
            .init(id: "preferences", title: "截图设置", component: "capture.preferences"),
        ]
        ui.slots[PluginUISlot.menuBar.rawValue] = manifest.actions.filter(\.isScreenshotAction).compactMap { action in
            actionsReference(action).map { .command("menu.\(action.rawValue)", $0) }
        }
        return ui
    }

    private func actionsReference(_ action: ActionKind) -> String? {
        switch action {
        case .captureRegion: "capture.region"
        case .captureWindow: "capture.window"
        case .captureScreen: "capture.screen"
        case .captureScrolling: "capture.scrollVertical"
        case .captureRecording: "capture.record"
        case .pinSelection: "capture.pinSelection"
        case .pinClipboard: "capture.pinClipboard"
        case .togglePins: "capture.togglePins"
        case .captureHistory: "capture.history"
        default: nil
        }
    }
}
