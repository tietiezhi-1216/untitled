import AppKit
import Carbon
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor
struct PriorityHotKeyTests {
    private var key: HotKey { HotKey(keyCode: 18, modifiers: UInt32(controlKey), key: "1") }

    @Test func exactChordsRepeatAndModifierFirstReleaseStayPaired() throws {
        let system = TapSystem()
        let monitor = system.makeMonitor()
        defer { monitor.shutdown() }
        var calls: [String] = []
        try monitor.register(key, onRelease: { calls.append("up") }) { calls.append("down") }
        #expect(!monitor.handle(.keyDown, try event(.keyDown, flags: [.maskControl, .maskShift])))
        #expect(!monitor.handle(.keyUp, try event(.keyUp)))
        #expect(monitor.handle(.keyDown, try event(.keyDown, flags: [.maskControl, .maskAlphaShift])))
        #expect(monitor.handle(.keyDown, try event(.keyDown, flags: [], repeating: true)))
        #expect(monitor.handle(.keyUp, try event(.keyUp, flags: [])))
        #expect(calls.isEmpty) // Business actions never run inside the tap callback.
        monitor.drain()
        #expect(calls == ["down", "up"])
        #expect(monitor.capturedCount == 0)
        #expect(system.starts == 1)
    }

    @Test func passThroughIsStickyAcrossIngressAndEligibilityChanges() throws {
        let system = TapSystem()
        var allowed = false, calls = 0
        let monitor = system.makeMonitor()
        defer { monitor.shutdown() }
        try monitor.register(key, allowed: { allowed }) { calls += 1 }
        let down = try event(.keyDown)
        #expect(!monitor.handle(.keyDown, down))
        allowed = true
        #expect(!monitor.handle(.keyDown, down)) // The second ingress sees the same stroke.
        #expect(!monitor.handle(.keyDown, try event(.keyDown, repeating: true)))
        #expect(!monitor.handle(.keyUp, try event(.keyUp)))
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        #expect(monitor.handle(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(calls == 1)
    }

    @Test func rebindCancelsQueuedStartsAndDrainsOldPhysicalStroke() throws {
        let system = TapSystem()
        let monitor = system.makeMonitor()
        defer { monitor.shutdown() }
        var old = 0, fresh = 0
        try monitor.register(key) { old += 1 }
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        monitor.clear()
        try monitor.register(key) { fresh += 1 }
        #expect(monitor.handle(.keyDown, try event(.keyDown, repeating: true)))
        #expect(monitor.handle(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(old == 0 && fresh == 0)
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        #expect(monitor.handle(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(fresh == 1)
        #expect(system.starts == 1)
    }

    @Test func cancellationIsNotAnOrdinaryReleaseAndCannotStartANewAction() throws {
        let system = TapSystem()
        let monitor = system.makeMonitor()
        defer { monitor.shutdown() }
        var presses = 0, releases = 0, cancellations = 0
        try monitor.register(key, onRelease: { releases += 1 }, onCancel: { cancellations += 1 }) { presses += 1 }
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        monitor.drain()
        monitor.clear()
        #expect(presses == 1 && releases == 0 && cancellations == 1)
        #expect(monitor.handle(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(releases == 0 && cancellations == 1)
        #expect(system.stops == 0)
    }

    @Test func rapidCompletedStrokesKeepFIFOAndReserveOwnedReleases() throws {
        let monitor = TapSystem.monitor()
        defer { monitor.shutdown() }
        var down = 0, up = 0
        try monitor.register(key, onRelease: { up += 1 }) { down += 1 }
        for _ in 0..<127 {
            #expect(monitor.handle(.keyDown, try event(.keyDown)))
            #expect(monitor.handle(.keyUp, try event(.keyUp)))
        }
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        let other = HotKey(keyCode: 19, modifiers: UInt32(controlKey), key: "2")
        try monitor.register(other) { Issue.record("Overflow stroke was dispatched") }
        #expect(!monitor.handle(.keyDown, try event(.keyDown, code: 19)))
        #expect(monitor.handle(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(down == 128 && up == 128 && monitor.capturedCount == 0)
    }

