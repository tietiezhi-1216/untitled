import Carbon
import UntitledPluginSDK
import CoreGraphics
import Foundation

/// A standalone modifier is observed through flagsChanged only. Ordinary key and
/// mouse events remain untouched; they are used solely as hardware evidence that
/// a modifier became a chord.
@MainActor final class ModifierShortcutMonitor {
    static let holdDelay = Duration.milliseconds(200)

    private struct Binding {
        let allowed: () -> Bool
        let press: () -> Void
        let release: (() -> Void)?
        let cancel: (() -> Void)?
    }
    private struct Registration {
        let code: UInt32
        let binding: Binding
        var latched = false
        var active = false
        var downTime: TimeInterval?
    }
    private struct PendingEnd {
        let code: UInt32
        let binding: Binding
        let valid: Bool
    }
    private struct PendingTap {
        let binding: Binding
    }

    private let driver: PriorityHotKeyDriver
    private let access: () -> Bool
    private let ignoreEvent: (CGEvent) -> Bool
    private let failed: (String) -> Void
    private var registrations: [UInt32: Registration] = [:]
    private var stop: (@MainActor @Sendable () -> Void)?
    private var watch: Task<Void, Never>?
    private var faulted = false
    private var generation: UInt64 = 0
    private var pendingEnds: [PendingEnd] = []
    private var pendingTaps: [PendingTap] = []
    private var drainScheduled = false

    var isRunning: Bool { stop != nil && !faulted }
    var hasOutstandingKeys: Bool {
        registrations.values.contains { $0.downTime != nil } || !pendingEnds.isEmpty
    }

    init(driver: PriorityHotKeyDriver, access: @escaping () -> Bool,
         ignoreEvent: @escaping (CGEvent) -> Bool = { _ in false }, failed: @escaping (String) -> Void) {
        self.driver = driver
        self.access = access
        self.ignoreEvent = ignoreEvent
        self.failed = failed
    }

    isolated deinit { clear() }

    func register(_ key: HotKey, allowed: @escaping () -> Bool, onRelease: (() -> Void)?,
                  onCancel: (() -> Void)?, action: @escaping () -> Void) throws {
        try key.validate()
        guard let code = key.standaloneModifierCode, registrations[code] == nil else {
            throw PluginError.invalid("独立修饰键已占用或绑定无效。")
        }
        guard access() else {
            throw PluginError.invalid("\(key.display)需要辅助功能权限；请在菜单栏「快捷键」中授权后重试。")
        }
        guard !driver.secureInput() else {
            throw PluginError.invalid("系统正在安全输入，\(key.display)暂不可用。")
        }
        if stop == nil {
            stop = try driver.start { [weak self] type, event in
                self?.observe(type, event)
                // A standalone modifier must continue to reach macOS and the foreground app.
                return false
            }
        }
        registrations[code] = Registration(code: code, binding: Binding(
            allowed: allowed, press: action, release: onRelease, cancel: onCancel ?? onRelease),
            latched: driver.keyIsDown(code))
    }

    func clear() {
        let pendingCodes = Set(pendingEnds.map(\.code))
        let cancellations = registrations.values
            .filter { $0.active || pendingCodes.contains($0.code) }
            .compactMap(\.binding.cancel)
        generation &+= 1
        watch?.cancel(); watch = nil
        registrations.removeAll()
        pendingEnds.removeAll(); pendingTaps.removeAll(); drainScheduled = false
        let cleanup = stop; stop = nil; faulted = false
        cleanup?()
        cancellations.forEach { $0() }
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        guard isRunning else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { fail(); return }
        guard type == .flagsChanged,
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              !ignoreEvent(event) else { return }
        let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard registrations[code] != nil else {
            // Any other modifier transition turns a solo candidate into a chord.
            for candidate in registrations.keys where registrations[candidate]?.downTime != nil {
                end(candidate, valid: false)
            }
            return
        }
        guard access(), !driver.secureInput() else { fail(); return }
        guard var registration = registrations[code] else { return }
        let down = modifierIsDown(code: code, flags: event.flags, wasLatched: registration.latched)
        if down {
            guard !registration.latched else { return }
            registration.latched = true
            registrations[code] = registration
            guard modifierIsAlone(code: code, flags: event.flags), registration.binding.allowed() else { return }
            let now = driver.now()
            let timestamp = Double(event.timestamp) / 1_000_000_000
            let start = timestamp > 0 && timestamp <= now && now - timestamp <= 2 ? timestamp : now
            registration.downTime = start
            registrations[code] = registration
            startWatch()
        } else {
            registration.latched = false
            registrations[code] = registration
            guard let downTime = registration.downTime else { return }
            end(code, valid: !driver.chordSince(downTime) && registration.binding.allowed())
        }
    }

