import Foundation
import UntitledPluginSDK
import UntitledHost
import UntitledPluginCapture
import UntitledPluginSharing
import UntitledPluginSpeech

/// The only assembly point that knows which native modules ship with this app.
@MainActor enum PluginComposition {
    static func makePermissionCenter(runtime: PluginRuntimeRegistry) -> HostPermissionCenter {
        HostPermissionCenter(drivers: SystemPermissionProvider.drivers(), legacyDeclarations: runtime.legacyPermissions)
    }
    static func makeUIRegistry(runtime: PluginRuntimeRegistry? = nil) -> PluginUIRegistry {
        let active = runtime ?? PluginRuntimeRegistry([
            SharingPluginRuntime(defaults: nil, isolated: true),
            WirelessMicrophonePluginRuntime(defaults: nil, isolated: true),
            DoubaoSpeechPluginRuntime(),
            CapturePluginRuntime(directory: nil, usesLiveHistory: false),
        ])
        let registry = PluginUIRegistry()
        registry.register(HostPluginUIProvider())
        active.registerUI(in: registry)
        return registry
    }
    static func isolatedDirectoryForLaunch() -> URL? {
        SharingPluginRuntime.isolatedDirectoryForLaunch()
    }
}

extension PluginStore {
    // Preserve the existing application and test construction API. The store's
    // designated initializer itself only knows about abstract registrations.
    convenience init(directory: URL? = nil, captureDirectory: URL? = nil, startupError: String? = nil,
                     uiRegistry: PluginUIRegistry? = nil, permissions: HostPermissionCenter? = nil,
                     sharingDefaults: UserDefaults? = nil, shortcutDefaults: UserDefaults? = nil,
                     priorityHotKeyDriver: PriorityHotKeyDriver? = nil, ordinaryHotKeyDriver: HotKeyManager.Driver? = nil,
                     sideButtonDriver: PriorityHotKeyDriver? = nil, modifierDriver: PriorityHotKeyDriver? = nil,
                     priorityRecoverySleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                     presentations: PluginPresentationIndex = .bundled, initialCatalog: [CatalogEntry] = [],
                     dictationFactory: ((URL) -> DoubaoDictationController)? = nil,
                     captureFactory: ((URL?) -> ScreenshotController)? = nil,
                     wirelessMicrophoneFactory: ((String, UserDefaults) -> WirelessMicrophoneController)? = nil) {
        let sharing = SharingPluginRuntime(defaults: sharingDefaults, isolated: directory != nil)
        let wireless = WirelessMicrophonePluginRuntime(defaults: sharingDefaults, isolated: directory != nil,
                                                        factory: wirelessMicrophoneFactory)
        let dictation = DoubaoSpeechPluginRuntime(factory: dictationFactory)
        let capture = CapturePluginRuntime(directory: captureDirectory,
            usesLiveHistory: directory == nil && captureDirectory == nil, usesLiveMouseRouting: directory == nil,
            factory: captureFactory)
        let runtime = PluginRuntimeRegistry([sharing, wireless, dictation, capture])
        self.init(runtime: runtime, directory: directory, startupError: startupError,
                  uiRegistry: uiRegistry ?? PluginComposition.makeUIRegistry(runtime: runtime),
                  permissions: permissions ?? PluginComposition.makePermissionCenter(runtime: runtime),
                  shortcutDefaults: shortcutDefaults, priorityHotKeyDriver: priorityHotKeyDriver,
                  ordinaryHotKeyDriver: ordinaryHotKeyDriver, sideButtonDriver: sideButtonDriver, modifierDriver: modifierDriver,
                  priorityRecoverySleep: priorityRecoverySleep, presentations: presentations, initialCatalog: initialCatalog)
    }
}
