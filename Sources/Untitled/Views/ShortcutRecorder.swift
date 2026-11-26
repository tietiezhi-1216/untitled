import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey?
    @Binding var error: String?
    var allowedInputs = ShortcutInputKind.all

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button; button.action = #selector(RecorderButton.startRecording)
        button.setAccessibilityLabel("录制快捷键")
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.hotKey = hotKey; button.allowedInputs = allowedInputs
        button.isEnabled = !allowedInputs.isEmpty && context.environment.isEnabled
        button.onRecord = { error = nil; hotKey = $0 }
        button.onError = { error = $0 }
        button.updateTitle()
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stopRecording() }

    final class RecorderButton: NSButton {
        var hotKey: HotKey?
        var onRecord: ((HotKey) -> Void)?
        var onError: ((String) -> Void)?
        var allowedInputs = ShortcutInputKind.all
        private var isRecording = false
        private var pending: HotKey?
        private var soloModifier: UInt16?
        private var monitor: Any?, resignObserver: NSObjectProtocol?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { startRecording() }

        @objc func startRecording() {
            guard isEnabled, !isRecording, let window, window.makeFirstResponder(self) else { return }
            isRecording = true
            HotKeyRecordingSession.setRecording(true)
            // Only observe AppKit events in this recorder's own window while it is armed.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .rightMouseDown, .scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, self.isRecording, self.window?.firstResponder === self else { return event }
                if event.type == .leftMouseDown {
                    self.stopRecording(); return event
                }
                let mouseEvent = [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type)
                // Some drivers expose thumb buttons without an AppKit window tag.
                // The recorder is already the key window/first responder, so those
                // local mouse events are still safe to inspect.
                if !mouseEvent, event.window !== self.window { return event }
                return self.consume(event) ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            }
            updateTitle()
        }
        override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if isRecording, window?.firstResponder === self, event.type == .keyDown { return consume(event) }
            return super.performKeyEquivalent(with: event)
        }

        /// Finish on the matching release, so repeats or mouse-up won't fire the shortcut we just recorded.
        func consume(_ event: NSEvent) -> Bool {
            guard isRecording else { return false }
            switch event.type {
            case .flagsChanged:
                let code = event.keyCode
                guard code == UInt16(kVK_RightCommand) || code == UInt16(kVK_RightControl) else {
                    soloModifier = nil; return false
                }
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                let wasLatched = soloModifier == code
                let down: Bool
                if code == UInt16(kVK_RightCommand) {
                    down = HotKey.rightCommandDown(flags, fallback: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_RightCommand)) })
                } else {
                    down = wasLatched
                        ? CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_RightControl))
                        : flags.contains(.maskControl)
                }
                if down {
                    let alone = code == UInt16(kVK_RightCommand)
                        ? HotKey.rightCommandAlone(flags) && !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Command))
                        : HotKey.rightControlAlone(flags, leftControlDown: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Control)))
                    soloModifier = pending == nil && alone ? code : nil
                } else {
                    let alone = soloModifier == code; soloModifier = nil
                    if alone && pending == nil {
                        stage(code == UInt16(kVK_RightCommand) ? .rightCommand : .rightControl); commit()
                    }
                }
                return false // Never swallow normal modifier semantics in the recorder.
            case .rightMouseDown, .scrollWheel:
                soloModifier = nil; return false
            case .keyDown:
                soloModifier = nil
                if !event.isARepeat, pending == nil {
                    stage(HotKey(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event), key: Self.keyLabel(event)))
                }
            case .otherMouseDown, .otherMouseDragged:
                soloModifier = nil
                guard let button = UInt32(exactly: event.buttonNumber), HotKey.sideButtons.contains(button) else { return false }
                if pending == nil { stage(HotKey(mouseButton: button, modifiers: Self.modifiers(event))) }
            case .keyUp:
                if pending?.keyCode == UInt32(event.keyCode) { commit() }
            case .otherMouseUp:
                guard let button = UInt32(exactly: event.buttonNumber), HotKey.sideButtons.contains(button) else { return false }
                if pending?.mouseButton == button { commit() }
            default: return false
            }
            return true
        }
        private func stage(_ candidate: HotKey) {
            do { try candidate.validate(allowedInputs: allowedInputs); pending = candidate }
            catch { onError?(error.localizedDescription) }
        }
        private func commit() {
            guard let value = pending else { return }
            stopRecording(); hotKey = value; onRecord?(value); updateTitle()
        }
        private static func modifiers(_ event: NSEvent) -> UInt32 {
            let flags = event.modifierFlags
            var value: UInt32 = 0
            if flags.contains(.command) { value |= UInt32(cmdKey) }
            if flags.contains(.option) { value |= UInt32(optionKey) }
            if flags.contains(.control) { value |= UInt32(controlKey) }
            if flags.contains(.shift) { value |= UInt32(shiftKey) }
            return value
        }
        private static func keyLabel(_ event: NSEvent) -> String {
            let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
            if let name = special[event.keyCode] { return name }
            if let value = event.charactersIgnoringModifiers?.uppercased(), !value.isEmpty { return value }
            return "键 \(event.keyCode)"
        }
        func stopRecording() {
            guard isRecording else { return }
            isRecording = false; pending = nil; soloModifier = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
            HotKeyRecordingSession.setRecording(false); updateTitle()
        }
        func updateTitle() {
            title = isRecording ? (allowedInputs.contains(.mouseButton) ? "按键或按鼠标侧键…" : "按下按键…") : hotKey?.display ?? "点击录制快捷键"
            toolTip = isRecording ? "点击别处取消录制" : nil
        }
    }
}
