import AppKit
import UntitledPluginSDK
import UntitledHost

extension ActionKind {
    static let captureRegion = Self(rawValue: "captureRegion")
    static let captureWindow = Self(rawValue: "captureWindow")
    static let captureScreen = Self(rawValue: "captureScreen")
    static let captureScrolling = Self(rawValue: "captureScrolling")
    static let captureRecording = Self(rawValue: "captureRecording")
    static let pinSelection = Self(rawValue: "pinSelection")
    static let togglePins = Self(rawValue: "togglePins")
    static let captureHistory = Self(rawValue: "captureHistory")
    static let pinClipboard = Self(rawValue: "pinClipboard")
    static let captureDelayed = Self(rawValue: "captureDelayed")
    static let captureAndCopy = Self(rawValue: "captureAndCopy")
    static let captureLastRegion = Self(rawValue: "captureLastRegion")
    static let restorePin = Self(rawValue: "restorePin")
    static let closePins = Self(rawValue: "closePins")
    static let hideOtherPins = Self(rawValue: "hideOtherPins")
    static let togglePinClickThrough = Self(rawValue: "togglePinClickThrough")
    static let cyclePinGroup = Self(rawValue: "cyclePinGroup")
    static let pinFiles = Self(rawValue: "pinFiles")
    static let toggleCaptureHotKeys = Self(rawValue: "toggleCaptureHotKeys")
}

/// Screenshot state, permission choices, tray/launch hooks and hotkey policy
/// belong to this module. The host only dispatches registered actions/events.
@MainActor package final class CapturePluginRuntime: NativePluginRuntime {
    package let actions = CapturePluginActions.all
    package var actionPresentation: [ActionKind: PluginActionPresentation] { CapturePluginActions.presentation }

    package func registerUI(in registry: PluginUIRegistry) { registry.register(CapturePluginUIProvider(runtime: self)) }
    package func legacyPermissions(for manifest: PluginManifest) -> [PluginPermissionDeclaration] {
        CapturePermissionRequirements.legacyDeclarations(for: manifest)
    }
    private let directory: URL?
    private let usesLiveHistory: Bool
    private let usesLiveMouseRouting: Bool
    private let factory: (URL?) -> ScreenshotController
    private var controller: ScreenshotController?
    private(set) var shortcutsPaused = false

    package init(directory: URL?, usesLiveHistory: Bool, usesLiveMouseRouting: Bool = false,
                 factory: ((URL?) -> ScreenshotController)? = nil) {
        self.directory = directory
        self.usesLiveHistory = usesLiveHistory
        self.usesLiveMouseRouting = usesLiveMouseRouting
        self.factory = factory ?? { ScreenshotController(directory: $0) }
    }

    func screenshots(in host: PluginStore) -> ScreenshotController {
        if let controller { return controller }
        let viewModel = factory(directory)
        viewModel.didCopyPNG = { [weak host] data, count in
            host?.publishRuntimeEvent(.copiedImage(data, changeCount: count))
        }
        viewModel.reportError = { [weak host] in host?.errorMessage = $0 }
        if let error = viewModel.errorMessage { host.errorMessage = error }
        viewModel.canUseFeatures = { [weak host] in
            host?.installed.contains { $0.isEnabled && $0.manifest.hasCaptureCapability } == true
        }
        controller = viewModel
        if let plugin = enabledCapture(in: host) { configureMouse(viewModel, plugin: plugin, in: host) }
        viewModel.pinManager.activate()
        return viewModel
    }

    private func enabledCapture(in host: PluginStore) -> InstalledPlugin? {
        host.installed.first { $0.isEnabled && $0.manifest.hasCaptureCapability }
    }

    private func configureMouse(_ screenshot: ScreenshotController, plugin: InstalledPlugin, in host: PluginStore) {
        guard usesLiveMouseRouting else { screenshot.globalMouse.stop(); return }
        screenshot.configureGlobalMouse(permissions: host.permissionClient(for: plugin.id),
            allowed: { [weak self] in self?.shortcutsPaused == false && !HotKeyRecordingSession.isRecording })
    }

    package func receive(_ event: PluginRuntimeEvent, in host: PluginStore) {
        switch event {
        case .installedPluginsChanged:
            let cleanup = usesLiveHistory && host.allowsPluginActivity &&
                host.installed.contains { $0.isEnabled && $0.manifest.actions.contains(.captureHistory) }
            if cleanup { screenshots(in: host).setHistoryCleanupActive(true) }
            else { controller?.setHistoryCleanupActive(false) }
        case .willLaunch:
            if enabledCapture(in: host) != nil { screenshots(in: host).pinManager.activate() }
        case .willReloadShortcuts:
            if let plugin = enabledCapture(in: host) {
                if let controller { configureMouse(controller, plugin: plugin, in: host) }
                else if usesLiveMouseRouting && UserDefaults.standard.bool(forKey: "capture.mouse.enabled") { _ = screenshots(in: host) }
            } else { controller?.globalMouse.stop() }
        default: break
        }
    }

    package func didReplace(_ previous: InstalledPlugin, with plugin: InstalledPlugin, in host: PluginStore) {
        let removedActions = Set(previous.manifest.actions).intersection(actions).subtracting(plugin.manifest.actions)
        let before = Set((previous.manifest.permissions ?? legacyPermissions(for: previous.manifest)).map(\.id))
        let after = Set((plugin.manifest.permissions ?? legacyPermissions(for: plugin.manifest)).map(\.id))
        guard !removedActions.isEmpty || !before.isSubset(of: after) else { return }
        controller?.deactivate() // Preserve live output, but stop work the new manifest no longer allows.
        if enabledCapture(in: host) != nil { controller?.pinManager.activate() }
    }

    package func didSetEnabled(_ plugin: InstalledPlugin, in host: PluginStore) {
        if !plugin.isEnabled { controller?.deactivate() }
        else { controller?.pinManager.activate(); controller?.objectWillChange.send() }
    }
    package func willUninstall(_ plugin: InstalledPlugin, in host: PluginStore) throws { controller?.deactivate() }
    package func prepareForQuit() async -> Bool { await controller?.prepareForQuit() ?? true }

    package func includesShortcut(_ command: PluginCommand, in plugin: InstalledPlugin) -> Bool {
        !actions.contains(command.action) || !shortcutsPaused || command.action == .toggleCaptureHotKeys
    }

    package func perform(_ command: PluginCommand, for pluginID: String, in host: PluginStore) async throws {
        try await perform(command.action, for: pluginID, in: host)
    }
    package func perform(_ action: ActionKind, for pluginID: String, in host: PluginStore) async throws {
        guard actions.contains(action), let plugin = host.enabledPlugin(pluginID, allowing: action) else {
            throw PluginError.invalid("请先启用截图插件。")
        }
        if action == .toggleCaptureHotKeys {
            shortcutsPaused.toggle()
            host.refreshShortcutBindings()
            return
        }
        // Ignore another capture request before permission checks or lazy construction.
        guard controller?.shouldIgnoreCaptureRequest(action) != true else { return }
        let client = host.permissionClient(for: pluginID)
        if !(action == .captureRecording && controller?.isRecording == true) {
            try client.require(CapturePermissionRequirements.permissions(for: action))
        }
        let screenshot = screenshots(in: host)
        screenshot.showHistory = { [weak host] in
            host?.requestedPluginID = pluginID
            host?.showMainWindow()
        }
        let live = Set(CaptureSelectionLiveAction.allCases.filter { plugin.manifest.actions.contains($0.action) })
        try await screenshot.perform(action, permissions: client, liveActions: live) { [weak host] action in
            host?.enabledPlugin(pluginID, allowing: action) != nil
        }
    }
}