    @Test func injectedEventsAndSharingReplayNeverBecomeCommands() throws {
        let system = TapSystem()
        let monitor = system.makeMonitor(ignoreEvent: {
            $0.getIntegerValueField(.eventSourceUnixProcessID) != 0 || SharingInput.isHostShortcutReplay($0)
        })
        defer { monitor.shutdown() }
        try monitor.register(key) { Issue.record("Injected shortcut ran") }
        let injected = try event(.keyDown)
        injected.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        #expect(!monitor.handle(.keyDown, injected))
        for marker: Int64 in [SharingInput.replayMarker, 0x554E_0000_0000_0001, 0x554C_0000_0000_0001, 0x554F_0000_0000_0001] {
            let replay = try event(.keyDown)
            replay.setIntegerValueField(.eventSourceUserData, value: marker)
            #expect(!monitor.handle(.keyDown, replay))
        }
        #expect(monitor.capturedCount == 0)
    }

    @Test func missingAuthorizationNeverCreatesATapAndDuplicateBindingsAreRejected() throws {
        let system = TapSystem()
        system.authorized = false
        let monitor = system.makeMonitor()
        defer { monitor.shutdown() }
        #expect(throws: HostPermissionError.self) { try monitor.register(key) {} }
        #expect(system.starts == 0)
        system.authorized = true
        try monitor.register(key) {}
        #expect(throws: PluginError.self) { try monitor.register(key) {} }
        #expect(system.starts == 1)
    }

    @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func disabledTapDefersTeardownAndReleasesExactlyOnce(type: CGEventType) async throws {
        let system = TapSystem()
        var releases = 0, failures = 0
        let monitor = system.makeMonitor(failed: { _ in failures += 1 })
        defer { monitor.shutdown() }
        try monitor.register(key, onRelease: { releases += 1 }) {}
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        monitor.drain()
        #expect(!monitor.handle(type, try event(.keyDown)))
        #expect(releases == 0 && system.stops == 0)
        try await settle()
        #expect(releases == 1 && failures == 1 && system.stops == 1)
        #expect(system.starts == 1 && !monitor.isRunning)
    }

    @Test func permissionLossOrSecureInputCancelsHoldsOutsideTheCallback() async throws {
        for secure in [false, true] {
            let system = TapSystem()
            var releases = 0
            let monitor = system.makeMonitor()
            defer { monitor.shutdown() }
            try monitor.register(key, onRelease: { releases += 1 }) {}
            #expect(monitor.handle(.keyDown, try event(.keyDown)))
            monitor.drain()
            if secure { system.secure = true } else { system.authorized = false }
            #expect(!monitor.handle(.keyUp, try event(.keyUp)))
            #expect(releases == 0)
            try await settle()
            #expect(releases == 1 && !monitor.isRunning)
        }
    }

    @Test func missedUpEndsLogicalHoldButProtectsItsLateTerminalEvent() throws {
        let system = TapSystem()
        var releases = 0
        let monitor = system.makeMonitor()
        defer { monitor.shutdown() }
        try monitor.register(key, onRelease: { releases += 1 }) {}
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        monitor.drain()
        system.held.remove(18)
        monitor.checkHeldKeys()
        monitor.drain()
        #expect(releases == 1 && !monitor.hasOutstandingKeys)
        #expect(monitor.handle(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(releases == 1)
        #expect(!monitor.handle(.keyUp, try event(.keyUp)))
    }

    @Test func reentrantClearCannotDispatchTheRestOfAnOldBatch() throws {
        let monitor = TapSystem.monitor()
        defer { monitor.shutdown() }
        var presses = 0, releases = 0
        try monitor.register(key, onRelease: { releases += 1 }) { presses += 1; monitor.clear() }
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        #expect(monitor.handle(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(presses == 1 && releases == 1)
        #expect(!monitor.isRunning)
    }

