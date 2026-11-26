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

    @Test func toggleSideButtonPassesPointerDragAfterItsDownEdge() throws {
        let system = TapSystem()
        let monitor = PriorityHotKeyMonitor(driver: system.driver, channel: .sideButtons, accessAllowed: { system.authorized }, failed: { _ in })
        var down = 0
        try monitor.register(HotKey(mouseButton: 3), onRelease: nil) { down += 1 }
        func mouse(_ type: CGEventType) throws -> Bool {
            let event = try #require(CGEvent(source: nil))
            event.type = type; event.flags = []
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            return monitor.handle(type, event)
        }
        #expect(try mouse(.otherMouseDown))
        monitor.drain()
        #expect(down == 1)
        #expect(try !mouse(.otherMouseDragged))
        #expect(try mouse(.otherMouseUp))
        #expect(!monitor.hasOutstandingKeys)
        monitor.shutdown()
    }

    @Test func sideButtonChannelMatchesOnlyOwnedPhysicalGesturesAndBalancesRebinding() throws {
        let system = TapSystem()
        let monitor = PriorityHotKeyMonitor(driver: system.driver, channel: .sideButtons, accessAllowed: { system.authorized }, failed: { _ in })
        var down = 0, up = 0
        let key = HotKey(mouseButton: 3, modifiers: UInt32(optionKey))
        try monitor.register(key, allowed: { true }, onRelease: { up += 1 }) { down += 1 }
        func mouse(_ type: CGEventType, _ button: Int64 = 3, _ flags: CGEventFlags = [.maskAlternate], injected: Bool = false) throws -> Bool {
            let event = try #require(CGEvent(source: nil))
            event.type = type; event.flags = flags
            event.setIntegerValueField(.eventSourceUnixProcessID, value: injected ? 99 : 0)
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            return monitor.handle(type, event)
        }
        #expect(ShortcutChannel.sideButtons.events == [.otherMouseDown, .otherMouseUp, .otherMouseDragged])
        #expect(try !mouse(.otherMouseDown, 2) && !mouse(.otherMouseDown, 4))
        #expect(try !mouse(.leftMouseDown) && !mouse(.scrollWheel) && !mouse(.keyDown))
        #expect(try !mouse(.otherMouseDown, injected: true))
        #expect(try !mouse(.otherMouseDown, 3, [])); #expect(try !mouse(.otherMouseUp))
        #expect(try mouse(.otherMouseDown)); #expect(try mouse(.otherMouseDown)); #expect(try mouse(.otherMouseDragged, 3, []))
        monitor.drain(); #expect(down == 1 && up == 0)
        #expect(try mouse(.otherMouseUp, 3, [])); monitor.drain()
        #expect(up == 1 && !monitor.hasOutstandingKeys)
        #expect(try mouse(.otherMouseDown)); monitor.drain(); monitor.clear()
        #expect(down == 2 && up == 2)
        #expect(try mouse(.otherMouseUp)); monitor.drain(); #expect(up == 2)
        monitor.shutdown()
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

    @Test func soloRightCommandNeverConsumesChordsAndPairsOnlyAnEligibleHold() throws {
        let driver = ModifierFixture(), monitor = driver.monitor()
        var trace: [String] = []
        try monitor.register(.rightCommand, allowed: { driver.allowed }, onRelease: { trace.append("up") },
                             onCancel: { trace.append("cancel") }) { trace.append("down") }
        defer { monitor.clear() }
        #expect(ShortcutChannel.modifierOnly.events == [.flagsChanged])
        try driver.right(true); try driver.right(false); monitor.drain()
        #expect(trace.isEmpty) // A quick right tap.
        try driver.right(true); driver.chord = true; driver.tick(monitor); try driver.right(false); monitor.drain()
        #expect(trace.isEmpty) // A Cmd+C consumed upstream is still a chord.
        driver.chord = false; try driver.right(true); try driver.right(true); driver.tick(monitor); driver.tick(monitor)
        try driver.right(false); monitor.drain()
        #expect(trace == ["down","up"])
        try driver.right(true); driver.tick(monitor); driver.chord = true; driver.tick(monitor)
        try driver.right(false); monitor.drain()
        #expect(trace == ["down","up","down","cancel"]) // Never finish a late chord as a successful hold.
        driver.chord = false; driver.left = true
        try driver.flags(55, [.maskCommand, .init(rawValue: 8)])
        try driver.right(true); driver.tick(monitor); try driver.right(false); monitor.drain()
        #expect(trace.count == 4) // Releasing right while left is held leaves aggregate Command set.
        driver.left = false; driver.allowed = false; try driver.right(true); driver.allowed = true
        driver.tick(monitor); try driver.right(false); monitor.drain()
        #expect(trace.count == 4) // A remote/ineligible start cannot be adopted.
        try driver.right(true); driver.tick(monitor); driver.held = false; driver.tick(monitor); monitor.drain()
        try driver.right(false); monitor.drain()
        #expect(trace.suffix(2) == ["down","up"] && trace.count == 6)
    }

    @Test func standaloneRightControlHoldAndChordCancellationPairEdges() throws {
        let system = RightControlFixture()
        let monitor = ModifierShortcutMonitor(driver: system.driver, access: { true }, failed: { _ in })
        var starts = 0, releases = 0, cancels = 0
        try monitor.register(.rightControl, allowed: { true }, onRelease: { releases += 1 }, onCancel: { cancels += 1 }) { starts += 1 }
        try system.edge(true); system.clock += 0.25; monitor.checkStroke()
        #expect(starts == 1)
        try system.edge(false); monitor.drain()
        #expect(releases == 1 && cancels == 0)
        system.chord = false; try system.edge(true); system.clock += 0.25; monitor.checkStroke()
        #expect(starts == 2)
        system.chord = true; try system.edge(false); monitor.drain()
        #expect(releases == 1 && cancels == 1)
    }

    @Test func standaloneModifierHandlesTapBindingsPermissionLossAndLateCallbacks() async throws {
        let f = ModifierFixture(), m = f.monitor()
        var taps = 0, starts = 0, cancels = 0, releases = 0
        f.trusted = false
        #expect(throws: PluginError.self) { try m.register(.rightCommand, allowed: { true }, onRelease: nil, onCancel: nil) {} }
        #expect(f.starts == 0)
        f.trusted = true
        try m.register(.rightCommand, allowed: { true }, onRelease: nil, onCancel: nil) { taps += 1 }
        try f.flags(54, [.maskCommand, .init(rawValue: 16)], injected: true); try f.right(false); m.drain()
        try f.right(true); try f.right(false); m.drain()
        #expect(taps == 1)
        try f.right(true); try f.right(false); m.clear(); m.drain(); #expect(taps == 1)
        try m.register(.rightCommand, allowed: { true }, onRelease: { releases += 1 }, onCancel: { cancels += 1 }) { starts += 1 }
        try f.right(true); f.tick(m); f.secure = true; f.tick(m)
        try await settle()
        #expect(starts == 1 && cancels == 1 && releases == 0 && !m.isRunning && f.stops == 2)
        f.secure = false
        try m.register(.rightCommand, allowed: { true }, onRelease: { releases += 1 }, onCancel: { cancels += 1 }) { starts += 1 }
        try f.right(true); f.tick(m); try f.right(false); m.drain() // Held across rebind.
        #expect(starts == 1 && releases == 0)
        try f.right(true); f.tick(m); try f.right(false); m.clear(); m.drain()
        #expect(starts == 2 && releases == 0 && cancels == 2)
    }

    @MainActor private final class RightControlFixture {
        var handler: (@MainActor (CGEventType, CGEvent) -> Bool)?
        var held = false, chord = false, clock = 10.0
        var driver: PriorityHotKeyDriver {
            .init(start: { [self] h in handler = h; return { [self] in handler = nil } },
                  secureInput: { false }, keyIsDown: { [self] code in code == UInt32(kVK_RightControl) && held },
                  now: { self.clock }, chordSince: { [self] _ in self.chord })
        }
        func edge(_ down: Bool) throws {
            held = down
            let e = try #require(CGEvent(source: nil)); e.type = .flagsChanged; e.flags = down ? [.maskControl] : []
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_RightControl))
            e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            #expect(handler?(.flagsChanged, e) == false)
        }
    }

    @MainActor private final class ModifierFixture {
        var handler: (@MainActor (CGEventType, CGEvent) -> Bool)?
        var trusted = true, secure = false, allowed = true, chord = false, held = false, left = false
        var clock = 10.0, starts = 0, stops = 0
        func monitor() -> ModifierShortcutMonitor {
            let driver = PriorityHotKeyDriver(start: { [self] f in handler = f; starts += 1; return { [self] in handler = nil; stops += 1 } },
                secureInput: { self.secure }, keyIsDown: { $0 == 54 ? self.held : self.left }, now: { self.clock }, chordSince: { _ in self.chord })
            return ModifierShortcutMonitor(driver: driver, access: { self.trusted }, failed: { _ in })
        }
        func right(_ down: Bool) throws {
            held = down
            let sides = (held ? UInt64(16) : 0) | (left ? 8 : 0)
            try flags(54, sides == 0 ? [] : [.maskCommand, .init(rawValue: sides)])
        }
        func flags(_ code: Int64, _ flags: CGEventFlags, injected: Bool = false) throws {
            let e = try #require(CGEvent(source: nil))
            e.type = .flagsChanged; e.flags = flags; e.timestamp = UInt64(clock * 1_000_000_000)
            e.setIntegerValueField(.keyboardEventKeycode, value: code)
            e.setIntegerValueField(.eventSourceUnixProcessID, value: injected ? 99 : 0)
            #expect(handler?(.flagsChanged, e) == false)
        }
        func tick(_ m: ModifierShortcutMonitor) { clock += 0.25; m.checkStroke() }
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
