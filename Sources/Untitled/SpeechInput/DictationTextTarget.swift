import AppKit
import ApplicationServices
import Carbon
import os

enum DictationTargetError: LocalizedError {
    case secure, unavailable, changed, unconfirmed
    var errorDescription: String? {
        switch self {
        case .secure: "安全输入或密码框中不插入听写文字。"
        case .unavailable: "未找到可安全写入的当前输入框。"
        case .changed: "投递期间输入焦点、选区或原文已改变，已停止写入。"
        case .unconfirmed: "输入框未确认完整写入，未重发。"
        }
    }
}

private func sameText(_ lhs: String, _ rhs: String) -> Bool {
    // Swift String equality normalizes canonically equivalent Unicode. AX offsets do not.
    lhs.utf16.elementsEqual(rhs.utf16)
}

struct DictationEditorSnapshot: Sendable {
    let value: String
    let selection: NSRange

    func requireValidOrigin() throws {
        let count = value.utf16.count
        guard count <= 131_072, selection.location >= 0, selection.length >= 0,
              selection.location <= count, selection.length <= count - selection.location,
              Range(selection, in: value) != nil else { throw DictationTargetError.unavailable }
    }
    func matches(_ other: Self) -> Bool {
        selection == other.selection && sameText(value, other.value)
    }
}

/// Ownership model for the separate marked-text adapter.
struct DictationTextAnchor {
    let original: String
    let selection: NSRange
    private(set) var inserted = ""
    private(set) var hasWritten = false
    var range: NSRange { hasWritten ? NSRange(location: selection.location, length: inserted.utf16.count) : selection }
    var expectedValue: String { (original as NSString).replacingCharacters(in: selection, with: inserted) }
    var expectedSelection: NSRange {
        hasWritten ? NSRange(location: selection.location + inserted.utf16.count, length: 0) : selection
    }
    var currentValue: String { hasWritten ? expectedValue : original }

    init(value: String, selection: NSRange) throws {
        try DictationEditorSnapshot(value: value, selection: selection).requireValidOrigin()
        original = value; self.selection = selection
    }
    func replacement(_ text: String, value: String, selected: NSRange) throws -> String {
        guard sameText(value, currentValue), selected == expectedSelection else { throw DictationTargetError.changed }
        guard text.utf16.count <= DoubaoASRLimits.textLength else { throw PluginError.invalid("听写文字超过长度预算。") }
        return (original as NSString).replacingCharacters(in: selection, with: text)
    }
    mutating func commit(_ text: String) { inserted = text; hasWritten = true }
}

/// The speech controller gets one destination only after a service final. It cannot
/// poll editors during recording or write a draft through this interface.
@MainActor protocol DictationFinalInserting: AnyObject {
    var acknowledgedLength: Int? { get }
    func commitFinal(_ text: String) async throws
    func cancel()
}
extension DictationFinalInserting {
    var acknowledgedLength: Int? { nil }
    func cancel() {}
}

