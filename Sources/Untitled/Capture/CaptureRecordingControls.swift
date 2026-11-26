import AppKit
@preconcurrency import AVFoundation

@MainActor final class CaptureCameraPair {
    private var cameras: [CaptureCameraOverlay] = []
    var windowIDs: [CGWindowID] { cameras.compactMap(\.windowID) }
    func start(in selection: CaptureSelection, permissions: PluginPermissionClient) async throws {
        let defaults = UserDefaults.standard
        let second = defaults.bool(forKey: "capture.secondCamera")
        let secondID = defaults.string(forKey: "capture.secondCameraDevice") ?? ""
        let firstID = defaults.string(forKey: "capture.cameraDevice") ?? ""
        let effectiveFirst = firstID.isEmpty ? AVCaptureDevice.default(for: .video)?.uniqueID : firstID
        if second, secondID.isEmpty || secondID == effectiveFirst { throw PluginError.invalid("请选择另一台摄像头作为第二摄像头。") }
        let first = CaptureCameraOverlay(); cameras = [first]
        do {
            try await first.start(in: selection, permissions: permissions)
            if second {
                let other = CaptureCameraOverlay(); cameras.append(other)
                try await other.start(in: selection, permissions: permissions, deviceID: secondID, secondary: true)
            }
        } catch { stop(); throw error }
    }
    func stop() { cameras.forEach { $0.stop() }; cameras = [] }
}
