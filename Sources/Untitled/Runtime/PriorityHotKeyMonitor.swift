import AppKit
import Carbon

@MainActor struct PriorityHotKeyDriver {
    let start: (@escaping @MainActor (CGEventType, CGEvent) -> Bool) throws -> (@MainActor @Sendable () -> Void)
    let secureInput: () -> Bool
    let keyIsDown: (UInt32) -> Bool
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static var unavailable: Self {
        Self(start: { _ in throw PluginError.invalid("隔离环境需要显式提供快捷键测试驱动。") },
             secureInput: { false }, keyIsDown: { _ in false })
    }
    static var native: Self {
        Self(start: { handler in
            let tap = NativePriorityHotKeyTap(handler: handler)
            try tap.start()
            return { tap.stop() }
        }, secureInput: { IsSecureEventInputEnabled() }, keyIsDown: {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        })
    }
}

/// Host routing only: no characters are read, logged, or delivered to plugins.
/// One matcher for both native and sharing ingress; <=128 key slots, <=256 queued
/// transitions. No idle polling. A 250ms watchdog runs only for outstanding strokes.
@MainActor final class PriorityHotKeyMonitor {
    private struct Chord: Hashable { let code: UInt32; let modifiers: UInt32 }
    private struct Binding {
        let allowed: () -> Bool
        let press: () -> Void
        let release: (() -> Void)?
        let cancel: (() -> Void)?
    }
    @MainActor private final class Invocations {
        var bindings: [UInt64: Binding] = [:]
        func cancelAll() {
            let releases = bindings.values.compactMap(\.cancel)
            bindings.removeAll()
            releases.forEach { $0() }
        }
    }
    private struct Stroke { let token: UInt64; let epoch: UInt64; let binding: Binding }
    private struct Transition { let stroke: Stroke; let pressed: Bool }
    private let driver: PriorityHotKeyDriver
    private let accessAllowed: () -> Bool
    private let ignoreEvent: (CGEvent) -> Bool
    // Synchronous bookkeeping ONLY; no business callbacks or input-source changes.
    private let noteOwnership: (UInt32, Bool) -> Void
    private let ownershipChanged: () -> Void
    private let failed: (String) -> Void
    private var cleanup: (@MainActor @Sendable () -> Void)?
    private var bindings: [Chord: Binding] = [:]
    private var captured: [UInt32: Stroke] = [:]
    private var passedThrough: Set<UInt32> = []
    // After a missed up, protect an in-flight terminal event for at most one second.
    // Force loss of OS access cannot guarantee downstream physical event balance.
    private var draining: [UInt32: TimeInterval] = [:]
    private let invocations = Invocations()
    private var pending: [Transition] = []
    private var nextToken: UInt64 = 0
    private var revision: UInt64 = 0
    private var drainScheduled = false
    private var ownershipNotificationScheduled = false
    private var healthTask: Task<Void, Never>?
    private(set) var isRunning = false
    var bindingCount: Int { bindings.count }
    var capturedCount: Int { captured.count }
    var hasOutstandingKeys: Bool { !captured.isEmpty }
    func ownsKey(_ code: UInt32) -> Bool { captured[code] != nil }

    init(driver: PriorityHotKeyDriver = .native, accessAllowed: @escaping () -> Bool,
         ignoreEvent: @escaping (CGEvent) -> Bool = { $0.getIntegerValueField(.eventSourceUnixProcessID) != 0 },
         noteOwnership: @escaping (UInt32, Bool) -> Void = { _, _ in },
         ownershipChanged: @escaping () -> Void = {}, failed: @escaping (String) -> Void = { _ in }) {
        self.driver = driver; self.accessAllowed = accessAllowed; self.ignoreEvent = ignoreEvent
        self.noteOwnership = noteOwnership; self.ownershipChanged = ownershipChanged; self.failed = failed
    }