    @Test(arguments: [false, true])
    func sharedIngressIsIndependentOfTapOrderAndNeverLatchesASampledDown(sharingFirst: Bool) throws {
        let input = SharingInput(tapReadyOverride: { true })
        // Simulate a hardware sample preceding delivery to the priority matcher.
        _ = input.handle(.keyDown, try event(.keyDown))
        #expect(!input.isNeutral)
        let system = TapSystem()
        let monitor = system.makeMonitor(noteOwnership: { code, _ in input.notePriorityShortcutOwnership(code) },
                                         ownershipChanged: { input.priorityShortcutOwnershipChanged() })
        defer { monitor.shutdown(); input.stop() }
        input.priorityOwnsKey = { monitor.ownsKey($0) }
        input.priorityHasOutstandingKeys = { monitor.hasOutstandingKeys }
        input.routeHostShortcut = { monitor.handle($0, $1) }
        var presses = 0
        try monitor.register(key) { presses += 1 }
        let route: (CGEventType, CGEvent) -> Bool = { type, event in
            if sharingFirst {
                if input.handle(type, event) { return true }
                return monitor.handle(type, event)
            }
            if monitor.handle(type, event) { return true }
            return input.handle(type, event)
        }
        #expect(route(.keyDown, try event(.keyDown)))
        #expect(!input.isNeutral)
        #expect(route(.keyUp, try event(.keyUp)))
        monitor.drain()
        #expect(presses == 1 && input.isNeutral)
    }