/// Testable editor boundary: AX reads establish ownership; real key events drive the app's
/// normal input/undo/DOM event path. A reported-success AXSelectedText setter is NOT proof.
@MainActor protocol DictationEditorReading: AnyObject {
    func validateFocus() async throws
    func compositionCaret(at offset: Int) async throws -> CGRect
    func snapshot() async throws -> DictationEditorSnapshot
    func cancel()
}
@MainActor protocol DictationEditor: DictationEditorReading {
    func insert(_ text: String, replacing snapshot: DictationEditorSnapshot) async throws
}
extension DictationEditorReading {
    func cancel() {}
    func compositionCaret(at offset: Int) async throws -> CGRect { throw DictationTargetError.unavailable }
    func readableSnapshot() async throws -> DictationEditorSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
        while true {
            try Task.checkCancellation()
            do { return try await snapshot() }
            catch DictationTargetError.unavailable {
                // Chromium can temporarily expose a new caret with an old value (or no
                // range) while updating AX. Wait for a readable snapshot; NEVER resend.
                guard ContinuousClock.now < deadline else { throw DictationTargetError.unconfirmed }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

/// The editor is read-only throughout recognition. The sole mutation is inserting the
/// complete service final over the original selection, never selecting or deleting a range.
@MainActor final class DictationTextTarget: DictationFinalInserting {
    private let editor: any DictationEditor
    private let original: DictationEditorSnapshot
    private var finalClaimed = false, cancelled = false
    private(set) var acknowledgedLength: Int? = 0

    static func capture() throws -> DictationTextTarget {
        let (editor, snapshot) = try captureEditor()
        return try .init(editor: editor, snapshot: snapshot)
    }
    static func captureEditor() throws -> (any DictationEditor, DictationEditorSnapshot) {
        try AXDictationEditor.capture()
    }
    convenience init(editor: any DictationEditor) async throws {
        let snapshot = try await editor.readableSnapshot()
        try self.init(editor: editor, snapshot: snapshot)
    }
    init(editor: any DictationEditor, snapshot: DictationEditorSnapshot) throws {
        try snapshot.requireValidOrigin()
        self.editor = editor; original = snapshot
    }
    func validate() async throws {
        try check()
        guard !finalClaimed else { return } // The final transaction now owns validation.
        let current = try await editor.readableSnapshot()
        try check()
        guard !finalClaimed else { return }
        guard original.matches(current) else { throw DictationTargetError.changed }
    }
    func cancel() { cancelled = true; editor.cancel() }

    func commitFinal(_ raw: String) async throws {
        try check()
        guard !finalClaimed else { throw DictationTargetError.unconfirmed }
        // Claim before any await, including when the editor never acknowledges the event.
        finalClaimed = true
        guard raw.utf16.count <= DoubaoASRLimits.textLength else { throw DictationTargetError.unconfirmed }
        let text = Self.keyboardSafeText(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationTargetError.unconfirmed }
        let current = try await editor.readableSnapshot()
        try check()
        guard original.matches(current) else { throw DictationTargetError.changed }
        let expected = DictationEditorSnapshot(
            value: (original.value as NSString).replacingCharacters(in: original.selection, with: text),
            selection: NSRange(location: original.selection.location + text.utf16.count, length: 0))
        // The AX worker checks the original element, security, value and selection again
        // immediately before posting this one event. It cannot select, erase or replay.
        try await editor.insert(text, replacing: original)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
        repeat {
            try check()
            do {
                let actual = try await editor.snapshot()
                try check()
                if actual.matches(expected) { acknowledgedLength = text.utf16.count; return }
            } catch DictationTargetError.unavailable { /* AX can lag. Only poll, never resend. */ }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw DictationTargetError.unconfirmed
    }
    private func check() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
    }
    static func keyboardSafeText(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: result.append(" ")
            default: result.append(scalar)
            }
        }
        return String(result)
    }
}

/// Bounded, checked event encoding; constructing it does not post any input.
/// Quartz stores the whole UTF-16 string, not just a single 16-unit fragment.
enum DictationUnicodeInput {
    static func keyDown(_ text: String, source: CGEventSource) throws -> CGEvent {
        let characters = Array(text.utf16)
        guard !characters.isEmpty, characters.count <= DoubaoASRLimits.textLength,
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { throw DictationTargetError.unconfirmed }
        event.flags = []
        characters.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: $0.baseAddress) }
        var actual = 0
        var readback = [UniChar](repeating: 0, count: characters.count)
        readback.withUnsafeMutableBufferPointer {
            event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &actual, unicodeString: $0.baseAddress)
        }
        guard actual == characters.count, readback == characters else { throw DictationTargetError.unconfirmed }
        return event
    }
}

