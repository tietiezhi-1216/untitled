import AppKit
import UntitledPluginSDK
@testable import UntitledPluginSpeech
import Carbon
#if SWIFT_PACKAGE
import DictationIMEKit
#endif

/// User-invoked, fixed-text acceptance check after Keyboard Settings approval. Not a dictation
/// shortcut: no ASR, microphone, AX capture of another app, pasteboard, history, or global events.
@MainActor enum DictationInputMethodCheck {
    private final class Sample: DictationEditorReading {
        let view: NSTextView, window: NSWindow
        init(view: NSTextView, window: NSWindow) { self.view = view; self.window = window }
        func validateFocus() async throws {
            try Task.checkCancellation()
            guard NSApp.isActive, window.isKeyWindow, window.isVisible, window.firstResponder === view,
                  !IsSecureEventInputEnabled() else { throw DictationTargetError.changed }
        }
        func snapshot() async throws -> DictationEditorSnapshot {
            try await validateFocus(); return .init(value: view.string, selection: view.selectedRange())
        }
        func compositionCaret(at offset: Int) async throws -> CGRect {
            try await validateFocus(); var actual = NSRange(location: NSNotFound, length: 0)
            let rect = view.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: &actual)
            guard actual.location == offset, !rect.isNull, rect.height > 0 else { throw DictationTargetError.unavailable }; return rect
        }
    }
    static func run() async throws {
        guard DictationInputSourceSetup.selectable(DictationIME.sourceID) != nil else { throw PluginError.invalid(DictationInputSourceSetup.instructions) }
        guard let id = Bundle.main.bundleIdentifier, NSApp.isActive else { throw DictationTargetError.unavailable }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 350, height: 84), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "输入法自检 · 不录音"
        let view = NSTextView(frame: window.contentView!.bounds)
        view.isRichText = false; view.font = .systemFont(ofSize: 17); view.textContainerInset = .init(width: 12, height: 12)
        view.isAutomaticTextReplacementEnabled = false; view.string = "测试：原文"; window.contentView = view
        window.center(); window.makeKeyAndOrderFront(nil); defer { window.close() }
        guard window.makeFirstResponder(view) else { throw DictationTargetError.unavailable }
        view.setSelectedRange(NSRange(location: 3, length: 2))
        let sample = Sample(view: view, window: window)
        let target = try await DictationMarkedTextTarget(editor: sample, snapshot: sample.snapshot(), pid: getpid(), bundleID: id, bridge: DictationMarkedTextBridge())
        defer { target.cancel() }
        for draft in ["听", "听写草稿"] {
            try await target.update(draft)
            guard view.hasMarkedText(), view.markedRange() == NSRange(location: 3, length: draft.utf16.count),
                  view.string == "测试：" + draft else { throw DictationTargetError.unconfirmed }
            try await Task.sleep(for: .milliseconds(360))
        }
        try await target.commitFinal("听写定稿。")
        guard !view.hasMarkedText(), view.string == "测试：听写定稿。" else { throw DictationTargetError.unconfirmed }
    }
}
