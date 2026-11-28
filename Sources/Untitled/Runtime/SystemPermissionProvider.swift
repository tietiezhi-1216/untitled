import AVFoundation
import UntitledPluginSDK
import AppKit
@preconcurrency import ApplicationServices

@MainActor package enum SystemPermissionProvider {
    package static func drivers() -> [HostPermissionDriver] {
        [
            make(
                .screenRecording, "屏幕与系统音频录制", "允许已声明并获得授权的操作采集屏幕与系统音频。", "display", "ScreenCapture",
                status: { CGPreflightScreenCaptureAccess() ? .authorized : .notGranted },
                request: { _ = CGRequestScreenCaptureAccess() }),
            make(
                .accessibility, "辅助功能", "允许已授权的操作访问辅助功能，以及你主动开启的宿主快捷键优先拦截。", "accessibility", "Accessibility",
                status: { AXIsProcessTrusted() ? .authorized : .notGranted },
                request: {
                    _ = AXIsProcessTrustedWithOptions(
                        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }),
            make(
                .inputMonitoring, "输入监控", "允许已声明并获得授权的操作监听输入事件。", "keyboard", "ListenEvent",
                status: { CGPreflightListenEventAccess() ? .authorized : .notGranted },
                request: { _ = CGRequestListenEventAccess() }),
            make(
                .camera, "摄像头", "允许已声明并获得授权的操作访问摄像头。", "camera", "Camera",
                status: { mediaStatus(.video) },
                request: {
                    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                    }
                }),
            make(
                .microphone, "麦克风", "允许已声明并获得授权的操作采集麦克风输入。", "mic", "Microphone",
                status: { mediaStatus(.audio) },
                request: {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                    }
                }),
            HostNativeCapabilities.notificationDriver,
        ]
    }
    private static func make(
        _ id: HostPermissionID, _ title: String, _ summary: String, _ symbol: String, _ pane: String,
        status: @escaping () -> HostPermissionStatus, request: @escaping () async -> Void
    ) -> HostPermissionDriver {
        .init(
            descriptor: .init(id: id, title: title, summary: summary, symbol: symbol),
            status: status, request: request,
            openSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            })
    }
    private static func mediaStatus(_ type: AVMediaType) -> HostPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .notGranted
        }
    }
}