private final class DictationDeliveryCancellation: Sendable {
    private struct State { var stopped = false; var lostFocus = false; var foreground: pid_t }
    private let state: OSAllocatedUnfairLock<State>
    private let initialPID: pid_t
    init(foreground: pid_t) {
        initialPID = foreground
        state = OSAllocatedUnfairLock(initialState: State(foreground: foreground))
    }
    func cancel() { state.withLock { $0.stopped = true } }
    func foregroundChanged(_ pid: pid_t) {
        state.withLock { $0.foreground = pid; if pid != initialPID { $0.lostFocus = true } }
    }
    func check(foreground pid: pid_t) throws {
        try Task.checkCancellation()
        try withCurrent(foreground: pid) {}
    }
    /// No AX IPC inside the lock. Serialize the actual post against cancellation so an
    /// abandoned worker cannot send an event after clipboard fallback or a new session.
    func withCurrent(foreground pid: pid_t, _ body: () -> Void) throws {
        // body is nonescaping, runs synchronously on the caller's AX worker, and never
        // transfers its worker-owned CGEvents to another executor.
        try state.withLockUnchecked { current in
            guard !current.stopped else { throw CancellationError() }
            guard !current.lostFocus, current.foreground == pid else { throw DictationTargetError.changed }
            body()
        }
    }
}

/// Only Sendable text/range snapshots cross this boundary. CoreFoundation handles are
/// uniquely transferred once and all subsequent AX IPC runs on this one worker actor.
@MainActor private final class AXDictationEditor: DictationEditor {
    private let worker: DictationAXWorker
    private let cancellation: DictationDeliveryCancellation
    private let pid: pid_t
    private var observers: [NSObjectProtocol] = []
    private init(worker: DictationAXWorker, cancellation: DictationDeliveryCancellation, pid: pid_t) {
        self.worker = worker; self.cancellation = cancellation; self.pid = pid
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [cancellation] _ in
            MainActor.assumeIsolated {
                cancellation.foregroundChanged(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [cancellation] note in
            if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid {
                cancellation.foregroundChanged(0)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [cancellation] _ in
            cancellation.cancel()
        })
    }
    isolated deinit { cancel() }
    private func refreshFocus() throws {
        cancellation.foregroundChanged(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        try cancellation.check(foreground: pid)
    }
    static func capture() throws -> (AXDictationEditor, DictationEditorSnapshot) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw DictationTargetError.unavailable }
        let cancellation = DictationDeliveryCancellation(foreground: front.processIdentifier)
        let state = try DictationAXState.capture(pid: front.processIdentifier, cancellation: cancellation)
        let snapshot = try state.snapshot()
        let worker = DictationAXWorker(state: state)
        let editor = AXDictationEditor(worker: worker, cancellation: cancellation, pid: front.processIdentifier)
        try editor.refreshFocus()
        return (editor, snapshot)
    }
    func validateFocus() async throws { try refreshFocus(); try await worker.validateFocus(); try refreshFocus() }
    func compositionCaret(at offset: Int) async throws -> CGRect {
        try refreshFocus()
        let bounds = try await worker.caret(at: offset); try refreshFocus()
        guard let top = NSScreen.screens.first?.frame.maxY else { throw DictationTargetError.unavailable }
        // Accessibility uses the primary display's top left; IMK's NSRect uses AppKit screen coordinates.
        return CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
    }
    func snapshot() async throws -> DictationEditorSnapshot {
        try refreshFocus()
        let value = try await worker.snapshot()
        try refreshFocus()
        return value
    }
    func insert(_ text: String, replacing snapshot: DictationEditorSnapshot) async throws {
        try refreshFocus(); try await worker.insert(text, replacing: snapshot)
    }
    func cancel() {
        cancellation.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}

private actor DictationAXWorker {
    private let state: DictationAXState
    init(state: sending DictationAXState) { self.state = state }
    func validateFocus() throws { try state.validateFocus() }
    func snapshot() throws -> DictationEditorSnapshot { try state.snapshot() }
    func caret(at offset: Int) throws -> CGRect { try state.caret(at: offset) }
    func insert(_ text: String, replacing snapshot: DictationEditorSnapshot) throws { try state.insert(text, replacing: snapshot) }
}

private final class DictationAXState {
    private let pid: pid_t
    private let application: AXUIElement
    private let element: AXUIElement
    private let events: CGEventSource
    private let cancellation: DictationDeliveryCancellation

