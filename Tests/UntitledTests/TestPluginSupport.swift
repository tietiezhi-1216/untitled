import Foundation
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

/// Test-only access to a feature controller. Production providers hold their
/// own runtime directly; there is no feature service locator on the host.
@MainActor extension PluginStore {
    private var captureForTesting: CapturePluginRuntime { runtime.owner(of: .captureRegion) as! CapturePluginRuntime }
    private var sharingForTesting: SharingPluginRuntime { runtime.owner(of: .sharePeripherals) as! SharingPluginRuntime }
    private var speechForTesting: DoubaoSpeechPluginRuntime { runtime.owner(of: .toggleDoubaoDictation) as! DoubaoSpeechPluginRuntime }

    var screenshots: ScreenshotController { captureForTesting.screenshots(in: self) }
    var captureHotKeysPaused: Bool { captureForTesting.shortcutsPaused }
    func performScreenshot(_ action: ActionKind, pluginID: String) async throws {
        try await captureForTesting.perform(action, for: pluginID, in: self)
    }
    func peripheralSharing(for pluginID: String) -> PeripheralSharingController {
        sharingForTesting.controller(for: pluginID, in: self)
    }
    func performPeripheralAction(_ action: ActionKind, pluginID: String) throws {
        try sharingForTesting.perform(action, for: pluginID, in: self)
    }
    func doubaoDictation(for pluginID: String) -> DoubaoDictationController { speechForTesting.controller(for: pluginID, in: self) }
    func performDictationAction(_ action: ActionKind, pluginID: String, holdCommandID: UUID? = nil) throws {
        try speechForTesting.perform(action, for: pluginID, holdCommandID: holdCommandID, in: self)
    }
}