    private func modifierIsDown(code: UInt32, flags: CGEventFlags, wasLatched: Bool) -> Bool {
        if code == UInt32(kVK_RightCommand) {
            return HotKey.rightCommandDown(flags, fallback: { driver.keyIsDown(code) })
        }
        // Control has no reliable left/right bit in CGEventFlags. The first edge
        // is identified by the aggregate flag; after latching, HID state resolves
        // the right-Control release even when left Control remains held.
        return wasLatched ? driver.keyIsDown(code) : flags.contains(.maskControl)
    }

    private func modifierIsAlone(code: UInt32, flags: CGEventFlags) -> Bool {
        if code == UInt32(kVK_RightCommand) {
            return HotKey.rightCommandAlone(flags) && !driver.keyIsDown(UInt32(kVK_Command))
        }
        return HotKey.rightControlAlone(flags, leftControlDown: driver.keyIsDown(UInt32(kVK_Control)))
    }

    private func modifierRemainsAlone(_ code: UInt32) -> Bool {
        if code == UInt32(kVK_RightCommand) {
            return !driver.keyIsDown(UInt32(kVK_Command))
        }
        return !driver.keyIsDown(UInt32(kVK_Control))
    }

    private func startWatch() {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.holdDelay)
                while !Task.isCancelled {
                    guard let self, self.checkStroke() else { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {}
        }
    }

    /// Runs outside the tap callback and starts hold bindings only after the short
    /// delay. Toggle bindings remain a release-time action.
    @discardableResult func checkStroke() -> Bool {
        let candidates = registrations.values.compactMap { $0.downTime == nil ? nil : $0.code }
        for code in candidates { checkStroke(code) }
        if candidates.isEmpty { watch?.cancel(); watch = nil }
        return registrations.values.contains { $0.downTime != nil }
    }

    private func checkStroke(_ code: UInt32) {
        guard isRunning, let registration = registrations[code], let downTime = registration.downTime else { return }
        guard access(), !driver.secureInput() else { fail(); return }
        guard driver.keyIsDown(code) else {
            end(code, valid: registration.active && !driver.chordSince(downTime))
            return
        }
        guard modifierRemainsAlone(code), !driver.chordSince(downTime), registration.binding.allowed() else {
            end(code, valid: false)
            return
        }
        guard !registration.active, registration.binding.release != nil,
              driver.now() - downTime >= 0.2 else { return }
        let token = generation
        drain()
        guard generation == token, registrations[code]?.downTime == downTime, isRunning else { return }
        guard var current = registrations[code] else { return }
        current.active = true
        registrations[code] = current
        current.binding.press()
    }

    private func end(_ code: UInt32, valid: Bool) {
        guard var registration = registrations[code], registration.downTime != nil else { return }
        registration.downTime = nil
        let wasActive = registration.active
        registration.active = false
        registrations[code] = registration
        if wasActive {
            pendingEnds.append(PendingEnd(code: code, binding: registration.binding, valid: valid))
        } else if valid, registration.binding.release == nil {
            pendingTaps.append(PendingTap(binding: registration.binding))
        }
        if !registrations.values.contains(where: { $0.downTime != nil }) {
            watch?.cancel(); watch = nil
        }
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard !drainScheduled, !pendingEnds.isEmpty || !pendingTaps.isEmpty else { return }
        drainScheduled = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.drain()
        }
    }

    func drain() {
        drainScheduled = false
        guard !faulted else { return }
        let ends = pendingEnds
        let taps = pendingTaps
        let token = generation
        pendingEnds.removeAll(); pendingTaps.removeAll()
        for pending in ends {
            let valid = pending.valid && access() && !driver.secureInput() && pending.binding.allowed()
            (valid ? pending.binding.release : pending.binding.cancel)?()
        }
        for pending in taps {
            guard token == generation, access(), !driver.secureInput(), pending.binding.allowed() else { break }
            pending.binding.press()
        }
    }

    private func fail() {
        guard !faulted else { return }
        faulted = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.clear()
            self.failed("独立修饰键已暂停，请检查辅助功能权限或退出安全输入后重试。")
        }
    }
}