    @Test func sharingCannotCrossAnEdgeWhileAPriorityStrokeIsOwned() throws {
        let input = SharingInput(tapReadyOverride: { true })
        defer { input.stop() }
        var owned = true, requests = 0
        input.priorityHasOutstandingKeys = { owned }
        input.canSwitch = true
        input.requestControl = { _, _ in requests += 1 }
        let bounds = SharingInput.bounds
        let move = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: bounds.maxX - 1, y: bounds.midY), mouseButton: .left))
        move.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        move.setDoubleValueField(.mouseEventDeltaX, value: 20)
        #expect(!input.handle(.mouseMoved, move))
        #expect(requests == 0)
        owned = false
        #expect(input.isNeutral)
        #expect(!input.handle(.mouseMoved, move))
        #expect(requests == 1)
    }

    @Test func hostGrantDoesNotExpandPluginDeclarationsOrPromptOnLoad() throws {
        var requests = 0
        let driver = HostPermissionDriver(descriptor: .init(id: .accessibility, title: "AX", summary: "Test", symbol: "lock"),
            status: { .authorized }, request: { requests += 1 }, openSettings: {})
        let permissions = HostPermissionCenter(drivers: [driver])
        #expect(permissions.hasShortcutRoutingAccess())
        var manifest = manifest()
        manifest.permissions = []
        let plugin = InstalledPlugin(manifest: manifest, commands: [])
        #expect(throws: PluginError.self) { try permissions.require([.accessibility], for: plugin) }
        permissions.revealShortcutRoutingPermissions()
        #expect(permissions.pendingRequest?.pluginID == nil)
        #expect(permissions.pendingRequest?.source == .hostShortcutRouting)
        #expect(permissions.pendingRequest?.permissions == [.accessibility])
        #expect(requests == 0)
    }

    @Test func storePriorityModePreservesBindingsPausesAndStopsOnQuit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PriorityStore-" + UUID().uuidString)
        let domain = "PriorityStore-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let system = TapSystem()
        let permissions = HostPermissionCenter(drivers: [HostPermissionDriver(
            descriptor: .init(id: .accessibility, title: "AX", summary: "Test", symbol: "lock"),
            status: { .authorized }, request: { Issue.record("Unexpected OS prompt") }, openSettings: {})])
        let store = PluginStore(directory: directory, permissions: permissions, shortcutDefaults: defaults,
                                priorityHotKeyDriver: system.driver)
        #expect(!store.priorityHotKeysEnabled && system.starts == 0)
        try store.installManifest(manifest())
        store.setPriorityHotKeysEnabled(true)
        let command = PluginCommand(action: .showMainWindow, hotKey: key)
        try store.saveCommand(command, pluginID: manifest().id)
        let saved = try Data(contentsOf: directory.appendingPathComponent(manifest().id + ".json"))
        #expect(store.hotKeyErrors.isEmpty && system.starts == 1)
        store.setHotKeysPaused(true)
        #expect(system.stops == 1)
        store.setHotKeysPaused(false)
        #expect(system.starts == 2)
        defer { HotKeyRecordingSession.setRecording(false) }
        HotKeyRecordingSession.setRecording(true)
        #expect(system.stops == 2)
        HotKeyRecordingSession.setRecording(false)
        #expect(system.starts == 3)
        #expect(try Data(contentsOf: directory.appendingPathComponent(manifest().id + ".json")) == saved)
        #expect(await store.prepareForQuit())
        #expect(system.stops == 3)
        #expect(store.installed[0].commands == [command])
        var lateOpens = 0
        store.showMainWindow = { lateOpens += 1 }
        await store.execute(command, pluginID: manifest().id)
        #expect(lateOpens == 0)
    }

    @Test func secureInputRefusesCreationAndDeinitReleasesStartedHolds() async throws {
        let system = TapSystem()
        system.secure = true
        var monitor: PriorityHotKeyMonitor? = system.makeMonitor()
        #expect(throws: PluginError.self) { try monitor?.register(key) {} }
        #expect(system.starts == 0)
        system.secure = false
        var releases = 0
        try monitor?.register(key, onRelease: { releases += 1 }) {}
        #expect(monitor?.handle(.keyDown, try event(.keyDown)) == true)
        monitor?.drain()
        monitor = nil
        try await settle()
        #expect(releases == 1 && system.stops == 1)
    }

    @Test func missedTerminalDrainHasABoundedLifetimeAfterPause() async throws {
        let system = TapSystem()
        let monitor = system.makeMonitor()
        defer { monitor.shutdown() }
        try monitor.register(key) {}
        #expect(monitor.handle(.keyDown, try event(.keyDown)))
        monitor.drain()
        system.held.remove(18)
        monitor.checkHeldKeys()
        monitor.drain()
        monitor.clear()
        #expect(monitor.isRunning) // Keep the late-up tombstone briefly.
        system.clock = 2
        monitor.checkHeldKeys()
        try await settle()
        #expect(!monitor.isRunning && system.stops == 1)
    }

    @Test func tapCreationFailureIsVisibleAndIsolatedStoresDoNotInheritTheOptIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PriorityIsolation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        #expect(!store.priorityHotKeysEnabled)
        let system = TapSystem()
        system.startFails = true
        let monitor = system.makeMonitor()
        #expect(throws: PluginError.self) { try monitor.register(key) {} }
        #expect(!monitor.isRunning && system.stops == 0)
    }

    private func event(_ type: CGEventType, code: UInt16 = 18, flags: CGEventFlags = [.maskControl], repeating: Bool = false) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown))
        event.type = type; event.flags = flags
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return event
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
    private func manifest() -> PluginManifest {
        PluginManifest(schemaVersion: 1, id: "com.untitled.priority-tests", name: "Test", version: "1.0.0", summary: "Test", author: "Tests",
            repository: HostInfo.repository, minimumHostVersion: "0.2.0", actions: [.showMainWindow],
            templates: [CommandTemplate(id: "panel", title: "Panel", action: .showMainWindow)])
    }

    @MainActor private final class TapSystem {
        var starts = 0, stops = 0
        var authorized = true, secure = false, startFails = false
        var held: Set<UInt32> = [18]
        var clock: TimeInterval = 0
        var driver: PriorityHotKeyDriver {
            PriorityHotKeyDriver(start: { [self] _ in
                if startFails { throw PluginError.invalid("Fake tap unavailable") }
                starts += 1
                return { [self] in stops += 1 }
            }, secureInput: { [self] in secure }, keyIsDown: { [self] in held.contains($0) }, now: { [self] in clock })
        }
        static func monitor() -> PriorityHotKeyMonitor { TapSystem().makeMonitor() }
        func makeMonitor(ignoreEvent: @escaping (CGEvent) -> Bool = { $0.getIntegerValueField(.eventSourceUnixProcessID) != 0 },
                         noteOwnership: @escaping (UInt32, Bool) -> Void = { _, _ in }, ownershipChanged: @escaping () -> Void = {},
                         failed: @escaping (String) -> Void = { _ in }) -> PriorityHotKeyMonitor {
            PriorityHotKeyMonitor(driver: driver, accessAllowed: { [self] in authorized }, ignoreEvent: ignoreEvent,
                                  noteOwnership: noteOwnership, ownershipChanged: ownershipChanged, failed: failed)
        }
    }
}