    static func capture(pid: pid_t, cancellation: DictationDeliveryCancellation) throws -> sending DictationAXState {
        guard !IsSecureEventInputEnabled() else { throw DictationTargetError.secure }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let focused = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw DictationTargetError.unavailable
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        try requireNonSecure(element)
        try requireEditable(element)
        guard let source = CGEventSource(stateID: .privateState) else { throw DictationTargetError.unavailable }
        return DictationAXState(pid: pid, application: application, element: element,
                                events: source, cancellation: cancellation)
    }
    private init(pid: pid_t, application: AXUIElement, element: AXUIElement,
                 events: CGEventSource, cancellation: DictationDeliveryCancellation) {
        self.pid = pid; self.application = application; self.element = element
        self.events = events; self.cancellation = cancellation
    }
    func validateFocus() throws {
        try cancellation.check(foreground: pid)
        guard !IsSecureEventInputEnabled() else { throw DictationTargetError.secure }
        guard let focused = Self.attribute(application, kAXFocusedUIElementAttribute), CFEqual(focused, element) else {
            throw DictationTargetError.changed
        }
        try Self.requireNonSecure(element)
    }
    func caret(at offset: Int) throws -> CGRect {
        try validateFocus()
        var range = CFRange(location: offset, length: 0), rect = CGRect.null, raw: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetValue(raw as! AXValue, .cgRect, &rect),
              !rect.isNull, rect.height > 0 else { throw DictationTargetError.unavailable }
        return rect
    }
    func snapshot() throws -> DictationEditorSnapshot {
        try validateFocus()
        var copied: CFArray?
        let attributes = [kAXValueAttribute, kAXSelectedTextRangeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &copied) == .success,
              let values = copied as? [Any], values.count == 2,
              let value = values[0] as? String, value.utf16.count <= 196_608 else { throw DictationTargetError.unavailable }
        let raw = values[1] as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { throw DictationTargetError.unavailable }
        let ax = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= value.utf16.count, range.length <= value.utf16.count - range.location else {
            throw DictationTargetError.unavailable
        }
        return .init(value: value, selection: NSRange(location: range.location, length: range.length))
    }
    func insert(_ text: String, replacing expected: DictationEditorSnapshot) throws {
        let down = try DictationUnicodeInput.keyDown(text, source: events)
        guard let up = CGEvent(keyboardEventSource: events, virtualKey: 0, keyDown: false) else { throw DictationTargetError.unconfirmed }
        up.flags = []
        try Self.requireEditable(element)
        guard try snapshot().matches(expected) else { throw DictationTargetError.changed }
        try validateFocus()
        try Task.checkCancellation()
        try cancellation.withCurrent(foreground: pid) { down.postToPid(pid); up.postToPid(pid) }
    }
    private static func requireNonSecure(_ element: AXUIElement) throws {
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) {
        case .success:
            guard let role = subrole as? String else { throw DictationTargetError.unavailable }
            guard role != kAXSecureTextFieldSubrole as String else { throw DictationTargetError.secure }
        case .attributeUnsupported, .noValue: break // Ordinary fields need not have a subrole.
        default: throw DictationTargetError.unavailable
        }
    }
    private static func requireEditable(_ element: AXUIElement) throws {
        let role = attribute(element, kAXRoleAttribute) as? String
        // Selecting/copying a text range is possible even in read-only documents.
        guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(where: { $0 as String == role }),
              attribute(element, kAXEnabledAttribute) as? Bool != false,
              writable(element, kAXValueAttribute) || writable(element, kAXSelectedTextAttribute)
        else { throw DictationTargetError.unavailable }
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func writable(_ element: AXUIElement, _ name: String) -> Bool {
        var value: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }
}