enum CapturePluginActions {
    private static let labels: [ActionKind: PluginActionPresentation] = [
        .captureRegion: .init(title: "区域截图", symbol: "viewfinder"),
        .captureWindow: .init(title: "窗口截图", symbol: "macwindow"),
        .captureScreen: .init(title: "全屏截图", symbol: "display"),
        .captureScrolling: .init(title: "滚动长截图", symbol: "scroll"),
        .captureRecording: .init(title: "开始或停止录屏", symbol: "record.circle"),
        .pinSelection: .init(title: "贴图（当前选区）", symbol: "pin"),
        .pinClipboard: .init(title: "贴图（当前选区）", symbol: "pin"),
        .togglePins: .init(title: "隐藏或显示贴图", symbol: "eye"),
        .captureHistory: .init(title: "打开截图历史", symbol: "clock"),
        .captureDelayed: .init(title: "自定义 / 延时截图", symbol: "timer"),
        .captureAndCopy: .init(title: "截图并复制", symbol: "doc.on.clipboard"),
        .captureLastRegion: .init(title: "重复上次截图区域", symbol: "viewfinder.rectangular"),
        .restorePin: .init(title: "恢复上次关闭的贴图", symbol: "pin.circle"),
        .closePins: .init(title: "关闭所有贴图", symbol: "xmark.rectangle.on.rectangle"),
        .hideOtherPins: .init(title: "隐藏或显示其他贴图", symbol: "eye.slash"),
        .togglePinClickThrough: .init(title: "切换贴图鼠标穿透", symbol: "cursorarrow.rays"),
        .cyclePinGroup: .init(title: "切换贴图组", symbol: "square.stack.3d.up"),
        .pinFiles: .init(title: "文件贴图", symbol: "photo.on.rectangle.angled"),
        .toggleCaptureHotKeys: .init(title: "暂停或恢复截图快捷键", symbol: "keyboard")
    ]
    static let presentation = labels.mapValues { label in
        var value = label
        value.detail = "全局截图操作"
        value.bindingHelp = "绑定后可在任意应用中执行此截图操作。首次截屏或录屏时需要允许屏幕录制权限。"
        return value
    }
    static let all = Set(presentation.keys)
}
extension ActionKind {
    var isScreenshotAction: Bool { CapturePluginActions.all.contains(self) }
}
