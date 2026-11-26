import Carbon
import Foundation

/// Suppress repeat-downs; clearing bindings releases only keys that actually started a gesture.
struct HotKeyPressState {
    private var down: Set<UInt32> = []
    mutating func transition(_ id: UInt32, pressed: Bool) -> Bool {
        if pressed { return down.insert(id).inserted }
        return down.remove(id) != nil
    }
    mutating func clear() -> Set<UInt32> { let previous = down; down.removeAll(); return previous }
}

@MainActor
final class HotKeyManager {
    /// Native Carbon remains the default. Tests can own registrations without
    /// reserving real system chords, including deterministic conflict failures.
    struct Driver {
        let register: (HotKey, @escaping @MainActor (Bool) -> Void) throws -> (@MainActor @Sendable () -> Void)
    }
    private let driver: Driver?
    private let resources = CarbonResources()
    private struct Callbacks { let press: () -> Void; let release: (() -> Void)?; let skipsSecureInput: Bool }
    private let secureInput: () -> Bool
    private var skippedSecurePresses = Set<UInt32>()
    private var callbacks: [UInt32: Callbacks] = [:]
    private var presses = HotKeyPressState()
    private var nextIdentifier: UInt32 = 0
    private var setupStatus: OSStatus = noErr

    init(driver: Driver? = nil, secureInput: (() -> Bool)? = nil) {
        self.driver=driver
        self.secureInput = secureInput ?? (driver == nil ? { IsSecureEventInputEnabled() } : { false })
        resources.owner = self
        guard driver == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        setupStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x554E544C else { return OSStatus(eventNotHandledErr) }
            let resources = Unmanaged<CarbonResources>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { resources.owner?.dispatch(identifier.id, pressed: pressed) }
            return noErr
        }, 2, &eventTypes, Unmanaged.passUnretained(resources).toOpaque(), &resources.eventHandler)
    }

    private func dispatch(_ identifier: UInt32, pressed: Bool) {
        guard let callback = callbacks[identifier], presses.transition(identifier, pressed: pressed) else { return }
        if pressed {
            // Carbon reports a registered shortcut, not text. Respect Secure Input
            // for unmodified typing keys and temporary workflow shortcuts.
            if callback.skipsSecureInput && secureInput() { skippedSecurePresses.insert(identifier); return }
            callback.press()
        } else if skippedSecurePresses.remove(identifier) == nil { callback.release?() }
    }

    func clear() {
        let releases = presses.clear().subtracting(skippedSecurePresses).compactMap { callbacks[$0]?.release }
        skippedSecurePresses.removeAll()
        resources.clearRegistrations()
        callbacks.removeAll()
        releases.forEach { $0() }
    }

    func register(_ hotKey: HotKey, onRelease: (() -> Void)? = nil, action: @escaping () -> Void) throws {
        _ = try registerBinding(hotKey, onRelease: onRelease, skipsSecureInput: !hotKey.supportsLegacyHosts, action: action)
    }

    /// A single chord owned by an active workflow, not a saved command. Removing it
    /// must not release another shortcut (e.g. the key still held for dictation).
    func registerScoped(_ hotKey: HotKey, action: @escaping () -> Void) throws -> () -> Void {
        guard !secureInput() else { throw PluginError.invalid("安全输入期间无法注册临时快捷键。") }
        let identifier = try registerBinding(hotKey, onRelease: nil, skipsSecureInput: true, action: action)
        return { [weak self] in
            guard let self, self.callbacks.removeValue(forKey: identifier) != nil else { return }
            _ = self.presses.transition(identifier, pressed: false)
            self.skippedSecurePresses.remove(identifier)
            self.resources.unregister(identifier)
        }
    }

    private func registerBinding(_ hotKey: HotKey, onRelease: (() -> Void)?, skipsSecureInput: Bool,
                                 action: @escaping () -> Void) throws -> UInt32 {
        try hotKey.validate()
        guard !hotKey.isStandaloneModifier else { throw PluginError.invalid("独立修饰键需使用专用通道。") }
        guard let code = hotKey.keyCode else { throw PluginError.invalid("鼠标侧键不能注册为键盘按键。") }
        guard setupStatus == noErr else { throw PluginError.invalid("无法监听快捷键（\(setupStatus)）。") }
        nextIdentifier &+= 1
        if nextIdentifier == 0 { nextIdentifier = 1 }
        let identifier = nextIdentifier
        let callback = Callbacks(press: action, release: onRelease, skipsSecureInput: skipsSecureInput)
        if let driver {
            let stop = try driver.register(hotKey) { [weak self] pressed in self?.dispatch(identifier, pressed: pressed) }
            resources.driverStops[identifier] = stop
            callbacks[identifier] = callback
            return identifier
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(code, hotKey.modifiers,
                                        EventHotKeyID(signature: 0x554E544C, id: identifier),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            throw PluginError.invalid("\(hotKey.display) 无法注册，可能已被系统或其他应用占用（\(status)）。")
        }
        resources.references[identifier] = reference
        callbacks[identifier] = callback
        return identifier
    }

    deinit {
        let resources = resources
        if Thread.isMainThread {
            MainActor.assumeIsolated { resources.invalidate() }
        } else {
            Task { @MainActor in resources.invalidate() }
        }
    }

    // Carbon 句柄仅在主线程使用；Sendable 包装用于将析构清理移交回主线程。
    private final class CarbonResources: @unchecked Sendable {
        var eventHandler: EventHandlerRef?
        var references: [UInt32: EventHotKeyRef] = [:]
        var driverStops: [UInt32: @MainActor @Sendable () -> Void] = [:]
        @MainActor weak var owner: HotKeyManager?

        @MainActor func unregister(_ identifier: UInt32) {
            if let reference = references.removeValue(forKey: identifier) { UnregisterEventHotKey(reference) }
            driverStops.removeValue(forKey: identifier)?()
        }

        @MainActor func clearRegistrations() {
            references.values.forEach { UnregisterEventHotKey($0) }; references.removeAll()
            let stops = driverStops; driverStops.removeAll(); stops.values.forEach { $0() }
        }
        @MainActor func invalidate() {
            owner = nil
            clearRegistrations()
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
        }
    }
}
