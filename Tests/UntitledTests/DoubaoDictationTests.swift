import AppKit
import Carbon
import Foundation
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized) struct DoubaoDictationTests {
    @Test func utf16SelectionAndFinalRevisionOwnOnlyTheDictationSpan() throws {
        let original = "前😀选中后"
        let selected = (original as NSString).range(of: "选中")
        var anchor = try DictationTextAnchor(value: original, selection: selected)
        let draft = try anchor.replacement("下午三点", value: original, selected: selected)
        #expect(draft == "前😀下午三点后")
        anchor.commit("下午三点")
        #expect(anchor.range == NSRange(location: selected.location, length: 4))
        let final = try anchor.replacement("下午 3 点。", value: draft, selected: anchor.expectedSelection)
        #expect(final == "前😀下午 3 点。后")
        #expect(throws: DictationTargetError.self) {
            try anchor.replacement("新文字", value: draft + "手改", selected: anchor.expectedSelection)
        }
        #expect(throws: DictationTargetError.self) {
            try anchor.replacement("新文字", value: draft, selected: NSRange(location: 0, length: 0))
        }
        #expect(throws: DictationTargetError.self) {
            try DictationTextAnchor(value: "小", selection: NSRange(location: 2, length: Int.max))
        }
    }

    @Test func hotkeyRepeatsAndReleasesAreBalanced() {
        var presses = HotKeyPressState()
        let transitions = [presses.transition(1, pressed: false), presses.transition(1, pressed: true),
                           presses.transition(1, pressed: true), presses.transition(1, pressed: false),
                           presses.transition(1, pressed: false), presses.transition(2, pressed: true),
                           presses.transition(3, pressed: true)]
        #expect(transitions == [false, true, false, true, false, true, true])
        let releases = presses.clear(), empty = presses.clear()
        let staleRelease = presses.transition(2, pressed: false)
        #expect(releases == [2, 3])
        #expect(empty.isEmpty)
        #expect(!staleRelease)
    }

    @Test @MainActor func nativeCarbonReleaseEventsAndRebindingBalanceHolds() throws {
        _ = NSApplication.shared
        let manager = HotKeyManager()
        defer { manager.clear() }
        var downs = 0, ups = 0
        try manager.register(HotKey(keyCode: UInt32(kVK_F20), modifiers: 0, key: "F20"),
                             onRelease: { ups += 1 }) { downs += 1 }
        func send(_ kind: UInt32) throws {
            var raw: EventRef?
            #expect(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &raw) == noErr)
            let event = try #require(raw)
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x554E544C, id: 1)
            #expect(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
            #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        }
        try send(UInt32(kEventHotKeyPressed)); try send(UInt32(kEventHotKeyPressed))
        try send(UInt32(kEventHotKeyReleased)); try send(UInt32(kEventHotKeyReleased))
        #expect(downs == 1 && ups == 1)
        try send(UInt32(kEventHotKeyPressed))
        manager.clear()
        #expect(downs == 2 && ups == 2)
        try send(UInt32(kEventHotKeyReleased))
        #expect(ups == 2)
    }

    @Test @MainActor func globalSideButtonHoldAndSingleKeyToggleUseExistingCommandsWithoutPriorityMode() async throws {
        let dir = temporary(), deps = Dependencies()
        defer { try? FileManager.default.removeItem(at: dir) }
        @MainActor final class Inputs {
            var mouse: (@MainActor (CGEventType, CGEvent) -> Bool)?
            var keys: [String: @MainActor (Bool) -> Void] = [:]
            var keyboard: HotKeyManager.Driver { .init(register: { [self] key, callback in
                guard key.mouseButton == nil else { throw PluginError.invalid("mouse reached Carbon") }
                keys[key.identity] = callback
                return { [self] in keys.removeValue(forKey: key.identity) }
            }) }
            var pointer: PriorityHotKeyDriver { .init(start: { [self] handler in
                mouse = handler; return { [self] in mouse = nil }
            }, secureInput: { false }, keyIsDown: { _ in true }) }
            func side(_ type: CGEventType, flags: CGEventFlags = []) throws -> Bool {
                let event = try #require(CGEvent(source: nil)); event.type = type; event.flags = flags
                event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
                event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
                return mouse?(type, event) ?? false
            }
        }
        let inputs = Inputs(), manifest = try pluginManifest()
        let store = PluginStore(directory: dir, permissions: permissionCenter(), ordinaryHotKeyDriver: inputs.keyboard,
                                sideButtonDriver: inputs.pointer, dictationFactory: { deps.controller(preferencesURL: $0) })
        try store.installManifest(manifest)
        #expect(inputs.mouse == nil && !store.priorityHotKeysEnabled)
        var hold = try #require(store.installed[0].commands.first { $0.action == .holdDoubaoDictation })
        var toggle = try #require(store.installed[0].commands.first { $0.action == .toggleDoubaoDictation })
        hold.hotKey = .init(mouseButton: 3); let letter = HotKey(keyCode: 3, modifiers: 0, key: "F"); toggle.hotKey = letter
        try store.saveCommand(hold, pluginID: manifest.id); try store.saveCommand(toggle, pluginID: manifest.id)
        #expect(deps.sessions.isEmpty && store.hotKeyErrors.isEmpty)
        let controller = store.doubaoDictation(for: manifest.id)
        #expect(try inputs.side(.otherMouseDown)); #expect(try inputs.side(.otherMouseDown))
        try await wait { controller.phase == .listening }
        #expect(deps.sessions.count == 1 && deps.microphones[0].started == 1)
        #expect(try inputs.side(.otherMouseUp, flags: .maskShift))
        try await wait { controller.phase == .idle && controller.history.entries.count == 1 }
        let key = try #require(inputs.keys[letter.identity]); key(true); key(true); key(false)
        try await wait { controller.phase == .listening }
        key(true); key(false)
        try await wait { controller.phase == .idle && controller.history.entries.count == 2 }
        #expect(deps.sessions.count == 2)
        store.setHotKeysPaused(true); #expect(inputs.mouse == nil && inputs.keys.isEmpty)
        let reopened = PluginStore(directory: dir, permissions: permissionCenter(), ordinaryHotKeyDriver: inputs.keyboard, sideButtonDriver: inputs.pointer)
        #expect(reopened.installed[0].commands.contains(hold) && reopened.installed[0].commands.contains(toggle))
        reopened.setEnabled(false, pluginID: manifest.id); #expect(inputs.mouse == nil && inputs.keys.isEmpty)
    }

    @Test @MainActor func defaultRightCommandHoldsThenFinalizesWithoutStartingOnShortcuts() async throws {
        @MainActor final class Hardware {
            var held = false, otherInput = false
            var hook: (@MainActor (CGEventType, CGEvent) -> Bool)?
            var driver: PriorityHotKeyDriver { .init(start: { [self] h in hook = h; return { [self] in hook = nil } },
                secureInput: { false }, keyIsDown: { [self] in $0 == 54 && held }, chordSince: { [self] _ in otherInput }) }
            func edge(_ down: Bool) throws {
                held = down
                let e = try #require(CGEvent(source: nil)); e.type = .flagsChanged; e.flags = down ? [.maskCommand, .init(rawValue: 16)] : []
                e.setIntegerValueField(.keyboardEventKeycode, value: 54); e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
                #expect(hook?(.flagsChanged,e) == false)
            }
        }
        let root = temporary(), h = Hardware(), d = Dependencies(), m = try pluginManifest()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(directory: root, permissions: permissionCenter(), ordinaryHotKeyDriver: .init(register: { key, _ in
            #expect(!key.isRightCommand); return {}
        }), modifierDriver: h.driver, dictationFactory: { d.controller(preferencesURL: $0) })
        try store.installManifest(m)
        let c = store.doubaoDictation(for: m.id)
        #expect(!store.priorityHotKeysEnabled && store.hotKeyErrors.isEmpty && d.microphones.isEmpty)
        try h.edge(true); try h.edge(false)
        h.otherInput = true; try h.edge(true); try await Task.sleep(for: .milliseconds(310)); try h.edge(false)
        #expect(c.phase == .idle && d.microphones.isEmpty)
        h.otherInput = false; try h.edge(true); try await wait { c.phase == .listening }; try h.edge(false)
        try await wait { c.phase == .idle && c.history.entries.count == 1 }
        #expect(d.sessions[0].finished == 1 && d.microphones[0].stopped > 0)
        try h.edge(true); try await wait { c.phase == .listening }; h.otherInput = true
        try await wait { c.phase == .idle }; try h.edge(false)
        #expect(d.sessions[1].finished == 0 && c.history.entries.count == 1)
        store.setHotKeysPaused(true); #expect(h.hook == nil)
        #expect(await store.prepareForQuit())
    }

    @Test @MainActor func liveGesturesRequireOnlyMicrophoneBeforeCapture() throws {
        let dependencies = Dependencies()
        let controller = dependencies.controller()
        var checks: [Set<HostPermissionID>] = []
        controller.isAllowed = { true }
        controller.requirePermissions = { checks.append($0); throw HostPermissionError.missing }
        #expect(throws: HostPermissionError.self) { try controller.toggle() }
        #expect(throws: HostPermissionError.self) { try controller.holdPressed(UUID()) }
        #expect(checks == [[.microphone], [.microphone]] && dependencies.targetCaptures == 0 && dependencies.copies.isEmpty)
        #expect(controller.phase == .idle && dependencies.microphones.isEmpty && dependencies.sessions.isEmpty)
    }

    @Test @MainActor func obsoleteInlineModesCannotOptUsersOutOfBubblePreviewOrResetPreferences() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("preferences.json")
        let old = Data(#"{"liveInput":false,"experimentalRealtimeInput":false,"usesDictationInputMethod":true,"maximumSeconds":60,"inputDeviceUID":"test.input"}"#.utf8)
        try old.write(to: url)
        let dependencies = Dependencies()
        let controller = dependencies.controller(preferencesURL: url)
        #expect(controller.preferences == DictationPreferences(maximumSeconds: 60, inputDeviceUID: "test.input"))
        var checks: [Set<HostPermissionID>] = []
        controller.isAllowed = { true }; controller.requirePermissions = { checks.append($0) }
        await controller.history.load()
        #expect(checks.isEmpty && dependencies.sessions.isEmpty && dependencies.microphones.isEmpty)
        #expect(try Data(contentsOf: url) == old)
        try controller.holdPressed(UUID())
        try await wait { controller.phase == .listening }
        #expect(checks.first == [.microphone] && dependencies.targetCaptures == 0)
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        try await wait { controller.history.entries.count == 1 }
        #expect(dependencies.target.writes == [dependencies.sessions[0].finalText])
        #expect(try Data(contentsOf: url) == old)
    }

    @Test @MainActor func microphoneSelectionIsLazyAndPreservedOnCancel() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        var settings = controller.preferences; settings.inputDeviceUID = "test.microphone"
        try controller.savePreferences(settings)
        #expect(dependencies.microphones.isEmpty && dependencies.sessions.isEmpty)
        try controller.toggle()
        try await wait { controller.phase == .listening }
        #expect(dependencies.microphones[0].configuredUID == "test.microphone")
        controller.cancel()
        #expect(dependencies.microphones[0].stopped > 0 && controller.preferences.inputDeviceUID == "test.microphone")
        for invalid in ["", "\u{0}", String(repeating: "x", count: 1025)] {
            settings.inputDeviceUID = invalid
            #expect(throws: PluginError.self) { try settings.validate() }
        }
    }

    @Test @MainActor func emptyRecognitionKeepsCaptureDiagnosticsAfterStopping() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.microphones[0].currentDiagnostics = .init(inputName: "Test input", callbacks: 4, capturedBytes: 1280, peakRMS: 0)
        dependencies.sessions[0].finalText = ""
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(controller.audioDiagnostics?.capturedBytes == 1280)
        #expect(controller.notice.contains("静音音频"))
        #expect(controller.history.entries.isEmpty)
        #expect(dependencies.microphones[0].stopped > 0)
    }

    @Test @MainActor func missingFocusAndWhitespaceFinalNeverCopyThePriorDraft() async throws {
        let d = Dependencies(), c = d.allowedController()
        d.unsupported = true
        try c.toggle(); try await wait { c.phase == .listening }
        d.sessions[0].finalText = " \n\t"; d.sessions[0].onTranscript?("待校验")
        c.stopRecording(); try await wait { c.phase == .idle }
        #expect(d.targetCaptures == 0 && d.copies.isEmpty && c.notice.contains("草稿") && c.history.entries.isEmpty)
    }

    @Test @MainActor func reimportOnlyReportsAnInterruptionForAnActiveDictation() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = Dependencies()
        let store = PluginStore(directory: root, permissions: permissionCenter(),
                                ordinaryHotKeyDriver: .init(register: { _, _ in {} }),
                                dictationFactory: { dependencies.controller(preferencesURL: $0) })
        let manifest = try pluginManifest()
        try store.installManifest(manifest)
        let controller = store.doubaoDictation(for: manifest.id)
        try store.installManifest(manifest) // Open panel, then reimport while idle.
        #expect(controller.notice.isEmpty && dependencies.sessions.isEmpty && dependencies.microphones.isEmpty)

        // An idle lifecycle refresh must not replace a real, earlier startup error.
        let permissionGate = controller.requirePermissions
        controller.requirePermissions = { _ in throw HostPermissionError.missing }
        #expect(throws: HostPermissionError.self) { try controller.toggle() }
        try store.installManifest(manifest)
        #expect(controller.notice == HostPermissionError.missing.localizedDescription)
        controller.requirePermissions = permissionGate
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = dependencies.sessions[0], late = session.onTranscript
        session.onTranscript?("未定稿")
        try store.installManifest(manifest)
        late?("过期回调")
        #expect(controller.phase == .idle && session.cancelled > 0 && dependencies.microphones[0].stopped > 0)
        #expect(controller.notice.contains("中断") && controller.resultText == "未定稿")
        #expect(controller.history.entries.isEmpty)
    }

    @Test @MainActor func secureFieldIsNeverWrittenAndMissingMicrophoneStillBlocksCapture() async throws {
        let d = Dependencies(), c = d.allowedController()
        c.requirePermissions = { _ in throw HostPermissionError.missing }
        #expect(throws: HostPermissionError.self) { try c.toggle() }
        #expect(d.sessions.isEmpty && d.microphones.isEmpty && d.copies.isEmpty)
        c.requirePermissions = { _ in }; d.secure = true
        try c.toggle(); try await wait { c.phase == .listening }
        #expect(d.targetCaptures == 0 && d.copies.isEmpty)
        c.stopRecording(); try await wait { c.phase == .idle }
        #expect(d.targetCaptures == 1 && d.target.finalCalls == 0 && d.copies == [d.sessions[0].finalText])
        #expect(c.notice.contains("密码框") && c.notice.contains("已复制"))
    }

    @Test @MainActor func togglePreviewsRevisionsThenInsertsOnlyFinalAndReleasesResources() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = try #require(dependencies.sessions.first)
        session.onTranscript?("下午")
        session.onTranscript?("下午三点")
        #expect(controller.bubblePreview == "下午三点" && dependencies.target.writes.isEmpty)
        try controller.toggle()
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes == ["下午 3 点。"] && controller.bubblePreview.isEmpty)
        #expect(controller.lastResult == "下午 3 点。")
        #expect(session.finished == 1 && session.cancelled > 0)
        #expect(dependencies.microphones[0].stopped > 0)
    }

    @Test @MainActor func emptyFinalNeverErasesDraftOrClaimsSuccessfulPolishing() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.sessions[0].finalText = ""
        dependencies.sessions[0].onTranscript?("中间草稿")
        #expect(controller.bubblePreview == "中间草稿" && dependencies.target.writes.isEmpty)
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(controller.transcript == "中间草稿")
        #expect(dependencies.target.writes.isEmpty && dependencies.target.finalCalls == 0)
        #expect(controller.notice.contains("草稿"))
    }

    @Test @MainActor func holdReleaseDuringConnectingFinishesTheCapturedShortUtterance() async throws {
        let dependencies = Dependencies()
        dependencies.startDelay = .milliseconds(150)
        let controller = dependencies.allowedController()
        let command = UUID()
        try controller.holdPressed(command)
        #expect(dependencies.microphones.first?.started == 1)
        try await wait { dependencies.sessions.first?.started == 1 }
        controller.holdReleased(command)
        #expect(controller.phase == .finishing)
        #expect(dependencies.microphones.first?.stopped == 1)
        try await wait { controller.phase == .idle }
        #expect(dependencies.microphones.first?.started == 1)
        #expect(dependencies.sessions.first?.finished == 1)
        #expect(dependencies.sessions.first?.sentBytes == 640)
    }

    @Test @MainActor func cancelWhileConnectingNeverRestartsAudioOrWritesALateFinal() async throws {
        let dependencies = Dependencies()
        dependencies.suspendStart = true
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { dependencies.sessions.first?.started == 1 }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(controller.phase == .idle)
        #expect(dependencies.microphones.first?.started == 1)
        #expect(dependencies.microphones.first?.stopped == 1)
        #expect(dependencies.sessions.first?.finished == 0)
        #expect(dependencies.sessions.first?.cancelled == 1)
        #expect(dependencies.target.writes.isEmpty)
    }

    enum EscapeStage: CaseIterable, Sendable { case connecting, listening, waitingForFinal, hold }

    @Test(arguments: EscapeStage.allCases) @MainActor
    func escapeCancelsOnlyTheActiveUtterance(_ stage: EscapeStage) async throws {
        let folder = temporary(), d = Dependencies(), keys = EscapeKeys(), manifest = try pluginManifest()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PluginStore(directory: folder, permissions: permissionCenter(), ordinaryHotKeyDriver: keys.driver,
                                dictationFactory: { d.controller(preferencesURL: $0) })
        try store.installManifest(manifest)
        let c = store.doubaoDictation(for: manifest.id)
        defer { c.cancel() }
        #expect(keys.handlers[EscapeKeys.bare] == nil && keys.handlers[EscapeKeys.withCommand] == nil)
        let hold = try #require(store.installed.first?.commands.first { $0.action == .holdDoubaoDictation })
        d.suspendStart = stage == .connecting
        if stage == .hold { try store.performDictationAction(.holdDoubaoDictation, pluginID: manifest.id, holdCommandID: hold.id) }
        else { try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id) }
        try await wait { stage == .connecting ? d.sessions.first?.started == 1 : c.phase == .listening }
        let session = try #require(d.sessions.first)
        let lateDraft = session.onTranscript
        if stage != .connecting { session.onTranscript?("这段不提交") }
        if stage == .waitingForFinal {
            session.finishDelay = .seconds(1)
            c.stopRecording()
            try await wait { session.finished == 1 }
        }
        let callback = try #require(keys.handlers[stage == .hold ? EscapeKeys.withCommand : EscapeKeys.bare])
        let finishedBeforeCancel = session.finished
        callback(true)
        c.holdReleased(hold.id)
        lateDraft?("过期的识别回调")
        #expect(c.phase == .idle && c.notice.contains("取消") && c.bubblePreview.isEmpty)
        #expect(keys.handlers[EscapeKeys.bare] == nil && keys.handlers[EscapeKeys.withCommand] == nil)
        #expect(session.cancelled == 1 && session.finished == finishedBeforeCancel && d.microphones[0].stopped > 0)

        d.suspendStart = false
        try c.toggle()
        try await wait { c.phase == .listening }
        callback(false); callback(true) // A callback queued by the previous registration.
        #expect(c.phase == .listening)
        #expect(d.targetCaptures == 0 && d.target.writes.isEmpty && d.copies.isEmpty && c.history.entries.isEmpty)
        c.cancel()
        #expect(keys.handlers[EscapeKeys.bare] == nil)
    }

    @Test @MainActor func escapeTracksShortcutPauseAndReleasesOnDisable() async throws {
        let folder = temporary(), d = Dependencies(), keys = EscapeKeys(), manifest = try pluginManifest()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PluginStore(directory: folder, permissions: permissionCenter(), ordinaryHotKeyDriver: keys.driver,
                                dictationFactory: { d.controller(preferencesURL: $0) })
        try store.installManifest(manifest)
        let c = store.doubaoDictation(for: manifest.id)
        defer { c.cancel(); HotKeyRecordingSession.setRecording(false) }
        try c.toggle()
        try await wait { c.phase == .listening }
        #expect(keys.handlers[EscapeKeys.bare] != nil)
        store.setHotKeysPaused(true)
        #expect(keys.handlers[EscapeKeys.bare] == nil && c.phase == .listening)
        store.setHotKeysPaused(false)
        #expect(keys.handlers[EscapeKeys.bare] != nil)
        HotKeyRecordingSession.setRecording(true)
        #expect(keys.handlers[EscapeKeys.bare] == nil && c.phase == .listening)
        HotKeyRecordingSession.setRecording(false)
        #expect(keys.handlers[EscapeKeys.bare] != nil)
        store.setEnabled(false, pluginID: manifest.id)
        #expect(keys.handlers[EscapeKeys.bare] == nil && c.phase == .idle)
    }

    @Test @MainActor func occupiedEscapeLeavesExistingShortcutsAndDeliveryIntact() async throws {
        let folder = temporary(), d = Dependencies(), keys = EscapeKeys(), manifest = try pluginManifest()
        defer { try? FileManager.default.removeItem(at: folder) }
        keys.occupied = [EscapeKeys.bare]
        let store = PluginStore(directory: folder, permissions: permissionCenter(), ordinaryHotKeyDriver: keys.driver,
                                dictationFactory: { d.controller(preferencesURL: $0) })
        try store.installManifest(manifest)
        let commands = store.installed.first?.commands
        let c = store.doubaoDictation(for: manifest.id)
        defer { c.cancel() }
        try c.toggle()
        try await wait { c.phase == .listening }
        #expect(keys.handlers[EscapeKeys.bare] == nil && store.installed.first?.commands == commands)
        try store.performDictationAction(.cancelDoubaoDictation, pluginID: manifest.id)
        #expect(c.phase == .idle && d.targetCaptures == 0 && d.copies.isEmpty)

        keys.occupied.removeAll()
        d.target.blockFinal = true
        try c.toggle()
        try await wait { c.phase == .listening }
        let old = try #require(keys.handlers[EscapeKeys.bare])
        c.stopRecording()
        try await wait { d.target.blockedFinal != nil }
        #expect(keys.handlers[EscapeKeys.bare] == nil)
        old(true)
        #expect(c.phase == .finishing && !c.notice.contains("取消"))
        let finished = try #require(d.target.blockedFinal)
        d.target.blockedFinal = nil; finished.resume()
        try await wait { c.phase == .idle }
        #expect(d.target.writes == [d.sessions[1].finalText] && keys.handlers[EscapeKeys.bare] == nil)
    }

    @Test @MainActor func holdOwnsItsSessionAndDoesNotStopAnExistingToggle() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        let command = UUID()
        try controller.holdPressed(command)
        try await wait { controller.phase == .listening }
        controller.holdReleased(UUID())
        #expect(controller.phase == .listening)
        controller.holdReleased(command)
        try await wait { controller.phase == .idle }
        try controller.toggle()
        try await wait { controller.phase == .listening }
        try controller.holdPressed(command)
        controller.holdReleased(command)
        #expect(controller.phase == .listening)
        #expect(dependencies.sessions.count == 2)
        controller.cancel()
    }

    @Test(arguments: [false, true]) @MainActor func noFieldSupportsBothGesturesAndCopiesOnlyTheFinal(hold: Bool) async throws {
        let d = Dependencies(), c = d.allowedController(), key = UUID()
        d.unsupported = true
        if hold { try c.holdPressed(key) } else { try c.toggle() }
        try await wait { c.phase == .listening }
        let s = d.sessions[0]; s.onTranscript?("草稿"); s.finishUpdates = ["收尾草稿"]
        #expect(d.targetCaptures == 0 && d.copies.isEmpty && d.microphones[0].started == 1)
        if hold { c.holdReleased(key) } else { try c.toggle() }
        try await wait { c.bubblePreview == "收尾草稿" }
        #expect(d.targetCaptures == 0 && d.copies.isEmpty)
        c.stopRecording()
        try await wait { c.phase == .idle && c.history.entries.count == 1 }
        #expect(s.finished == 1 && d.targetCaptures == 1 && d.target.finalCalls == 0 && d.copies == [s.finalText])
    }

    @Test @MainActor func deliveryRaceCopiesOnceAndOldCallbacksCannotReachANewSession() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let stale = dependencies.sessions[0].onTranscript
        dependencies.target.changed = true
        dependencies.sessions[0].onTranscript?("不应强行输入")
        #expect(controller.phase == .listening && dependencies.targetCaptures == 0)
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes.isEmpty)
        #expect(controller.notice.contains("改变") && dependencies.copies == [dependencies.sessions[0].finalText])
        try await wait { controller.history.entries.count == 1 }
        #expect(controller.history.entries[0].preview == dependencies.sessions[0].finalText)
        dependencies.target.changed = false
        try controller.toggle()
        try await wait { controller.phase == .listening }
        stale?("过期回调")
        #expect(controller.transcript.isEmpty)
        #expect(dependencies.target.writes.isEmpty)
        controller.cancel()
    }

    @Test @MainActor func foregroundChangesDoNotPollOrInterruptCaptureAndAccessCanBeRevokedAtFinal() async throws {
        let d = Dependencies(), c = d.allowedController()
        defer { c.cancel() }
        d.unsupported = true
        try c.toggle(); try await wait { c.phase == .listening }
        d.sessions[0].onTranscript?("桌面"); d.unsupported = false; d.secure = true
        try await wait { c.seconds >= 1 }
        d.secure = false; d.insertionAccess = false
        #expect(c.phase == .listening && d.targetCaptures == 0 && d.insertionChecks == 0)
        c.stopRecording(); try await wait { c.phase == .idle }
        #expect(d.targetCaptures == 0 && d.target.finalCalls == 0 && d.insertionChecks == 1)
        #expect(d.copies == [d.sessions[0].finalText] && c.notice.contains("辅助功能"))
    }

    @Test @MainActor func finishingRevisionsAreObservedButOnlyTheFinalIsCommitted() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = dependencies.sessions[0]
        session.onTranscript?("明天下午三点")
        #expect(controller.bubblePreview == "明天下午三点" && dependencies.target.writes.isEmpty)
        session.finishUpdates = ["明天下午三点，", "明天下午 3 点，开会"]
        session.finalText = "明天下午 3 点，开会。"
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes == [session.finalText])
        #expect(dependencies.target.finalCalls == 1)
        try await wait { !controller.history.entries.isEmpty }
        #expect(controller.history.entries.map(\.preview) == [session.finalText])
    }

    @Test @MainActor func finishingStillPreviewsRevisionsButRepeatedStopDoesNotSubmitTwice() async throws {
        let d = Dependencies(), c = d.allowedController()
        try c.toggle(); try await wait { c.phase == .listening }
        let s = d.sessions[0]
        s.onTranscript?("初稿"); s.finishUpdates = ["收尾修订"]; s.finishDelay = .milliseconds(180)
        c.stopRecording(); c.stopRecording(); try c.toggle(); c.holdReleased(UUID())
        try await wait { c.bubblePreview == "收尾修订" }
        #expect(c.phase == .finishing && d.target.writes.isEmpty && c.acknowledgedTextLength == 0)
        try await wait { c.phase == .idle }
        #expect(d.target.writes == [s.finalText] && s.finished == 1 && d.target.finalCalls == 1)
    }

    @Test @MainActor func identicalBubbleTextAndFinalStillRequiresExactlyOneInsertion() async throws {
        let d = Dependencies(), c = d.allowedController()
        try c.toggle(); try await wait { c.phase == .listening }
        let s = d.sessions[0]; s.onTranscript?(s.finalText)
        #expect(c.bubblePreview == s.finalText && d.target.writes.isEmpty)
        c.stopRecording(); try await wait { c.phase == .idle }
        #expect(d.target.writes == [s.finalText] && d.target.finalCalls == 1)
    }

    @Test @MainActor func stalledFinalDeliveryReleasesSessionAndKeepsExactlyOneFinal() async throws {
        let deps = Dependencies(); deps.deliveryBudget = .milliseconds(80)
        let controller = deps.allowedController()
        try controller.toggle(); try await wait { controller.phase == .listening }
        let session = deps.sessions[0]; session.onTranscript?("仅预览草稿")
        #expect(controller.bubblePreview == "仅预览草稿" && deps.target.writes.isEmpty)
        deps.target.blockFinal = true; session.finalText = "这是定稿，有标点。"
        controller.stopRecording()
        try await wait { deps.target.blockedFinal != nil }
        #expect(controller.statusTitle == "正在更新输入框")
        try await wait { controller.phase == .idle && controller.history.entries.count == 1 }
        #expect(controller.notice.contains("粘贴前请核对") && deps.copies == [session.finalText] && controller.history.entries[0].preview == session.finalText)
        #expect(deps.microphones[0].stopped > 0 && session.cancelled > 0 && deps.target.finalCalls == 1)
        try controller.toggle(); try await wait { controller.phase == .listening }
        deps.target.blockedFinal?.resume(); deps.target.blockedFinal = nil
        try await Task.sleep(for: .milliseconds(25))
        #expect(controller.phase == .listening && deps.target.writes.isEmpty && deps.copies == [session.finalText] && controller.notice.isEmpty)
        controller.cancel()
    }

    @Test @MainActor func aServiceFinalWithoutPunctuationIsDeliveredWithoutInventingAPeriod() async throws {
        let deps = Dependencies(), controller = deps.allowedController()
        try controller.toggle(); try await wait { controller.phase == .listening }
        let session = deps.sessions[0]; session.finalText = "一个标题"
        session.onTranscript?("一个标"); controller.stopRecording()
        try await wait { controller.phase == .idle && controller.history.entries.count == 1 }
        #expect(controller.notice.isEmpty && controller.history.entries[0].preview == session.finalText)
        #expect(deps.target.writes.last == "一个标题" && deps.target.finalCalls == 1)
    }

    @Test @MainActor func recognitionDeadlineNeverPromotesAnUnpunctuatedDraft() async throws {
        let deps = Dependencies(); deps.recognitionBudget = .milliseconds(100)
        let controller = deps.allowedController()
        try controller.toggle(); try await wait { controller.phase == .listening }
        let session = deps.sessions[0]; session.onTranscript?("尚未定稿"); session.finishDelay = .seconds(5)
        controller.stopRecording(); try await wait { controller.phase == .idle }
        #expect(controller.resultText == "尚未定稿" && controller.history.entries.isEmpty && deps.target.finalCalls == 0)
        #expect(controller.notice.contains("超时") && session.cancelled > 0 && deps.microphones[0].stopped > 0 && deps.copies.isEmpty && deps.targetCaptures == 0)
    }

    @Test @MainActor func cancelDuringFinalAcknowledgementNeverReplaysIt() async throws {
        let dependencies = Dependencies()
        dependencies.target.delay = .seconds(5)
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        controller.stopRecording()
        try await wait { dependencies.target.finalCalls == 1 }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.phase == .idle && dependencies.target.writes.isEmpty)
        #expect(dependencies.target.finalCalls == 1 && dependencies.copies.isEmpty)
        #expect(controller.history.entries.isEmpty)
        #expect(controller.resultText == dependencies.sessions[0].finalText && controller.notice.contains("定稿仍可"))
    }

    @Test @MainActor func burstOfPartialsChangesOnlyTheBubbleAndNeverTruncatesDelivery() async throws {
        let dependencies = Dependencies()
        dependencies.target.delay = .milliseconds(100)
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = dependencies.sessions[0]
        let sentence = "计划是明天下午开会，然后核对预算。"
        for i in 1...200 { session.onTranscript?(sentence + String(i)) }
        let long = String(repeating: sentence, count: 100) + "最后一句👨‍👩‍👧‍👦"
        session.onTranscript?(long)
        #expect(controller.bubblePreview == "…" + String(long.suffix(96)))
        #expect(controller.resultText == long && dependencies.target.finalCalls == 0)
        session.finalText = long + "。"
        controller.stopRecording(); try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes == [session.finalText])
        #expect(controller.transcript == session.finalText && controller.bubblePreview.isEmpty)
        #expect(controller.acknowledgedTextLength == session.finalText.utf16.count)
    }

    @Test @MainActor func cancellingTheBubbleNeverSubmitsAPartialOrLateFinal() async throws {
        let d = Dependencies(), c = d.allowedController()
        try c.toggle(); try await wait { c.phase == .listening }
        let s = d.sessions[0], late = s.onTranscript
        s.onTranscript?("不要迟到写入"); s.finishDelay = .milliseconds(180)
        c.stopRecording(); try await wait { s.finished == 1 }
        c.cancel(); late?("过期"); try await Task.sleep(for: .milliseconds(230))
        #expect(c.phase == .idle && c.resultText == "不要迟到写入" && c.bubblePreview.isEmpty)
        #expect(d.target.writes.isEmpty && d.target.finalCalls == 0 && d.targetCaptures == 0 && d.copies.isEmpty && c.history.entries.isEmpty)
    }

    @Test @MainActor func forkedPluginGetsScopedEscapeAndStopsItOnDisable() async throws {
        let folder = temporary(), d = Dependencies(), keys = EscapeKeys()
        defer { try? FileManager.default.removeItem(at: folder) }
        var payload = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        payload["id"] = "test.voice-fork"
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: payload))
        let store = PluginStore(directory: folder, permissions: permissionCenter(), ordinaryHotKeyDriver: keys.driver,
                                dictationFactory: { d.controller(preferencesURL: $0) })
        try store.installManifest(manifest)
        let controller = store.doubaoDictation(for: manifest.id)
        defer { controller.cancel() }
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id)
        try await wait { controller.phase == .listening }
        let cancel = try #require(keys.handlers[EscapeKeys.bare])
        cancel(true)
        #expect(controller.phase == .idle && keys.handlers[EscapeKeys.bare] == nil)
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id)
        try await wait { controller.phase == .listening }
        store.setEnabled(false, pluginID: manifest.id)
        #expect(controller.phase == .idle && keys.handlers[EscapeKeys.bare] == nil && d.copies.isEmpty)
    }

    @Test @MainActor func networkFailureAndPermissionRevocationStopAudio() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.sessions[0].onFailure?(PluginError.invalid("模拟断网"))
        #expect(controller.phase == .idle)
        #expect(dependencies.microphones[0].stopped > 0)
        #expect(controller.notice == "模拟断网" && controller.history.entries.isEmpty)
        try controller.toggle()
        try await wait { controller.phase == .listening }
        controller.requirePermissions = { _ in throw HostPermissionError.missing }
        try await wait { controller.phase == .idle }
        #expect(dependencies.microphones[1].stopped > 0)
        #expect(dependencies.sessions[1].cancelled > 0)
    }

    enum PreviousHold: CaseIterable, Sendable { case stock, custom, cleared, disabled, deleted, occupiedHere, occupiedElsewhere }
    @Test(arguments: PreviousHold.allCases) @MainActor func onlyTheStockHoldDefaultMigrates(_ previous: PreviousHold) throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let m = try pluginManifest(), deps = Dependencies()
        let store = PluginStore(directory: root, permissions: permissionCenter(), ordinaryHotKeyDriver: .init(register: { _, _ in {} }),
            modifierDriver: .init(start: { _ in {} }, secureInput: { false }, keyIsDown: { _ in false }), dictationFactory: { deps.controller(preferencesURL: $0) })
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        old["version"] = "1.2.3"; old["minimumHostVersion"] = "0.13.30"
        old.removeValue(forKey: "styles") // This manifest predates the HUD style contract.
        let tooOld = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(throws: PluginError.self) { try tooOld.validate() }
        var templates = try #require(old["templates"] as? [[String: Any]])
        let i = try #require(templates.firstIndex { $0["id"] as? String == "doubao.hold" })
        templates[i]["defaultHotKey"] = ["keyCode": 49, "modifiers": 6656, "key": "空格"]; old["templates"] = templates
        try store.installManifest(JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: old)))
        var hold = try #require(store.installed[0].commands.first { $0.templateID == "doubao.hold" })
        switch previous {
        case .stock: break
        case .custom: hold.hotKey = .init(mouseButton: 3); try store.saveCommand(hold, pluginID: m.id)
        case .cleared: hold.hotKey = nil; try store.saveCommand(hold, pluginID: m.id)
        case .disabled: hold.isEnabled = false; try store.saveCommand(hold, pluginID: m.id)
        case .deleted: store.removeCommand(hold.id, pluginID: m.id)
        case .occupiedHere:
            var other = try #require(store.installed[0].commands.first { $0.action == .toggleDoubaoDictation }); other.hotKey = .rightCommand
            try store.saveCommand(other, pluginID: m.id)
        case .occupiedElsewhere:
            let other = PluginManifest(schemaVersion: 1, id: "com.untitled.right-cmd-test", name: "Test", version: "1.0.0", summary: "Test", author: "Test", repository: HostInfo.repository, minimumHostVersion: "0.2.0", actions: [.showMainWindow], templates: [])
            try store.installManifest(other); try store.saveCommand(.init(action: .showMainWindow, hotKey: .rightCommand), pluginID: other.id)
        }
        var expected = try #require(store.installed.first { $0.id == m.id }?.commands)
        if previous == .stock { let j = try #require(expected.firstIndex { $0.id == hold.id }); expected[j].hotKey = .rightCommand }
        try store.installManifest(m); try store.installManifest(m)
        #expect(store.installed.first { $0.id == m.id }?.commands == expected && deps.sessions.isEmpty && deps.microphones.isEmpty)
    }

    @Test @MainActor func panelActionWorksWithoutAccessibilityAndNeverPresentsPermissionManagement() async throws {
        let d = Dependencies(), root = temporary(), m = try pluginManifest()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = HostPermissionCenter(drivers: [HostPermissionID.microphone, .accessibility].map { id in
            .init(descriptor: .init(id: id, title: id.rawValue, summary: "测试", symbol: "checkmark"),
                  status: { id == .microphone ? .authorized : .notGranted }, request: { Issue.record("Unexpected prompt") }, openSettings: {})
        })
        var presentations = 0; center.presentManagement = { presentations += 1 }
        let store = PluginStore(directory: root, permissions: center, ordinaryHotKeyDriver: .init(register: { _, _ in {} }),
                                dictationFactory: { d.controller(preferencesURL: $0) })
        try store.installManifest(m)
        let c = store.doubaoDictation(for: m.id)
        #expect(d.sessions.isEmpty && d.targetCaptures == 0 && d.copies.isEmpty)
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: m.id)
        try await wait { c.phase == .listening }; d.sessions[0].onTranscript?("面板开始")
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: m.id)
        try await wait { c.phase == .idle }
        #expect(d.targetCaptures == 0 && d.copies == [d.sessions[0].finalText] && c.notice.contains("已复制"))
        #expect(center.pendingRequest == nil && presentations == 0)
    }

    @Test @MainActor func installDisableUpgradeAndUninstallAreLazyAndKeepUserBindings() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = Dependencies()
        let center = permissionCenter()
        let store = PluginStore(directory: root, permissions: center,
                                dictationFactory: { dependencies.controller(preferencesURL: $0) })
        let manifest = try pluginManifest()
        try store.installManifest(manifest)
        #expect(dependencies.sessions.isEmpty)
        #expect(store.installed[0].commands.count == 3)
        #expect(Set(store.installed[0].commands.compactMap { $0.hotKey?.identity }).count == 3)
        let controller = store.doubaoDictation(for: manifest.id)
        var settings = controller.preferences
        settings.maximumSeconds = 60
        try controller.savePreferences(settings)
        await controller.history.record(id: UUID(), text: "历史记录")
        let command = store.installed[0].commands[0]
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id)
        try await wait { controller.phase == .listening }
        store.setEnabled(false, pluginID: manifest.id)
        #expect(controller.phase == .idle)
        #expect(dependencies.sessions[0].cancelled > 0)
        #expect(dependencies.microphones[0].stopped > 0)
        store.setEnabled(true, pluginID: manifest.id)
        var edited = command; edited.hotKey = nil
        try store.saveCommand(edited, pluginID: manifest.id)
        try store.installManifest(manifest)
        #expect(store.installed[0].commands.first(where: { $0.id == edited.id })?.hotKey == nil)
        #expect(store.doubaoDictation(for: manifest.id).preferences.maximumSeconds == 60)
        #expect(controller.history.entries.map(\.preview) == ["历史记录"])
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id)
        try await wait { controller.phase == .listening }
        #expect(await store.prepareForQuit())
        #expect(controller.phase == .idle)
        #expect(throws: PluginError.self) { try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id) }
        store.uninstall(manifest.id)
        #expect(store.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(manifest.id + ".json").path))
        let prefs = root.appendingPathComponent("Preferences/" + manifest.id + ".dictation.json")
        #expect(!FileManager.default.fileExists(atPath: prefs.path))
        await controller.history.record(id: UUID(), text: "过期结果")
        #expect(!FileManager.default.fileExists(atPath: DictationHistory.directory(for: prefs).path))
    }

    @Test @MainActor func tenCancelCyclesReleaseEachSessionAndMicrophone() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        for _ in 0..<10 {
            try controller.toggle()
            try await wait { controller.phase == .listening }
            controller.cancel()
            #expect(controller.phase == .idle)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(dependencies.sessions.count == 10)
        #expect(dependencies.sessions.allSatisfy { $0.cancelled == 1 && $0.onTranscript == nil && $0.onFailure == nil })
        #expect(dependencies.microphones.allSatisfy { $0.started == 1 && $0.stopped > 0 })
    }

    @Test @MainActor func bubbleCrossfadesToOneLineAndWidensWithoutTakingKeyboardFocus() async throws {
        _ = NSApplication.shared
        let d = Dependencies(), c = d.allowedController()
        try c.toggle(); defer { c.cancel() }
        try await wait { c.phase == .listening }
        let hud = DictationHUD(), key = NSApp.keyWindow
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let testProcess = ProcessInfo.processInfo.processIdentifier
        hud.show(controller: c); defer { hud.close() }
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == front)
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "doubao.dictation.hud" })
        #expect(!window.canBecomeKey && !window.canBecomeMain && window.styleMask.contains(.nonactivatingPanel))
        #expect(window.ignoresMouseEvents)
        let canvas = window.frame, session = d.sessions[0]
        if let screen = window.screen { #expect(abs(canvas.midX - screen.visibleFrame.midX) <= 1) }
        let stage = try #require(window.contentView as? DictationHUDStage)
        let content = try #require(stage.plate), compact = content.frame
        #expect(compact.size == DictationHUDStyle.defaults.compact && compact.minY == 0)
        #expect(compact.midX == stage.bounds.midX)
        if #available(macOS 26, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let glass = try #require(content as? NSGlassEffectView)
            #expect(glass.style == .regular && glass.contentView != nil)
        }
        func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let typed = view as? T { return typed }
            for child in view.subviews { if let match = first(type, in: child) { return match } }
            return nil
        }
        try await wait { first(DictationWaveView.self, in: content) != nil }
        let compactWave = try #require(first(DictationWaveView.self, in: content))
        let waveRect = compactWave.convert(compactWave.bounds, to: content)
        #expect(abs(waveRect.width - DictationWaveMotion.compactWidth) <= 1 && waveRect.height == DictationWaveMotion.slotHeight)
        #expect(abs(waveRect.midX - content.bounds.midX) <= 1 && abs(waveRect.midY - content.bounds.midY) <= 1 && waveRect.minY >= 4)
        func render(_ variant: String) async throws {
            guard let path = ProcessInfo.processInfo.environment["UNTITLED_DICTATION_HUD_PREVIEW"] else { return }
            try await Task.sleep(for: .milliseconds(700))
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let url = URL(fileURLWithPath: path)
            let out = variant.isEmpty ? url : url.deletingPathExtension().appendingPathExtension(variant + ".png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: out)
        }
        try await render("compact")
        session.onTranscript?("明天下午三点")
        try await wait { stage.openness == 1 && stage.wave == nil }
        let expanded = content.frame
        #expect(window.frame == canvas && expanded.height == DictationHUDStyle.defaults.expanded.height)
        #expect(expanded.width > compact.width && expanded.width < canvas.width)
        #expect(abs(expanded.midX - compact.midX) <= 1 && expanded.minY == compact.minY)
        #expect(first(DictationWaveView.self, in: content) == nil && compactWave.window == nil && !compactWave.isAnimating)
        let ink = try #require(first(DictationCaptionView.self, in: content))
        let inkFrame = ink.convert(ink.bounds, to: content)
        #expect(abs(inkFrame.width - DictationHUDStyle.defaults.captionWidth(in: content.bounds.width)) <= 1)
        #expect(abs(inkFrame.midY - content.bounds.midY) <= 1 && inkFrame.height == DictationHUDStyle.captionHeight)
        #expect(content.bounds.contains(inkFrame))
        let large = String(repeating: "这是一句话，然后是另一句话。", count: 32) + "注意：最后一行是最新的草稿。"
        session.onTranscript?(large)
        try await wait { abs(content.frame.width - canvas.width) < 0.01 }
        #expect(window.frame == canvas && content.frame.height == expanded.height && content.frame.midX == expanded.midX)
        #expect(c.bubblePreview.hasSuffix("最后一行是最新的草稿。") && stage.wave == nil)
        #expect(d.target.writes.isEmpty && NSApp.keyWindow === key)
        // The user's frontmost app can change while awaiting AppKit. What must
        // not happen is activation of our process by the nonactivating panel.
        if front != testProcess { #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != testProcess) }
        if ProcessInfo.processInfo.environment["UNTITLED_DICTATION_HUD_PREVIEW"] != nil {
            window.appearance = NSAppearance(named: .aqua); try await render("")
            window.appearance = NSAppearance(named: .darkAqua); try await render("dark")
            session.onTranscript?("明天下午 3 点，一起喝杯咖啡。"); try await render("short")
        }
        hud.close()
        #expect(!window.isVisible && !stage.isAnimating)
    }

    @Test @MainActor func twoZIPStylesUpdateTheSameRunningHostAndRejectInvalidUpdates() async throws {
        _ = NSApplication.shared
        let root = temporary(), source = root.appendingPathComponent("zip-source"), state = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: manifestURL)
        let original = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let name = DictationHUDStyle.name
        let styles = try #require(original["styles"] as? [String: [String: Any]])
        let baseline = try #require(styles[name])
        func zip(_ version: String, _ config: [String: Any]?, minimum: String = HostInfo.version) throws -> URL {
            var manifest = original
            manifest["version"] = version
            manifest["minimumHostVersion"] = minimum
            manifest["styles"] = config.map { [name: $0] }
            try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
            let archive = root.appendingPathComponent(UUID().uuidString + ".zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = source
            process.arguments = ["-q", archive.path, "manifest.json"]
            try process.run(); process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            return archive
        }
        let dependencies = Dependencies(), keys = EscapeKeys()
        let host = PluginStore(directory: state, permissions: permissionCenter(), ordinaryHotKeyDriver: keys.driver,
                               dictationFactory: { dependencies.controller(preferencesURL: $0, showsHUD: true) })
        let pluginID = DoubaoDictationController.pluginID
        await host.importPackage(try zip("900.0.1", baseline))
        try #require(host.installed.first?.manifest.version == "900.0.1")
        let command = PluginCommand(action: .toggleDoubaoDictation)
        try host.saveCommand(command, pluginID: pluginID)
        let activeController = host.doubaoDictation(for: pluginID)
        defer { activeController.cancel() }
        func openHUD() async throws -> DictationHUDStage {
            await host.execute(command, pluginID: pluginID)
            try await wait { activeController.phase == .listening }
            let panel = try #require(NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "doubao.dictation.hud" })
            #expect(!panel.canBecomeKey && panel.ignoresMouseEvents)
            return try #require(panel.contentView as? DictationHUDStage)
        }
        func renderCaption(in stage: DictationHUDStage) throws -> (width: CGFloat, greenMinusRed: CGFloat) {
            stage.configure(reduceMotion: true, solid: false)
            let session = try #require(dependencies.sessions.last)
            session.onTranscript?(String(repeating: "不过这一次只显示一行字幕。", count: 24))
            #expect(stage.openness == 1 && stage.wave == nil && stage.liquid.elapsed == 0 && !stage.isAnimating)
            let liquid = stage.liquid, bounds = liquid.bounds
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            liquid.draw(bounds)
            let pixels = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            let point = try #require(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            try #require(point.alphaComponent > 0.02)
            return (bounds.width, point.greenComponent - point.redComponent)
        }
        let first = try await openHUD()
        #expect(first.plate?.bounds.size == first.style.compact && first.wave != nil)
        let old = try renderCaption(in: first)
        #expect(old.width == 296)

        let record = state.appendingPathComponent(pluginID + ".json"), before = try Data(contentsOf: record)
        let invalidStyles: [[String: Any]] = [
            ["version": 2], ["version": 1, "maximumWidth": 1000], ["version": 1, "poolColors": ["#oops"]],
            ["version": 1, "compactHeight": 48, "expandedHeight": 49], ["version": 1, "unexpected": 13],
        ]
        for invalid in invalidStyles {
            host.errorMessage = nil
            await host.importPackage(try zip("900.0.2", invalid))
            #expect(host.errorMessage?.contains("安装失败") == true)
        }
        host.errorMessage = nil
        await host.importPackage(try zip("900.0.2", baseline, minimum: "0.13.50"))
        #expect(host.errorMessage?.contains("安装失败") == true)
        let afterInvalid = try Data(contentsOf: record)
        #expect(activeController.isBusy && afterInvalid == before)

        let alternative: [String: Any] = ["version": 1, "compactWidth": 102, "compactHeight": 42, "maximumWidth": 332,
                                         "expandedHeight": 56, "openingMilliseconds": 460, "driftSpeed": 0.7,
                                         "poolColors": Array(repeating: "#00DD00", count: 5)]
        await host.importPackage(try zip("900.0.2", alternative))
        #expect(host.installed.first?.manifest.version == "900.0.2" && host.installed.first?.commands.contains(command) == true)
        #expect(!activeController.isBusy && first.window == nil && !first.isAnimating)
        let second = try await openHUD()
        #expect(second.plate?.bounds.size == CGSize(width: 102, height: 42) && second.wave != nil)
        #expect(second.style.openingDuration == 0.46 && second.style.driftSpeed == 0.7)
        let new = try renderCaption(in: second)
        #expect(new.width == 332 && new.greenMinusRed > old.greenMinusRed + 0.20)
        second.configure(reduceMotion: true, solid: true)
        #expect(second.liquid.isHidden && !second.isAnimating)

        // An older manifest needs no style at all. A style rollback can be
        // packaged as a newer version without changing commands or the host.
        await host.importPackage(try zip("900.0.3", nil, minimum: "0.13.50"))
        #expect(host.installed.first?.commands.contains(command) == true)
        #expect(activeController.hudStyle() == .defaults)
        #expect(!activeController.isBusy && second.window == nil && !second.isAnimating)
        #expect(dependencies.target.writes.isEmpty && dependencies.copies.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor func syntheticPCMAnimatesActualPixelsEvenWhileASRIsBlocked(connecting: Bool) async throws {
        // No device, document, system pasteboard, network or visible test window.
        @MainActor final class Source: DictationAudioSource {
            let box = DictationAudioMailbox()
            var diagnostics: DictationAudioDiagnostics? { box.diagnostics() }
            var meterReadings: AsyncStream<DictationMeterReading>? { box.meterReadings }
            func start() throws {}
            func stop() { box.beginStopping() }
            func setStreaming() { box.setStreaming() }
            func validateBuffer() throws { try box.validate() }
            func read() throws -> (pcm: Data, level: Float) { try box.drain() }
        }
        let mic = Source(), session = Session()
        session.suspendStart = connecting; session.sendDelay = .seconds(15)
        let c = DoubaoDictationController(showsHUD: false, makeSession: { session }, makeMicrophone: { mic },
                        makeTarget: { throw DictationTargetError.unavailable }, copyFinal: { _ in Issue.record("Unexpected copy") })
        c.isAllowed = { true }; c.requirePermissions = { _ in }
        try c.toggle(); defer { c.cancel() }
        try await wait { connecting ? session.started == 1 : c.phase == .listening }
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: DictationWaveMotion.expandedWidth, height: DictationWaveMotion.slotHeight)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let wave = DictationWaveView(frame: rect); window.contentView = wave
        wave.bind(c.waveReadings, reduceMotion: false)
        func pixels() throws -> (core: CGFloat, outer: CGFloat, runs: Int, left: CGFloat, right: CGFloat) {
            let bitmap = try #require(wave.bitmapImageRepForCachingDisplay(in: wave.bounds))
            wave.cacheDisplay(in: wave.bounds, to: bitmap)
            let sx = rect.width / CGFloat(bitmap.pixelsWide), sy = rect.height / CGFloat(bitmap.pixelsHigh)
            var core: CGFloat = 0, outer: CGFloat = 0, runs = 0, wasInk = false
            var left = rect.maxX, right = rect.minX
            for x in 2..<(bitmap.pixelsWide - 2) {
                let d = abs((CGFloat(x) + 0.5) * sx - rect.midX)
                var ink = false
                // Measure the raised stems, not the low-alpha colour passing between them.
                for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x,y: y)?.alphaComponent ?? 0) > 0.5 {
                    let h = abs((CGFloat(y) + 0.5) * sy - rect.midY); ink = true
                    if d < 23 { core = max(core,h) }
                    if (44...75).contains(d) { outer = max(outer,h) }
                }
                if ink {
                    if !wasInk { runs += 1 }
                    left = min(left, CGFloat(x) * sx); right = CGFloat(x+1) * sx
                }
                wasInk = ink
            }
            return (core,outer,runs,left,right)
        }
        let rest = try pixels()
        #expect(rest.runs == 31 && rest.core <= 2 && rest.outer <= 2)
        #expect(rest.left < 6 && rest.right > rect.width - 6)
        let samples = (0..<320).map { i in Int16((583.4 * sin(2 * .pi * Double(i) / 64)).rounded()).littleEndian }
        let audio = samples.withUnsafeBytes { Data($0) }, zero = Data(repeating: 0, count: 640)
        var peak = rest.core, outer = rest.outer
        for _ in 0..<8 {
            mic.box.append(audio); mic.box.append(audio)
            try await Task.sleep(for: .milliseconds(40))
            let frame = try pixels()
            peak = max(peak,frame.core); outer = max(outer,frame.outer)
            #expect(frame.runs == rest.runs && abs(frame.left-rest.left) <= 1 && abs(frame.right-rest.right) <= 1)
        }
        #expect(peak - rest.core >= 3 && outer - rest.outer >= 2 && wave.isAnimating)
        #expect(connecting ? (c.phase == .connecting && session.sentBytes == 0) : (c.phase == .listening && session.sentBytes > 0))
        mic.box.append(zero); mic.box.append(zero)
        try await wait { c.waveReadings.value.rms == 0 }
        try await wait { !wave.isAnimating }
        let end = try pixels()
        #expect(end == rest)
        c.cancel(); mic.box.append(audio); mic.box.append(audio)
        #expect(c.waveReadings.value == .quiet && !wave.isAnimating && c.history.entries.isEmpty)
    }

    @Test @MainActor func clipboardReceiptIsStaticNonactivatingAndReleasedOnTimeoutOrNextSession() async throws {
        _ = NSApplication.shared
        let d = Dependencies(), c = d.controller(showsHUD: true)
        d.unsupported = true; c.isAllowed = { true }; c.requirePermissions = { _ in }
        defer { c.cancel() }
        for round in 0..<2 {
            let testProcess = ProcessInfo.processInfo.processIdentifier
            let startedInBackground = NSWorkspace.shared.frontmostApplication?.processIdentifier != testProcess
            let key = NSApp.keyWindow
            try c.toggle(); try await wait { c.phase == .listening }
            let window = try #require(NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "doubao.dictation.hud" })
            let frame = window.frame
            d.sessions[round].onTranscript?("只有草稿会淡入")
            c.stopRecording(); try await wait { c.phase == .idle }
            #expect(window.isVisible && window.frame == frame && window.ignoresMouseEvents && !window.canBecomeKey)
            #expect(window.contentView != nil && !(window.contentView is DictationHUDStage))
            #expect(NSApp.keyWindow === key)
            if startedInBackground {
                #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != testProcess)
            }
            #expect(d.copies.count == round + 1 && d.microphones[round].stopped > 0 && d.sessions[round].cancelled > 0)
            if round == 0 { try await wait { !window.isVisible } }
            else { try c.toggle(); #expect(!window.isVisible); c.cancel() }
            #expect(window.contentView == nil)
        }
    }

    enum Outcome: CaseIterable, Sendable {
        case noFieldToField, fieldToTwin, movedBeforeFinal, editedBeforeFinal, fieldToNone, readOnly,
             focusRace, caretRace, editRace, lostACK, copyFailure, cancel, empty
    }
    @Test(arguments: Outcome.allCases) @MainActor func realTextViewsAndPrivateBoardRouteOnlyTheFinal(_ outcome: Outcome) async throws {
        let root = temporary(), prefs = root.appendingPathComponent("test.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let field = FixtureEditor(), session = Session(), mic = Microphone(), command = UUID()
        let board = NSPasteboard.withUniqueName(), sentinel = "测试夹具的原剪贴板"
        defer { board.releaseGlobally() }
        try DictationClipboard.write(sentinel, to: board)
        let initialCount = board.changeCount
        var copies = 0, captures = 0
        if outcome == .noFieldToField { field.active = nil }
        let c = DoubaoDictationController(preferencesURL: prefs, showsHUD: false, deliveryBudget: .milliseconds(240),
            makeSession: { session }, makeMicrophone: { mic },
            makeTarget: {
                captures += 1
                let bound = try field.capture()
                // Change *after* the final resolved its destination and before the first event.
                switch outcome {
                case .focusRace: field.active = field.twin
                case .caretRace: field.field.setSelectedRange(NSRange(location: 0, length: 0))
                case .editRace: field.field.string = "用户在投递时编辑"
                default: break
                }
                return bound
            }, copyFinal: { text in
                copies += 1
                if outcome == .copyFailure { throw PluginError.invalid("模拟剪贴板不可用") }
                try DictationClipboard.putFinal(text, on: board)
            })
        c.isAllowed = { true }; c.requirePermissions = { _ in }; c.hasInsertionAccess = { true }
        try c.holdPressed(command); defer { c.cancel() }
        try await wait { c.phase == .listening }
        let original = field.field.string, selection = field.field.selectedRange()
        for i in 1...35 {
            let update = "草稿" + String(i); session.onTranscript?(update)
            #expect(c.bubblePreview == update && field.insertions.isEmpty && captures == 0 && copies == 0)
            #expect(field.field.string == original && field.field.selectedRange() == selection && board.changeCount == initialCount)
        }
        if outcome == .cancel {
            c.cancel()
            #expect(captures == 0 && field.insertions.isEmpty && copies == 0 && board.changeCount == initialCount)
            #expect(session.finished == 0 && c.history.entries.isEmpty); return
        }
        session.finishUpdates = ["收尾修订"]; session.finishDelay = .milliseconds(120)
        session.finalText = outcome == .empty ? "" : String(repeating: "定稿😀", count: 40) + "。\n第二行。"
        c.holdReleased(command); c.holdReleased(command)
        try await wait { c.bubblePreview == "收尾修订" }
        #expect(captures == 0 && copies == 0 && field.insertions.isEmpty && board.changeCount == initialCount)
        switch outcome {
        case .noFieldToField: field.active = field.field
        case .fieldToTwin: field.active = field.twin
        case .movedBeforeFinal: field.field.setSelectedRange(NSRange(location: 0, length: 0))
        case .editedBeforeFinal: field.field.string = "改选新的文字"; field.field.setSelectedRange(NSRange(location: 2, length: 2))
        case .fieldToNone, .copyFailure: field.active = nil
        case .readOnly: field.field.isEditable = false
        case .lostACK: field.loseACK = true
        default: break
        }
        let chosen = field.active, before = chosen?.string, range = chosen?.selectedRange()
        try await wait { c.phase == .idle }
        if outcome == .empty {
            #expect(captures == 0 && copies == 0 && field.insertions.isEmpty && board.changeCount == initialCount)
            #expect(c.history.entries.isEmpty && c.resultText == "收尾修订"); return
        }
        try await wait { c.history.entries.count == 1 }
        let id = try #require(c.finalResultID)
        #expect(try await c.history.text(for: id) == session.finalText)
        #expect(captures == 1 && c.bubblePreview.isEmpty && c.resultText == session.finalText && session.finished == 1)
        if [.noFieldToField, .fieldToTwin, .movedBeforeFinal, .editedBeforeFinal, .lostACK].contains(outcome) {
            let view = try #require(chosen), range = try #require(range), before = try #require(before)
            let safe = DictationTextTarget.keyboardSafeText(session.finalText)
            #expect(view.string == (before as NSString).replacingCharacters(in: range, with: safe))
            #expect(view.selectedRange() == NSRange(location: range.location + safe.utf16.count, length: 0))
            let untouched = view === field.twin ? field.field : field.twin
            #expect(untouched.string == original && untouched.selectedRange() == selection && field.insertions == [safe])
            if outcome != .lostACK {
                #expect(c.notice.isEmpty && copies == 0 && board.changeCount == initialCount && board.string(forType: .string) == sentinel)
                return
            }
            #expect(c.notice.contains("粘贴前请核对"))
        } else {
            #expect(field.insertions.isEmpty && field.twin.string == original && field.twin.selectedRange() == selection)
            #expect(field.field.string == (outcome == .editRace ? "用户在投递时编辑" : original))
            if outcome == .caretRace { #expect(field.field.selectedRange() == NSRange(location: 0, length: 0)) }
        }
        #expect(copies == 1 && c.acknowledgedTextLength == 0)
        if outcome == .copyFailure {
            #expect(board.changeCount == initialCount && c.notice.contains("未能复制") && !c.notice.contains("已复制"))
        } else {
            #expect(board.string(forType: .string) == session.finalText && board.changeCount != initialCount)
            #expect(board.types?.contains(.init("org.nspasteboard.AutoGeneratedType")) == true && c.notice.contains("已复制"))
        }
    }

    @MainActor private final class FixtureEditor: DictationEditor {
        let field = NSTextView(), twin = NSTextView()
        var active: NSTextView?, bound: NSTextView?
        var insertions: [String] = [], loseACK = false
        init() {
            active = field
            for view in [field,twin] {
                view.isRichText = false; view.isAutomaticTextReplacementEnabled = false
                view.string = "前😀选中后"; view.setSelectedRange(NSRange(location: 3, length: 2))
            }
        }
        func capture() throws -> DictationTextTarget {
            guard let active, active.isEditable else { throw DictationTargetError.unavailable }
            bound = active
            return try DictationTextTarget(editor: self, snapshot: read())
        }
        func validateFocus() throws {
            guard let bound, active === bound, bound.isEditable else { throw DictationTargetError.changed }
        }
        func read() throws -> DictationEditorSnapshot {
            try validateFocus()
            let view = try #require(bound)
            return .init(value: view.string, selection: view.selectedRange())
        }
        func snapshot() throws -> DictationEditorSnapshot {
            if loseACK && !insertions.isEmpty { throw DictationTargetError.unavailable }
            return try read()
        }
        func insert(_ text: String, replacing expected: DictationEditorSnapshot) throws {
            guard try read().matches(expected) else { throw DictationTargetError.changed }
            let source = try #require(CGEventSource(stateID: .privateState))
            let event = try DictationUnicodeInput.keyDown(text, source: source)
            let characters = try #require(NSEvent(cgEvent: event)?.characters)
            insertions.append(characters)
            bound?.insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    @Test @MainActor func nativeCapabilityRequiresCorrectHostAndPermissionDeclarations() throws {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        try PluginComposition.makeUIRegistry().validate(manifest)
        try permissionCenter().validate(manifest)
        #expect(manifest.permissions?.first { $0.id == .accessibility }?.isOptional == true)
        #expect(manifest.permissions?.first { $0.id == .microphone }?.isOptional == false)
        #expect(!ActionKind.toggleDoubaoDictation.isScreenshotAction)
        #expect(!ActionKind.holdDoubaoDictation.isScreenshotAction)
        #expect(!ActionKind.cancelDoubaoDictation.isScreenshotAction)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["minimumHostVersion"] = "0.9.7"
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(throws: PluginError.self) { try JSONDecoder().decode(PluginManifest.self, from: oldData).validate() }
    }

    @Test @MainActor func historyKeepsTheNewestHundredAcrossRestartAndCopiesTheFullText() async throws {
        let root = temporary(), prefs = root.appendingPathComponent("test.dictation.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = DictationHistory(preferencesURL: prefs)
        await history.load()
        #expect(history.limit == 100 && history.entries.isEmpty && history.isLoaded)
        #expect(!FileManager.default.fileExists(atPath: DictationHistory.directory(for: prefs).path))
        let full = String(repeating: "这是测试。😀", count: 80) + "\n原始文本结尾"
        let firstID = UUID(), lastID = UUID()
        for index in 0...100 {
            await history.record(id: index == 0 ? firstID : (index == 100 ? lastID : UUID()),
                                 text: index == 100 ? full : "第\(index)条")
        }
        let reopened = DictationHistory(preferencesURL: prefs)
        await reopened.load()
        #expect(reopened.entries.count == 100 && reopened.entries.first?.id == lastID)
        #expect(reopened.entries.last?.preview == "第1条" && reopened.entries.first?.preview != full)
        await #expect(throws: PluginError.self) { try await reopened.text(for: firstID) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try await DictationClipboard.copy(lastID, from: reopened, to: board)
        #expect(board.string(forType: .string) == full)
    }

    @Test @MainActor func historyLimitChangesTrimImmediatelyWithoutResurrectingOldText() async throws {
        let root = temporary(), prefs = root.appendingPathComponent("test.dictation.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = DictationHistory(preferencesURL: prefs), a = UUID(), b = UUID()
        await history.record(id: a, text: "相同文字"); await history.record(id: b, text: "相同文字")
        await history.record(id: UUID(), text: " \n ")
        #expect(history.entries.map(\.id) == [b, a])
        try await history.setLimit(1)
        #expect(history.entries.map(\.id) == [b])
        for invalid in [-1, DictationHistory.limits.upperBound + 1] {
            await #expect(throws: PluginError.self) { try await history.setLimit(invalid) }
        }
        let reopened = DictationHistory(preferencesURL: prefs)
        await reopened.load()
        #expect(reopened.limit == 1 && reopened.entries.map(\.id) == [b])
        try await reopened.setLimit(0)
        await reopened.record(id: UUID(), text: "不应保存")
        try await reopened.setLimit(36)
        #expect(reopened.entries.isEmpty)
        await reopened.record(id: UUID(), text: "新结果")
        try await reopened.clear()
        let cleared = DictationHistory(preferencesURL: prefs)
        await cleared.load()
        #expect(cleared.limit == 36 && cleared.entries.isEmpty)
    }

    @Test @MainActor func unreadableHistoryDoesNotClobberTheFileOrPreventDictation() async throws {
        let root = temporary(), prefs = root.appendingPathComponent("test.dictation.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = DictationHistory.directory(for: prefs)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("records.sqlite3"), original = Data("not a database".utf8)
        try original.write(to: file)
        let dependencies = Dependencies(), controller = dependencies.controller(preferencesURL: prefs)
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        await controller.history.load()
        #expect(controller.history.issue != nil && !controller.history.isLoaded)
        try controller.toggle(); try await wait { controller.phase == .listening }
        controller.stopRecording(); try await wait { controller.phase == .idle }
        #expect(controller.lastResult == dependencies.sessions[0].finalText)
        try await wait { controller.history.issue?.contains("未能保存") == true }
        #expect(controller.history.entries.isEmpty)
        #expect(try Data(contentsOf: file) == original)
    }

    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Plugins/doubao-speech-input/manifest.json")
    }
    private func pluginManifest() throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PluginError.invalid("等待模拟听写状态超时。")
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor private func permissionCenter() -> HostPermissionCenter {
        HostPermissionCenter(drivers: [HostPermissionID.microphone, .accessibility].map { id in
            HostPermissionDriver(descriptor: .init(id: id, title: id.rawValue, summary: "测试", symbol: "checkmark"),
                                 status: { .authorized }, request: {}, openSettings: {})
        })
    }

    @MainActor private final class EscapeKeys {
        static let bare = "\(kVK_Escape):0"
        static let withCommand = "\(kVK_Escape):\(cmdKey)"
        var occupied: Set<String> = []
        var handlers: [String: @MainActor (Bool) -> Void] = [:]
        var driver: HotKeyManager.Driver {
            .init(register: { [self] key, callback in
                let id = key.identity
                guard handlers[id] == nil, !occupied.contains(id) else { throw PluginError.invalid("模拟快捷键占用") }
                handlers[id] = callback
                return { [self] in handlers.removeValue(forKey: id) }
            })
        }
    }

    @MainActor private final class Dependencies {
        var sessions: [Session] = []
        var microphones: [Microphone] = []
        let target = Target()
        var targetCaptures = 0, insertionChecks = 0, insertionAccess = true
        var copies: [String] = []
        var secure = false, unsupported = false, suspendStart = false
        var startDelay: Duration = .zero
        var recognitionBudget: Duration = .seconds(18), deliveryBudget: Duration = .seconds(4)
        func controller(preferencesURL: URL? = nil, showsHUD: Bool = false) -> DoubaoDictationController {
            let controller = DoubaoDictationController(preferencesURL: preferencesURL, showsHUD: showsHUD, recognitionBudget: recognitionBudget, deliveryBudget: deliveryBudget, makeSession: { [self] in
                let session = Session(); session.suspendStart = suspendStart; session.startDelay = startDelay; sessions.append(session); return session
            }, makeMicrophone: { [self] in
                let microphone = Microphone(); microphones.append(microphone); return microphone
            }, makeTarget: { [self] in
                targetCaptures += 1
                if secure { throw DictationTargetError.secure }
                if unsupported { throw DictationTargetError.unavailable }
                return target
            }, copyFinal: { [self] in copies.append($0) })
            controller.hasInsertionAccess = { [self] in insertionChecks += 1; return insertionAccess }
            return controller
        }
        func allowedController() -> DoubaoDictationController {
            let result = controller(); result.isAllowed = { true }; result.requirePermissions = { _ in }; return result
        }
    }
    @MainActor private final class Session: DoubaoSpeechSession {
        var onTranscript: ((String) -> Void)?
        var onFailure: ((Error) -> Void)?
        var started = 0, cancelled = 0, finished = 0, sentBytes = 0
        var suspendStart = false
        var finalText = "下午 3 点。"
        var finishUpdates: [String] = []
        var finishDelay: Duration = .zero
        var startDelay: Duration = .zero, sendDelay: Duration = .zero
        func start() async throws {
            started += 1
            if suspendStart { try await Task.sleep(for: .seconds(60)) }
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
        }
        func send(_ pcm: Data) async throws {
            sentBytes += pcm.count
            if sendDelay > .zero { try await Task.sleep(for: sendDelay) }
        }
        func finish() async throws -> String {
            finished += 1
            for text in finishUpdates { onTranscript?(text); try await Task.sleep(for: .milliseconds(20)) }
            if finishDelay > .zero { try await Task.sleep(for: finishDelay) }
            if !finalText.isEmpty { onTranscript?(finalText) }
            return finalText
        }
        func cancel() { cancelled += 1; onTranscript = nil; onFailure = nil }
    }
    @MainActor private final class Microphone: DictationAudioSource {
        var started = 0, stopped = 0
        var buffered = Data()
        var configuredUID: String?
        var currentDiagnostics: DictationAudioDiagnostics?
        var diagnostics: DictationAudioDiagnostics? { currentDiagnostics }
        func configureInputDevice(_ uid: String?) throws { configuredUID = uid }
        func start() throws { started += 1; buffered = Data(repeating: 0, count: 640) }
        func read() throws -> (pcm: Data, level: Float) { let value = buffered; buffered = Data(); return (value, 0) }
        func setStreaming() {}
        func validateBuffer() throws {}
        func stop() { stopped += 1 }
    }
    @MainActor private final class Target: DictationFinalInserting {
        var writes: [String] = []
        var changed = false
        var delay: Duration = .zero
        private(set) var finalCalls = 0
        var blockFinal = false
        var blockedFinal: CheckedContinuation<Void, Never>?
        func commitFinal(_ text: String) async throws {
            finalCalls += 1
            if blockFinal {
                blockFinal = false
                await withCheckedContinuation { blockedFinal = $0 }
                try Task.checkCancellation()
            }
            if delay > .zero { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            if changed { throw DictationTargetError.changed }
            writes.append(text)
        }
    }
}
