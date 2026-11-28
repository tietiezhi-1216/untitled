import AppKit
import Carbon
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized) @MainActor
struct PriorityHotKeyRecoveryTests {
    @Test func secureInputEndsWithoutAPermissionChangeAndActuallyRestoresTheRoute() async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        let store=fixture.store!,system=fixture.system,sleeper=fixture.sleeper
        let saved=try Data(contentsOf:fixture.recordURL),statuses=store.permissions.statuses
        await settle()
        #expect(store.priorityHotKeyRecoveryNeeded && store.priorityRecoveryIsScheduled)
        #expect(store.priorityHotKeyStatus?.contains("安全输入") == true)
        #expect(store.hotKeyErrors.values.contains { $0.contains("-9878") })
        #expect(store.errorMessage?.hasPrefix("操作已保存，但快捷键未生效：") == true)
        #expect(system.starts == 0 && sleeper.pendingCount == 1)
        system.secure=false
        sleeper.advance()
        await settle()
        #expect(store.permissions.statuses == statuses)
        #expect(system.starts == 1 && system.ordinaryAttempts == 1)
        #expect(!store.priorityHotKeyRecoveryNeeded && !store.priorityRecoveryIsScheduled)
        #expect(store.hotKeyErrors.isEmpty && store.priorityHotKeyStatus == "优先模式已启用 · 1 个快捷键")
        #expect(sleeper.pendingCount == 0 && store.errorMessage == nil)
        #expect(try Data(contentsOf:fixture.recordURL) == saved)
        #expect(system.permissionRequests == 0)
    }

    @Test func retryBudgetEndsAndActivationRecoversWithoutChurningAHealthyTap() async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        let store=fixture.store!,system=fixture.system,sleeper=fixture.sleeper
        await exhaust(fixture)
        #expect(sleeper.delays == PluginStore.priorityRecoveryDelays)
        #expect(!store.priorityRecoveryIsScheduled && sleeper.pendingCount == 0)
        #expect(store.priorityHotKeyRecoveryNeeded && !store.hotKeyErrors.isEmpty)
        #expect(system.startAttempts == 0)
        system.secure=false
        NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:nil)
        await settle()
        #expect(system.starts == 1 && store.hotKeyErrors.isEmpty)
        NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:nil)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.sessionDidBecomeActiveNotification,object:nil)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didWakeNotification,object:nil)
        await settle()
        #expect(system.starts == 1 && system.stops == 0)
        #expect(!store.priorityRecoveryIsScheduled && sleeper.delays.count == 8)
    }

    @Test(arguments:[NSWorkspace.sessionDidBecomeActiveNotification,NSWorkspace.didWakeNotification])
    func unlockAndWakeRestoreAStaleFailure(name:Notification.Name) async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        await settle()
        fixture.system.secure=false
        NSWorkspace.shared.notificationCenter.post(name:name,object:nil)
        await settle()
        #expect(fixture.system.starts == 1)
        #expect(!fixture.store.priorityHotKeyRecoveryNeeded && fixture.store.hotKeyErrors.isEmpty)
        #expect(fixture.sleeper.pendingCount == 0 && !fixture.store.priorityRecoveryIsScheduled)
    }

    @Test func ordinarySingleKeyNeverStartsFromASecurePressOrFiresAnUnpairedRelease() throws {
        let system = System(); system.ordinaryFails = false; system.secure = true
        let manager = HotKeyManager(driver: system.ordinaryDriver, secureInput: { system.secure })
        var downs = 0, ups = 0
        try manager.register(.init(keyCode: 0, modifiers: 0, key: "A"), onRelease: { ups += 1 }) { downs += 1 }
        let route = try #require(system.ordinaryHandler)
        route(true); system.secure = false; route(true); route(false)
        #expect(downs == 0 && ups == 0)
        route(true); system.secure = true; route(false)
        #expect(downs == 1 && ups == 1)
        route(true); manager.clear(); #expect(ups == 1)
    }

    @Test func sideButtonDenialDoesNotDisableOrdinaryKeysOrSilentlyRequestAccess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mouse = System(), keyboard = System()
        mouse.authorized = false; keyboard.ordinaryFails = false
        let center = HostPermissionCenter(drivers: [HostPermissionDriver(descriptor: .init(id: .accessibility, title: "AX", summary: "", symbol: "lock"),
            status: { mouse.authorized ? .authorized : .notGranted }, request: { mouse.permissionRequests += 1 }, openSettings: {})])
        let store = PluginStore(directory: dir, permissions: center, ordinaryHotKeyDriver: keyboard.ordinaryDriver, sideButtonDriver: mouse.driver)
        try store.installManifest(Fixture.manifest)
        let id = Fixture.manifest.id
        let letter = PluginCommand(action: .showMainWindow, hotKey: .init(keyCode: 3, modifiers: 0, key: "F"))
        let side = PluginCommand(action: .showMainWindow, hotKey: .init(mouseButton: 3))
        try store.saveCommand(letter, pluginID: id); try store.saveCommand(side, pluginID: id)
        #expect(store.sideButtonRecoveryNeeded && !store.priorityHotKeysEnabled && !store.priorityRecoveryIsScheduled)
        #expect(Set(store.hotKeyErrors.keys) == [side.id] && keyboard.ordinaryHandler != nil && mouse.startAttempts == 0)
        #expect(throws: PluginError.self) { try store.saveCommand(PluginCommand(action: .showMainWindow, hotKey: side.hotKey), pluginID: id) }
        mouse.authorized = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(mouse.starts == 1 && !store.shortcutRecoveryNeeded && store.hotKeyErrors.isEmpty && mouse.permissionRequests == 0)
        store.removeCommand(side.id, pluginID: id)
        #expect(mouse.stops == 1 && keyboard.ordinaryHandler != nil && !store.shortcutRecoveryNeeded)
        #expect(await store.prepareForQuit())
    }

    @Test func runtimeFailureKeepsRealConflictsVisibleUntilRecoverySucceeds() async throws {
        let fixture=try Fixture(secure:false)
        defer { fixture.close() }
        let store=fixture.store!,system=fixture.system,sleeper=fixture.sleeper
        #expect(system.starts == 1 && store.hotKeyErrors.isEmpty)
        system.startFails=true
        let handler=try #require(system.handler)
        #expect(!handler(.tapDisabledByTimeout,try event(.keyDown)))
        await settle()
        #expect(system.stops == 1 && store.priorityHotKeyRecoveryNeeded)
        #expect(store.hotKeyErrors.values.contains { $0.contains("-9878") })
        sleeper.advance()
        await settle()
        #expect(system.startAttempts == 2 && system.starts == 1)
        #expect(store.priorityHotKeyRecoveryNeeded && !store.hotKeyErrors.isEmpty)
        system.startFails=false
        sleeper.advance()
        await settle()
        #expect(system.starts == 2 && system.stops == 1)
        #expect(store.hotKeyErrors.isEmpty && !store.priorityHotKeyRecoveryNeeded)
        #expect(!store.priorityRecoveryIsScheduled && sleeper.pendingCount == 0)
    }

    enum Stop:CaseIterable,Sendable { case pause,disablePriority,record,disablePlugin,uninstall,quit }
    @Test(arguments:Stop.allCases)
    func stoppingCancelsTheOnlyRecoveryTaskAndCannotRestartIt(stop:Stop) async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        await settle()
        #expect(fixture.sleeper.pendingCount == 1)
        switch stop {
        case .pause: fixture.store.setHotKeysPaused(true)
        case .disablePriority: fixture.store.setPriorityHotKeysEnabled(false)
        case .record: HotKeyRecordingSession.setRecording(true)
        case .disablePlugin: fixture.store.setEnabled(false,pluginID:Fixture.manifest.id)
        case .uninstall: fixture.store.uninstall(Fixture.manifest.id)
        case .quit: #expect(await fixture.store.prepareForQuit())
        }
        await settle()
        #expect(!fixture.store.priorityRecoveryIsScheduled && !fixture.store.priorityHotKeyRecoveryNeeded)
        #expect(fixture.sleeper.pendingCount == 0)
        fixture.system.secure=false
        fixture.sleeper.finishAll()
        NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:nil)
        await settle()
        #expect(fixture.system.starts == 0 && !fixture.store.priorityRecoveryIsScheduled)
    }

    @Test func rebindingCancelsTheOldGenerationAndOnlyRegistersTheNewChord() async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        await settle()
        var command=try #require(fixture.store.installed.first?.commands.first)
        command.hotKey=HotKey(keyCode:19,modifiers:UInt32(controlKey),key:"2")
        try fixture.store.saveCommand(command,pluginID:Fixture.manifest.id)
        await settle()
        #expect(fixture.sleeper.pendingCount == 1 && fixture.sleeper.delays.count == 2)
        fixture.system.secure=false
        fixture.sleeper.advance()
        await settle()
        #expect(fixture.system.starts == 1 && fixture.store.hotKeyErrors.isEmpty)
        #expect(fixture.store.installed.first?.commands == [command])
        var opens=0
        fixture.store.showMainWindow={ opens += 1 }
        let handler=try #require(fixture.system.handler)
        #expect(!handler(.keyDown,try event(.keyDown,code:18)))
        #expect(!handler(.keyUp,try event(.keyUp,code:18)))
        #expect(handler(.keyDown,try event(.keyDown,code:19)))
        #expect(handler(.keyUp,try event(.keyUp,code:19)))
        await settle()
        #expect(opens == 1 && fixture.sleeper.pendingCount == 0)
    }

    @Test func missingAuthorizationDoesNotPollOrPromptAndARealGrantRecovers() async throws {
        let fixture=try Fixture(secure:false,authorized:false)
        defer { fixture.close() }
        await settle()
        #expect(fixture.store.priorityHotKeyRecoveryNeeded && !fixture.store.priorityRecoveryIsScheduled)
        #expect(fixture.sleeper.delays.isEmpty && fixture.system.permissionRequests == 0)
        fixture.system.authorized=true
        fixture.store.permissions.refresh()
        await settle()
        #expect(fixture.system.starts == 1 && fixture.store.hotKeyErrors.isEmpty)
        #expect(!fixture.store.priorityHotKeyRecoveryNeeded && fixture.sleeper.delays.isEmpty)
        #expect(fixture.system.permissionRequests == 0)
    }

    @Test func aFailedRetryKeepsTheOwnedNoticeUntilTheRegistrationActuallySucceeds() async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        await settle()
        let notice=try #require(fixture.store.errorMessage)
        fixture.system.secure=false;fixture.system.startFails=true
        fixture.sleeper.advance()
        await settle()
        #expect(fixture.store.errorMessage == notice && !fixture.store.hotKeyErrors.isEmpty)
        fixture.system.startFails=false;fixture.sleeper.advance()
        await settle()
        #expect(fixture.store.errorMessage == nil && fixture.store.hotKeyErrors.isEmpty)
    }

    @Test func aSuccessfulRecoveryDoesNotDismissAnUnrelatedOutputError() async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        await settle()
        fixture.store.errorMessage="测试输出写入失败，请重试。"
        fixture.system.secure=false;fixture.sleeper.advance()
        await settle()
        #expect(!fixture.store.priorityHotKeyRecoveryNeeded && fixture.store.hotKeyErrors.isEmpty)
        #expect(fixture.store.errorMessage == "测试输出写入失败，请重试。")
    }

    @Test func aPendingSleepDoesNotRetainTheStoreAndIsCanceledAtDeinit() async throws {
        let fixture=try Fixture(secure:true)
        defer { fixture.close() }
        await settle()
        let released=WeakStore(fixture.store)
        fixture.store=nil
        await settle()
        #expect(released.value == nil && fixture.sleeper.pendingCount == 0)
        #expect(fixture.system.starts == 0)
    }

    @Test func tenRecoveryCyclesReleaseTheirStoresAndHaveOnePendingSleepAtMost() async throws {
        var weakStores:[WeakStore]=[]
        for _ in 0..<10 {
            let fixture=try Fixture(secure:true)
            await settle()
            weakStores.append(WeakStore(fixture.store))
            #expect(fixture.sleeper.pendingCount == 1)
            fixture.system.secure=false
            fixture.sleeper.advance()
            await settle()
            #expect(fixture.system.starts == 1 && fixture.sleeper.pendingCount == 0)
            #expect(await fixture.store.prepareForQuit())
            #expect(fixture.system.stops == 1 && !fixture.store.priorityRecoveryIsScheduled)
            fixture.close();fixture.store=nil
            await settle()
            #expect(weakStores.allSatisfy { $0.value == nil })
        }
    }

    @Test func injectedOrdinaryRegistrationsPreservePressPairingAndAreReleasedOnce() throws {
        let system=System();system.ordinaryFails=false
        var manager:HotKeyManager?=HotKeyManager(driver:system.ordinaryDriver)
        var presses=0,releases=0
        try manager?.register(Fixture.key,onRelease:{ releases += 1 }) { presses += 1 }
        let handler=try #require(system.ordinaryHandler)
        handler(true);handler(true)
        #expect(presses == 1 && releases == 0)
        manager?.clear()
        #expect(releases == 1 && system.ordinaryStops == 1)
        handler(false)
        #expect(releases == 1)
        try manager?.register(Fixture.key) {}
        manager=nil
        #expect(system.ordinaryStops == 2)
    }

    private func exhaust(_ fixture:Fixture) async {
        await settle()
        for _ in PluginStore.priorityRecoveryDelays { fixture.sleeper.advance();await settle() }
    }
    private func settle() async { try? await Task.sleep(for:.milliseconds(20)) }
    private func event(_ type:CGEventType,code:CGKeyCode=18) throws -> CGEvent {
        let value=try #require(CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:type == .keyDown))
        value.type=type;value.flags=[.maskControl]
        value.setIntegerValueField(.eventSourceUnixProcessID,value:0)
        return value
    }
    @MainActor private final class WeakStore {
        weak var value:PluginStore?
        init(_ value:PluginStore?) { self.value=value }
    }
    @MainActor private final class Fixture {
        static var key:HotKey { HotKey(keyCode:18,modifiers:UInt32(controlKey),key:"1") }
        static var manifest:PluginManifest {
            PluginManifest(schemaVersion:1,id:"com.untitled.priority-recovery-tests",name:"Recovery",version:"1.0.0",
                summary:"Test",author:"Tests",repository:HostInfo.repository,minimumHostVersion:"0.2.0",
                actions:[.showMainWindow],templates:[CommandTemplate(id:"panel",title:"Panel",action:.showMainWindow)])
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("PriorityRecovery-"+UUID().uuidString)
        let domain="PriorityRecovery-"+UUID().uuidString
        let system=System(),sleeper=Sleeper()
        var store:PluginStore!
        var recordURL:URL { directory.appendingPathComponent(Self.manifest.id+".json") }
        init(secure:Bool,authorized:Bool=true) throws {
            system.secure=secure;system.authorized=authorized
            let defaults=try #require(UserDefaults(suiteName:domain))
            let permissions=HostPermissionCenter(drivers:[HostPermissionDriver(
                descriptor:.init(id:.accessibility,title:"AX",summary:"Test",symbol:"lock"),
                status:{ [system] in system.authorized ? .authorized:.notGranted },
                request:{ [system] in system.permissionRequests += 1 },openSettings:{})])
            store=PluginStore(directory:directory,permissions:permissions,shortcutDefaults:defaults,
                priorityHotKeyDriver:system.driver,ordinaryHotKeyDriver:system.ordinaryDriver,
                priorityRecoverySleep:{ [sleeper] in try await sleeper.sleep($0) })
            try store.installManifest(Self.manifest)
            store.setPriorityHotKeysEnabled(true)
            try store.saveCommand(PluginCommand(action:.showMainWindow,hotKey:Self.key),pluginID:Self.manifest.id)
        }
        func close() {
            store?.setHotKeysPaused(true)
            HotKeyRecordingSession.setRecording(false)
            sleeper.finishAll()
            UserDefaults.standard.removePersistentDomain(forName:domain)
            try? FileManager.default.removeItem(at:directory)
        }
    }
    @MainActor private final class System {
        var secure=false,authorized=true,startFails=false,ordinaryFails=true
        var startAttempts=0,starts=0,stops=0,permissionRequests=0
        var ordinaryAttempts=0,ordinaryStops=0
        var handler:(@MainActor (CGEventType,CGEvent)->Bool)?
        var ordinaryHandler:(@MainActor (Bool)->Void)?
        var driver:PriorityHotKeyDriver {
            PriorityHotKeyDriver(start:{ [self] handler in
                startAttempts += 1
                if startFails { throw PluginError.invalid("Fake tap unavailable") }
                starts += 1;self.handler=handler
                return { [self] in stops += 1;self.handler=nil }
            },secureInput:{ [self] in secure },keyIsDown:{ _ in true })
        }
        var ordinaryDriver:HotKeyManager.Driver {
            HotKeyManager.Driver(register:{ [self] key,handler in
                ordinaryAttempts += 1
                if ordinaryFails { throw PluginError.invalid("\(key.display) 无法注册，可能已被系统或其他应用占用（-9878）。") }
                ordinaryHandler=handler
                return { [self] in ordinaryStops += 1;ordinaryHandler=nil }
            })
        }
    }
    /// Cancellable barriers, not wall-clock timers or real keyboard permissions.
    @MainActor private final class Sleeper {
        var delays:[Duration]=[]
        private var pending:[UUID:CheckedContinuation<Void,Never>]=[:]
        var pendingCount:Int { pending.count }
        func sleep(_ delay:Duration) async throws {
            let id=UUID();delays.append(delay)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { pending[id]=continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.pending.removeValue(forKey:id)?.resume() }
            }
            try Task.checkCancellation()
        }
        func advance() { if let id=pending.keys.first { pending.removeValue(forKey:id)?.resume() } }
        func finishAll() { let values=Array(pending.values);pending.removeAll();values.forEach { $0.resume() } }
    }
}