    func register(_ key: HotKey, allowed: @escaping () -> Bool = { true },
                  onRelease: (() -> Void)? = nil, onCancel: (() -> Void)? = nil, action: @escaping () -> Void) throws {
        try key.validate()
        let chord = Chord(code: key.keyCode, modifiers: key.modifiers)
        guard bindings[chord] == nil else { throw PluginError.invalid("这个快捷键已绑定到其他操作。") }
        guard accessAllowed() else { throw HostPermissionError.missing }
        guard !driver.secureInput() else { throw PluginError.invalid("系统正在安全输入，优先快捷键暂不可用；退出安全输入后重试。") }
        if !isRunning, cleanup != nil { shutdown() }
        if cleanup == nil {
            cleanup = try driver.start { [weak self] type, event in self?.handle(type, event) ?? false }
            isRunning = true
        }
        bindings[chord] = Binding(allowed: allowed, press: action, release: onRelease, cancel: onCancel ?? onRelease)
    }

    /// Cancel logical actions now, retain physical ownership until its release drains.
    func clear() {
        revision &+= 1
        let releases = invocations.bindings.values.compactMap(\.cancel)
        bindings.removeAll(); invocations.bindings.removeAll(); pending.removeAll()
        drainScheduled = false
        if captured.isEmpty && draining.isEmpty { stopNativeTap() }
        releases.forEach { $0() }
    }
    func shutdown() {
        let codes = Array(captured.keys)
        captured.removeAll(); draining.removeAll(); passedThrough.removeAll()
        codes.forEach { noteOwnership($0, false) }
        notifyOwnershipChanged()
        clear()
    }
    private func stopNativeTap() {
        let stop = cleanup
        cleanup = nil; isRunning = false
        healthTask?.cancel(); healthTask = nil
        stop?()
    }
    private func stopWhenDrained() {
        guard captured.isEmpty && draining.isEmpty else { return }
        healthTask?.cancel(); healthTask = nil
        guard bindings.isEmpty else { return }
        let epoch = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == epoch, self.bindings.isEmpty,
                  self.captured.isEmpty, self.draining.isEmpty else { return }
            self.stopNativeTap()
        }
    }
    private func notifyOwnershipChanged() {
        guard !ownershipNotificationScheduled else { return }
        ownershipNotificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ownershipNotificationScheduled = false
            self.ownershipChanged()
        }
    }

    /// No event is posted. true means discard this event at the calling ingress.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard isRunning else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            fail("优先快捷键监听已被系统停用，请在应用设置中重试。")
            return false
        }
        guard type == .keyDown || type == .keyUp, !ignoreEvent(event) else { return false }
        let rawCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard (0..<128).contains(rawCode) else { return false }
        let code = UInt32(rawCode)
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if draining[code] != nil {
            guard accessAllowed(), !driver.secureInput() else {
                fail("优先快捷键已暂停：辅助功能权限不可用或进入安全输入模式。")
                return false
            }
            if type == .keyUp { draining.removeValue(forKey: code); stopWhenDrained(); return true }
            if repeating { return true }
            draining.removeValue(forKey: code) // A genuinely new physical stroke.
        }
        if let stroke = captured[code] {
            guard accessAllowed(), !driver.secureInput() else {
                fail("优先快捷键已暂停：辅助功能权限不可用或进入安全输入模式。")
                return false
            }
            if type == .keyUp {
                captured.removeValue(forKey: code)
                noteOwnership(code, false); notifyOwnershipChanged()
                if stroke.epoch == revision { enqueue(stroke, pressed: false) }
                stopWhenDrained()
            }
            return true // Exact pairing persists after modifiers or bindings change.
        }
        if type == .keyUp { passedThrough.remove(code); return false }
        // Latch pass-through too: another ingress must not capture this same down
        // after sharing/permission/command eligibility changes between callbacks.
        guard !passedThrough.contains(code) else { return false }
        let chord = Chord(code: code, modifiers: Self.modifiers(event.flags))
        guard !repeating, let binding = bindings[chord], binding.allowed() else {
            passedThrough.insert(code)
            return false
        }
        guard accessAllowed(), !driver.secureInput() else {
            passedThrough.insert(code)
            fail("优先快捷键已暂停：辅助功能权限不可用或进入安全输入模式。")
            return false
        }
        // Reserve one completion per outstanding down; an owned release cannot overflow.
        guard pending.count + captured.count + 2 <= 256 else { passedThrough.insert(code); return false }
        nextToken &+= 1
        let stroke = Stroke(token: nextToken, epoch: revision, binding: binding)
        captured[code] = stroke
        noteOwnership(code, true); notifyOwnershipChanged()
        watchOutstandingKeys()
        enqueue(stroke, pressed: true)
        return true
    }
    private func enqueue(_ stroke: Stroke, pressed: Bool) {
        precondition(pending.count < 256)
        pending.append(Transition(stroke: stroke, pressed: pressed))
        guard !drainScheduled else { return }
        drainScheduled = true
        let epoch = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == epoch else { return }
            self.drain()
        }
    }
    func drain() {
        drainScheduled = false
        let transitions = pending
        pending.removeAll(keepingCapacity: true)
        let epoch = revision
        for transition in transitions {
            guard revision == epoch, isRunning else { break }
            let stroke = transition.stroke
            if transition.pressed {
                guard accessAllowed(), !driver.secureInput(), stroke.binding.allowed() else { continue }
                invocations.bindings[stroke.token] = stroke.binding
                stroke.binding.press()
            } else {
                let binding = invocations.bindings.removeValue(forKey: stroke.token)
                binding?.release?()
            }
        }
    }
    private func watchOutstandingKeys() {
        guard healthTask == nil else { return }
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                self.checkHeldKeys()
                if self.captured.isEmpty && self.draining.isEmpty { self.healthTask = nil; return }
            }
        }
    }
    func checkHeldKeys() {
        guard isRunning else { return }
        guard accessAllowed(), !driver.secureInput() else {
            fail("优先快捷键已暂停：辅助功能权限不可用或进入安全输入模式。")
            return
        }
        for (code, stroke) in captured where !driver.keyIsDown(code) {
            captured.removeValue(forKey: code)
            draining[code] = driver.now() + 1
            noteOwnership(code, false); notifyOwnershipChanged()
            if stroke.epoch == revision { enqueue(stroke, pressed: false) }
        }
        let expired = draining.filter { $0.value <= driver.now() }.map(\.key)
        expired.forEach { draining.removeValue(forKey: $0) }
        stopWhenDrained()
    }
    private func fail(_ message: String) {
        isRunning = false; revision &+= 1
        let epoch = revision
        // Teardown, business releases and backend recovery run after the tap returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == epoch else { return }
            self.shutdown()
            self.failed(message)
        }
    }
    static func modifiers(_ flags: CGEventFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.maskControl) { value |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { value |= UInt32(optionKey) }
        if flags.contains(.maskShift) { value |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { value |= UInt32(cmdKey) }
        return value
    }
    deinit {
        healthTask?.cancel()
        let stop = cleanup
        let invocations = invocations
        Task { @MainActor in invocations.cancelAll(); stop?() }
    }
}

@MainActor private final class NativePriorityHotKeyTap {
    let handler: @MainActor (CGEventType, CGEvent) -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    init(handler: @escaping @MainActor (CGEventType, CGEvent) -> Bool) { self.handler = handler }
    func start() throws {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let suppress = MainActor.assumeIsolated {
                    Unmanaged<NativePriorityHotKeyTap>.fromOpaque(pointer).takeUnretainedValue().handler(type, event)
                }
                return suppress ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw PluginError.invalid("无法启动优先快捷键，请检查辅助功能权限后重试。")
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw PluginError.invalid("无法创建优先快捷键事件通道，请关闭后重试。")
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
}
