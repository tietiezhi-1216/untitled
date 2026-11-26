import AppKit
#if SWIFT_PACKAGE
import DictationIMEKit
#endif

/// AX is read-only here. Only the system-activated IMK client mutates text; never re-enter the
/// legacy keyboard writer for an in-flight utterance, even if a final acknowledgement is lost.
@MainActor final class DictationMarkedTextTarget {
    private let editor: any DictationEditorReading
    private let bridge: any DictationMarkedBridge
    private var anchor: DictationTextAnchor
    private let focus: DictationIMEFocus
    private let session = UUID()
    private var begun = false, closed = false, writing = false, finishing = false
    private var revision = 0
    var acknowledgedLength: Int? { anchor.inserted.utf16.count }
    static func capture() throws -> DictationMarkedTextTarget {
        guard DictationInputSourceSetup.selectable(DictationIME.sourceID) != nil else {
            throw PluginError.invalid(DictationInputSourceSetup.setupRequired)
        }
        guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier else { throw DictationTargetError.unavailable }
        let (editor, snapshot) = try DictationTextTarget.captureEditor()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else { throw DictationTargetError.changed }
        return try .init(editor: editor, snapshot: snapshot, pid: front.processIdentifier, bundleID: bundleID, bridge: DictationMarkedTextBridge())
    }
    init(editor: any DictationEditorReading, snapshot: DictationEditorSnapshot, pid: pid_t, bundleID: String, bridge: any DictationMarkedBridge) throws {
        self.editor = editor; self.bridge = bridge
        anchor = try .init(value: snapshot.value, selection: snapshot.selection)
        focus = .init(pid: pid, bundleID: bundleID, selection: anchor.selection)
    }
    isolated deinit { cancel() }
    func cancel() {
        guard !closed else { return }; closed = true
        bridge.close(); editor.cancel() // No last-chance insertion or restoration of selected text.
    }
    private func check() throws {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
    }
    func prepareForFinal() { finishing = true }
    func validate() async throws {
        try check()
        if writing { try await editor.validateFocus(); return }
        let version = revision, snapshot = try await editor.readableSnapshot()
        try check(); guard !writing, version == revision else { return }
        if begun { try bridge.validate() }
        _ = try anchor.replacement(anchor.inserted, value: snapshot.value, selected: snapshot.selection)
    }
    private func proof() async throws -> DictationIMEProof {
        let caret = try await editor.compositionCaret(at: anchor.selection.location)
        let snapshot = try await editor.readableSnapshot(); try check()
        _ = try anchor.replacement(anchor.inserted, value: snapshot.value, selected: snapshot.selection)
        return .init(value: snapshot.value, caret: caret)
    }
    func update(_ text: String) async throws { try await deliver(text, final: false) }
    func commitFinal(_ text: String) async throws { finishing = true; try await deliver(text, final: true) }
    private func deliver(_ raw: String, final: Bool) async throws {
        try check(); guard !writing else { throw DictationTargetError.unconfirmed }
        writing = true; defer { writing = false }
        do {
            let text = DictationTextTarget.keyboardSafeText(raw)
            guard !text.isEmpty, text.utf16.count <= DictationIME.textLimit else { throw DictationTargetError.unconfirmed }
            if !final && finishing { return }
            if !begun {
                let initial = try await proof(); try check()
                try await bridge.begin(session: session, focus: focus, proof: initial); try check(); begun = true
            }
            // Selection/activation is asynchronous. Re-read the *original AX element* even before the first mutation.
            let evidence = try await proof(); try check()
            if !final && finishing { return }
            try await bridge.send(.init(session: session, operation: final ? .commit : .mark, proof: evidence, text: text))
            let expected = (anchor.original as NSString).replacingCharacters(in: anchor.selection, with: text)
            let caret = NSRange(location: anchor.selection.location + text.utf16.count, length: 0)
            let deadline = ContinuousClock.now.advanced(by: final ? .milliseconds(1200) : .milliseconds(700))
            repeat {
                try check()
                do {
                    let actual = try await editor.snapshot(); try check()
                    if actual.selection == caret, DictationIME.literal(actual.value, expected) {
                        anchor.commit(text); revision &+= 1; if final { cancel() }; return
                    }
                } catch DictationTargetError.unavailable { /* Poll only; do not replay the request. */ }
                try await Task.sleep(for: .milliseconds(12))
            } while ContinuousClock.now < deadline
            throw DictationTargetError.unconfirmed
        } catch { cancel(); throw error }
    }
}
