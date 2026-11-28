import AppKit
import Network
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized) struct SharingCursorTests {
    @Test func failedDisassociationBalancesOnlyTheHide() throws {
        let system = CursorSystem(); system.set("detach", .failure)
        let resources = system.resources()
        #expect(throws: SharingCursorInterruption.self) { try resources.acquire() }
        #expect(system.calls == ["hide", "detach", "show"] && !resources.isActive && !resources.needsRecovery)
    }

    @Test func failedHideNeverDetachesOrShowsAnUnownedCursor() throws {
        let system = CursorSystem(); system.set("hide", .failure)
        let resources = system.resources()
        #expect(throws: SharingCursorInterruption.self) { try resources.acquire() }
        #expect(system.calls == ["hide"] && !resources.isActive && !resources.needsRecovery)
    }

    @Test func releaseIsBalancedAndIdempotent() throws {
        let system = CursorSystem(), point = CGPoint(x: 50, y: 40)
        let resources = system.resources(), token = try resources.acquire()
        var sent = 0
        #expect(resources.withActiveCapture(token: token) { sent += 1 })
        #expect(resources.release(warp: point).isEmpty)
        #expect(resources.release(warp: point).isEmpty)
        #expect(system.calls == ["hide", "detach", "warp", "reattach", "show"])
        #expect(!resources.withActiveCapture(token: token) { sent += 1 } && sent == 1)
    }
    @Test func failedRecoveryRetainsOwnershipAndBlocksAnotherCapture() throws {
        let system = CursorSystem(), resources = system.resources()
        try resources.acquire(); system.set("show", .failure)
        #expect(!resources.release().isEmpty && resources.needsRecovery && !resources.isActive)
        #expect(throws: PluginError.self) { try resources.acquire() }
        system.set("show", .success); resources.expireIfStalled()
        #expect(!resources.needsRecovery && system.calls.filter { $0 == "show" }.count == 2)
        #expect(system.calls.filter { $0 == "reattach" }.count == 1)
    }
    @Test func parkedPanelAndRegionAreReleasedInOrder() throws {
        let system = CursorSystem()
        let resources = SharingCursorResources(calls: .init(associate: { system.call($0 ? "reattach" : "detach") },
            hide: { system.call("hide") }, show: { system.call("show") }, warp: { _ in system.call("warp") },
            takeCursorRegion: { system.call("region") == .success }, releaseCursorRegion: { system.call("unlockRegion") }), watchdogEnabled: false)
        let token = try resources.acquire()
        let owner = SharingCursorPanelLease(retireGlyph: { _ = system.call("retireGlyph") }, withdraw: { system.call("withdraw") == .success })
        #expect(resources.placePanel(owner, token: token, show: { _ = system.call("present") }))
        #expect(resources.confirmPanel(token: token, setGlyph: { system.call("setGlyph") == .success }))
        #expect(resources.snapshot["cursorOwnerAcknowledged"] as? Bool == true)
        #expect(resources.release(warp: CGPoint(x: 50, y: 40)).isEmpty)
        #expect(system.calls == ["region", "hide", "detach", "present", "setGlyph", "warp", "retireGlyph", "withdraw", "reattach", "show", "unlockRegion"])
    }
    @Test func rejectedGlyphKeepsTheHideAndCleanupCanStillRetry() throws {
        let system = CursorSystem(), resources = system.resources()
        let token = try resources.acquire()
        #expect(resources.placePanel(.init(retireGlyph: {}, withdraw: { system.call("withdraw") == .success }), token: token, show: {}))
        system.set("show", .failure); system.set("withdraw", .failure)
        #expect(!resources.confirmPanel(token: token, setGlyph: { false }))
        #expect(resources.isActive(token: token) && !system.calls.contains("show"))
        #expect(!resources.release().isEmpty && resources.needsRecovery)
        #expect(system.calls.filter { $0 == "hide" }.count == 1)
        system.set("show", .success); system.set("withdraw", .success); resources.expireIfStalled()
        #expect(!resources.needsRecovery && !resources.isActive(token: token))
    }
    @Test func watchdogRevokesTheOldTokenBeforeRestoringMouse() throws {
        let system = CursorSystem(), resources = system.resources()
        let old = try resources.acquire()
        system.time = 1_100_000_000; resources.expireIfStalled()
        #expect(!resources.isActive(token: old) && !resources.needsRecovery)
        #expect(!resources.withActiveCapture(token: old) { Issue.record("Stale capture forwarded") })
        let fresh = try resources.acquire()
        #expect(fresh != old && resources.isActive(token: fresh))
        resources.heartbeat(token: old)
        #expect(!resources.withActiveCapture(token: old) { Issue.record("Old watchdog generation revived") })
        resources.release()
    }
    @Test func diagnosticHardDeadlineCannotBeExtendedByHeartbeats() throws {
        let system = CursorSystem(), resources = system.resources()
        let token = try resources.acquire(maximumDuration: 1)
        system.time = 900_000_000; resources.heartbeat(token: token)
        system.time = 1_010_000_000; resources.expireIfStalled()
        #expect(!resources.isActive(token: token) && !resources.needsRecovery)
        for duration in [-1.0, .nan, .infinity, 11] {
            #expect(throws: PluginError.self) { try resources.acquire(maximumDuration: duration) }
        }
    }
    @Test @MainActor func independentHardDeadlineRestoresEvenWithMainThreadBlocked() throws {
        let system = CursorSystem()
        let resources = SharingCursorResources(calls: SharingCursorCalls(
            associate: { system.call($0 ? "reattach" : "detach") }, hide: { system.call("hide") },
            show: { system.call("show") }, warp: { _ in system.call("warp") }), watchdogEnabled: true)
        let token = try resources.acquire(maximumDuration: 0.1)
        // The test blocks only its own main thread; all CG calls above are fakes.
        Thread.sleep(forTimeInterval: 0.35)
        #expect(!resources.isActive(token: token) && !resources.needsRecovery)
        #expect(system.calls == ["hide", "detach", "reattach", "show"])
        #expect(!resources.withActiveCapture(token: token) { Issue.record("Expired diagnostic forwarded") })
    }
    @Test @MainActor func tapTimeoutReleasesTheFakeCaptureWithoutForwarding() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true })
        var sent = 0, failures = 0
        input.send = { _ in sent += 1 }; input.failure = { _ in failures += 1 }
        try await input.capture()
        #expect(!input.handle(.tapDisabledByTimeout, try motion()))
        #expect(sent == 0 && failures == 1 && input.mode == .local && !resources.isActive && !resources.needsRecovery)
        input.stop()
    }
    @Test func overdueHeartbeatAndForwardingCannotReviveBeforeWatchdogDispatch() throws {
        let system = CursorSystem(), resources = system.resources()
        let token = try resources.acquire()
        system.time = 1_010_000_000
        resources.heartbeat(token: token) // Deliberately before the watchdog gets CPU time.
        #expect(!resources.withActiveCapture(token: token) { Issue.record("Overdue heartbeat revived a lease") })
        #expect(resources.snapshot["watchdogExpired"] as? Bool == true)
        resources.expireIfStalled()
        #expect(!resources.needsRecovery)
        let second = try resources.acquire(maximumDuration: 0.1)
        system.time = 1_120_000_000
        #expect(!resources.withActiveCapture(token: second) { Issue.record("Hard deadline waited for timer dispatch") })
        resources.release()
    }
    @Test @MainActor func watchdogIsNotBlockedByAnArbitraryMainThreadSendCallback() throws {
        let system = CursorSystem(), resources = system.resources(watchdogEnabled: true, realClock: true)
        let token = try resources.acquire(maximumDuration: 0.1)
        let accepted = resources.withActiveCapture(token: token) {
            // This pre-authorized callback may be in flight, but must not hold the watchdog lock.
            Thread.sleep(forTimeInterval: 0.35)
            #expect(!resources.isActive(token: token))
            #expect(system.calls.contains("reattach") && system.calls.contains("show"))
        }
        #expect(accepted)
        #expect(!resources.withActiveCapture(token: token) { Issue.record("A NEW frame passed after recovery") })
    }
    @Test @MainActor func watchdogCanRevokeWhileACGAcquisitionCallIsStalled() async throws {
        let system = CursorSystem(), unblock = DispatchSemaphore(value: 0)
        let resources = SharingCursorResources(calls: SharingCursorCalls(associate: { connected in
            if !connected { _ = system.call("detach"); unblock.wait(); return .success }
            return system.call("reattach")
        }, hide: { system.call("hide") }, show: { system.call("show") }, warp: { _ in system.call("warp") }))
        let attempt = Task.detached { try resources.acquire(maximumDuration: 0.1) }
        #expect(await wait { system.calls.contains("detach") })
        try? await Task.sleep(for: .milliseconds(350))
        #expect(resources.snapshot["watchdogExpired"] as? Bool == true)
        unblock.signal()
        switch await attempt.result { case .success: Issue.record("Overdue CG acquisition committed"); case .failure: break }
        #expect(await wait { !resources.needsRecovery })
        #expect(system.calls == ["hide", "detach", "reattach", "show"])
    }
    @Test @MainActor func failedReassociationBlocksCaptureUntilWatchdogRecovery() async throws {
        let system = CursorSystem(), resources = system.resources(), surface = CursorSurface()
        let capture = SharingCursorCapture(resources: resources, surface: surface)
        try await acquire(capture)
        system.set("reattach", .failure)
        #expect(!capture.release().isEmpty && !surface.isPresented && resources.needsRecovery)
        await #expect(throws: SharingCursorInterruption.self) { try await acquire(capture) }
        system.set("reattach", .success); resources.expireIfStalled()
        #expect(!resources.needsRecovery)
        try await acquire(capture); capture.release()
    }

    @Test @MainActor func oldRecoveryRequestCannotClearANewerCaptureGeneration() async throws {
        let system = CursorSystem(), resources = system.resources(watchdogEnabled: true)
        try resources.acquire(); resources.release()
        let oldGeneration = try #require(resources.snapshot["leaseGeneration"] as? UInt64)
        let fresh = try resources.acquire()
        resources.scheduleRecovery(forGeneration: oldGeneration)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(resources.isActive(token: fresh))
        #expect(system.calls.filter { $0 == "reattach" }.count == 1)
        #expect(system.calls.filter { $0 == "show" }.count == 1)
        resources.release()
    }
    @Test @MainActor func pendingRecoveryRefusesBothEnablingAndReceiving() async throws {
        let domain = "cursor-receive-recovery-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: domain)!, system = CursorSystem(), focus = CursorSurface()
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in system.call("receiveWarp") })
        let controller = PeripheralSharingController(defaults: settings, input: input)
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { system.set("reattach", .success); controller.stop(); settings.removePersistentDomain(forName: domain) }
        try controller.start(key: SharingPairingKey.generate(), localOnly: true)
        try await input.capture(); system.set("reattach", .failure)
        #expect(!input.reset().isEmpty && input.needsRecovery)
        #expect(throws: PluginError.self) { try controller.setKeyboardMouse(true) }
        #expect(throws: PluginError.self) { try input.receive(edge: .right, fraction: 0.5) }
        #expect(input.mode == .local && !controller.keyboardMouseEnabled)
        #expect(!system.calls.contains("receiveWarp")) // The fake receiver backend is never reached.
    }
    @Test @MainActor func missingBackgroundInterfaceDoesNotBlockNativeFreeze() throws {
        let system = CursorSystem(), surface = CursorSurface()
        let resources = SharingCursorResources(calls: .init(associate: { system.call($0 ? "reattach" : "detach") },
            hide: { system.call("hide") }, show: { system.call("show") }, warp: { _ in .success },
            enableBackground: { .failure }), watchdogEnabled: false)
        let capture = SharingCursorCapture(resources: resources, surface: surface)
        try capture.acquire(tapReady: { true }, neutral: { true })
        #expect(system.calls == ["hide", "detach"] && capture.isCaptured && !surface.isPresented)
        #expect(capture.release().isEmpty && system.calls == ["hide", "detach", "reattach", "show"])
    }

    @Test @MainActor func driftIsOnlyDiagnosticWhileTheLeaseIsLive() async throws {
        let system = CursorSystem(), surface = CursorSurface()
        let capture = SharingCursorCapture(resources: system.resources(), surface: surface)
        try await acquire(capture)
        #expect(capture.isCaptured && surface.isPresented)
        surface.position = CGPoint(x: 60, y: 40)
        try capture.validate(tapReady: true)
        capture.observeDrift()
        #expect(capture.maximumDrift == 10 && capture.isCaptured)
        #expect(capture.release().isEmpty && !surface.isPresented && !capture.isCaptured)
    }

    @Test @MainActor func changingForegroundDoesNotEndAnActiveHandoffOrDisableForwarding() async throws {
        let surface = CursorSurface(); var foreground: pid_t = 12, sent = 0
        let input = SharingInput(cursor: .init(resources: CursorSystem().resources(), surface: surface),
                                 tapReadyOverride: { true }, frontmostPID: { foreground })
        input.send = { _ in sent += 1 }
        defer { input.stop() }
        try await input.capture()
        foreground = 34
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        input.maintainCapture()
        #expect(input.isCapturing)
        #expect(input.handleEventTap(.mouseMoved, try motion()) && sent == 1)
    }

    @Test @MainActor func missingPanelHitKeepsTheLeaseAndDoesNotMoveTheCursor() async throws {
        let surface = CursorSurface(), system = CursorSystem()
        surface.isHittable = false; surface.inset = CGPoint(x: 30, y: 40)
        let capture = SharingCursorCapture(resources: system.resources(), surface: surface, ownerWait: .milliseconds(30))
        defer { capture.release() }
        try capture.acquire(tapReady: { true }, neutral: { true })
        capture.updateAppearance(avoidSystemEdges: true)
        #expect(await wait { capture.snapshot["cursorOwnerStage"] as? String == "window-not-owned" })
        #expect(surface.glyphSets == 0 && !surface.isPresented && capture.isCaptured)
        #expect(system.calls == ["hide", "detach"])
        #expect(capture.release().isEmpty && system.calls.suffix(2) == ["reattach", "show"])
    }

    @Test @MainActor func captureAnchorStartsAfterNativeFreeze() async throws {
        let surface = CursorSurface()
        let resources = SharingCursorResources(calls: SharingCursorCalls(associate: { associate in
            if !associate { MainActor.assumeIsolated { surface.position = CGPoint(x: 125, y: 40) } }
            return .success
        }, hide: { .success }, show: { .success }, warp: { _ in .success }), watchdogEnabled: false)
        let capture = SharingCursorCapture(resources: resources, surface: surface)
        try await acquire(capture)
        #expect(capture.isCaptured && capture.maximumDrift == 0 && surface.panelPoint?.x == 125)
        surface.position = CGPoint(x: 126, y: 40)
        try capture.validate(tapReady: true)
        capture.observeDrift()
        #expect(capture.maximumDrift == 1)
        capture.release()
    }

    @Test @MainActor func stagedCaptureCoalescesMotionWithoutWaitingForAppearance() async throws {
        let system = CursorSystem(), surface = CursorSurface()
        surface.isHittable = false
        var packets: [SharingInputPacket] = []
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface), tapReadyOverride: { true })
        defer { input.stop() }
        input.send = { packets.append($0) }
        try await input.capture(deferForwarding: true)
        #expect(input.isStaged && !input.isCapturing && surface.glyphSets == 0)
        for _ in 0..<2 { #expect(input.handle(.mouseMoved, try motion()) && packets.isEmpty) }
        try input.beginForwarding()
        #expect(input.isCapturing && packets == [.init(kind: .move, x: 10)] && surface.glyphSets == 0)
    }

    @Test @MainActor func stagedCaptureNeverFlushesAfterResetOrRevocation() async throws {
        for revoked in [false, true] {
            let system = CursorSystem(), surface = CursorSurface(), resources = system.resources()
            let input = SharingInput(cursor: .init(resources: resources, surface: surface), tapReadyOverride: { true })
            defer { input.stop() }
            var packets = 0; input.send = { _ in packets += 1 }
            try await input.capture(deferForwarding: true); _ = input.handle(.mouseMoved, try motion())
            if revoked { system.time = 1_100_000_000; resources.expireIfStalled() }
            else { input.reset() }
            #expect(throws: (any Error).self) { try input.beginForwarding() }
            #expect(packets == 0 && !input.isCapturing)
        }
    }


    @Test @MainActor func typingWhileStagedWithdrawsOutsideTapBeforeLocalReplay() async throws {
        let system = CursorSystem(), surface = CursorSurface(); var posted: [CGEvent] = [], packets = 0
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface), tapReadyOverride: { true },
                                 eventPoster: { posted.append($0) })
        input.send = { _ in packets += 1 }
        try await input.capture(deferForwarding: true)
        let key = try motion(); key.type = .keyDown
        #expect(input.handleEventTap(.keyDown, key) && !input.isNeutral)
        #expect(posted.isEmpty && packets == 0 && !input.isCapturing)
        #expect(throws: CancellationError.self) { try input.beginForwarding() }
        #expect(await wait { posted.count == 1 })
        #expect(!surface.isPresented)
        #expect(!input.handle(try #require(posted.first).type, try #require(posted.first)))
        input.stop()
    }

    @Test @MainActor func cancelledAppearanceCannotMoveOrCloseTheNextLease() async throws {
        let system = CursorSystem(), surface = CursorSurface()
        surface.isHittable = false; surface.inset = CGPoint(x: 30, y: 40)
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface, ownerWait: .milliseconds(80)),
                                 tapReadyOverride: { true }, receiverWarp: { _ in .success })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        #expect(await wait { surface.isPresented })
        input.reset()
        surface.isHittable = true
        try await input.capture()
        #expect(await wait { surface.glyphSets == 1 })
        try await Task.sleep(for: .milliseconds(90))
        #expect(input.isCapturing && surface.isPresented && surface.glyphSets == 1)
        #expect(system.calls.filter { $0 == "warp" }.count == 1) // Only the first lease's reset.
    }

    @Test @MainActor func senderNeverForwardsMotionAfterWatchdogRecovery() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
        let input = SharingInput(cursor: .init(resources: resources, surface: focus), tapReadyOverride: { true })
        var sent = 0, failures = 0
        input.send = { _ in sent += 1 }; input.failure = { _ in failures += 1 }
        defer { input.stop() }
        try await input.capture()
        system.time = 1_100_000_000; resources.expireIfStalled()
        #expect(!input.handle(.mouseMoved, try motion()))
        #expect(sent == 0 && failures == 1 && input.mode == .local && !resources.needsRecovery)
    }
    @Test @MainActor func foreignEventsAreNotForwardedAndDoNotDisableSharing() async throws {
        let system = CursorSystem(), focus = CursorSurface()
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true })
        var sent = 0, failures = 0
        input.send = { _ in sent += 1 }; input.failure = { _ in failures += 1 }
        try await input.capture()
        let own = try motion(); own.setIntegerValueField(.eventSourceUserData, value: SharingInput.replayMarker)
        own.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        #expect(!input.handle(.mouseMoved, own) && input.isCapturing && failures == 0)
        #expect(input.handle(.mouseMoved, try motion()) && sent == 1)
        let foreign = try motion(); foreign.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        #expect(!input.handle(.mouseMoved, foreign) && failures == 0 && sent == 1 && input.isCapturing)
        #expect(input.handle(.mouseMoved, try motion()) && sent == 2)
        input.stop()
    }
    @Test @MainActor func normalReentryIsImmediateButRejectedHandoffsKeepBoundedBackoff() throws {
        let system = CursorSystem(), focus = CursorSurface(); var clock = 100.0, requests = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true }, handoffClock: { clock })
        input.edge = .right; input.requestControl = { _, _ in requests += 1 }; input.canSwitch = true
        let event = try motion(); event.location = CGPoint(x: SharingInput.bounds.maxX - 1, y: SharingInput.bounds.midY)
        _ = input.handle(.mouseMoved, event); #expect(requests == 1)
        _ = input.handle(.mouseMoved, event); #expect(requests == 1) // No per-packet request storm.
        input.reset(handoffDelay: 0); input.canSwitch = true
        _ = input.handle(.mouseMoved, event); #expect(requests == 2) // Same clock: no 650 ms wait after success.
        input.reset(handoffDelay: 0.65); input.canSwitch = true
        clock += 0.64; _ = input.handle(.mouseMoved, event); #expect(requests == 2)
        clock += 0.02; _ = input.handle(.mouseMoved, event); #expect(requests == 3)
        input.stop()
    }
    @Test @MainActor func newlyReceivingCursorCanReturnImmediatelyWhenDirectionReallyReverses() throws {
        let system = CursorSystem(), focus = CursorSurface(); var returns = 0, posts = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { _ in posts += 1 }, handoffClock: { 100 })
        input.returnAcrossEdge = { _ in returns += 1 }
        try input.receive(edge: .right, fraction: 0.5) // Enters left at x + 4.
        input.apply(.init(kind: .move, x: -20)) // A real reversal, not continuing entry motion.
        #expect(returns == 1 && posts == 0)
        input.stop()
    }
    @Test @MainActor func controllerCancellationDoesNotCommitALateAcceptedCapture() async throws {
        let domain = "cursor-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!, system = CursorSystem(), focus = CursorSurface()
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: focus), tapReadyOverride: { true })
        let controller = PeripheralSharingController(defaults: defaults, input: input), peer = SharingTransport()
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        peer.connected = { peer.send(.init(kind: .hello, version: 1, deviceID: UUID().uuidString, name: "No-injection peer")) }
        var packets = 0, began = false
        peer.received = { message in
            if message.kind == .begin { began = true }
            if message.kind == .input { packets += 1 }
        }
        defer { controller.stop(); peer.stop(); defaults.removePersistentDomain(forName: domain) }
        let key = try SharingPairingKey.generate()
        try controller.start(key: key, localOnly: true); try peer.start(key: SharingPairingKey.decode(key), name: "cursor-peer", localOnly: true)
        #expect(await wait { controller.transport.port != nil && peer.port != nil })
        try controller.connect(host: "127.0.0.1", port: String(try #require(peer.port).rawValue))
        #expect(await wait { controller.peerName != nil })
        try controller.setKeyboardMouse(true); controller.toggleControl()
        #expect(await wait { began && input.isStaged })
        #expect(controller.control == .requesting && packets == 0)
        controller.returnToLocal()
        #expect(peer.send(.init(kind: .accepted)))
        try await Task.sleep(for: .milliseconds(25))
        #expect(controller.control == .local && packets == 0 && !focus.isPresented && !input.needsRecovery)
    }
    @Test @MainActor func diagnosticProducesMotionEvidenceButNeverOpensNetworkOrEmitsInput() async throws {
        let domain = "cursor-diagnostic-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: domain)!, system = CursorSystem(), focus = CursorSurface()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true })
        let controller = PeripheralSharingController(defaults: settings, input: input)
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { controller.stop(); settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        try controller.startCursorDiagnostic(confirmation: { true }, delay: .zero, maximumDuration: 0.4, reportDirectory: directory)
        #expect(await wait { input.isCapturing })
        #expect(input.handle(.mouseMoved, try motion()))
        #expect(!controller.isRunning && controller.transport.port == nil && controller.sentInputPackets == 0)
        #expect(await wait { !controller.isCursorDiagnostic })
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cursor-test.json"))) as? [String: Any])
        #expect(report["zeroNetworkInput"] as? Bool == true)
        #expect(report["wouldForwardPackets"] as? Int == 1)
        #expect(report["physicalMouseMovements"] as? Int == 1)
        #expect(report["visualConfirmation"] as? String == "not-collected")
        #expect(report["ownsHiddenCursor"] as? Bool == false && report["ownsDisassociation"] as? Bool == false)
        #expect(report["result"] as? String == "native-freeze-verified-needs-visual-confirmation")
    }
    @Test @MainActor func diagnosticNeverPassesWhenPositionRestorationFails() async throws {
        let domain = "cursor-warp-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: domain)!
        let system = CursorSystem(), focus = CursorSurface()
        system.set("warp", .failure)
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true })
        let controller = PeripheralSharingController(defaults: settings, input: input)
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { controller.stop(); settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        try controller.startCursorDiagnostic(confirmation: { true }, delay: .zero, maximumDuration: 0.4, reportDirectory: directory)
        #expect(await wait { input.isCapturing }); _ = input.handle(.mouseMoved, try motion())
        #expect(await wait { !controller.isCursorDiagnostic })
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cursor-test.json"))) as? [String: Any])
        #expect(report["result"] as? String == "failed-or-cancelled")
        #expect(!(report["cleanupErrors"] as? [String] ?? []).isEmpty)
        #expect(report["zeroNetworkInput"] as? Bool == true)
    }
    @Test @MainActor func returnedReceiverOwnsHiddenCursorUntilRealLocalActivity() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
        var posted = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in posted += 1 })
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        #expect(input.mode == .parked && resources.isActive && resources.snapshot["ownsHiddenCursor"] as? Bool == true)
        let event = try motion(); event.type = .scrollWheel
        #expect(input.handle(.scrollWheel, event))
        #expect(resources.isActive && posted == 0)
        #expect(await wait { posted == 1 })
        #expect(!focus.isPresented && input.mode == .local && !resources.isActive)
        #expect(system.calls.filter { $0 == "hide" }.count == 1 && system.calls.filter { $0 == "show" }.count == 1)
        input.stop()
    }
    @Test @MainActor func expiredParkingDoesNotWaitOnCleanupOrReuseTheOldLease() async throws {
        let system = CursorSystem(), surface = CursorSurface(), resources = system.resources()
        var warps = 0, resumed = 0, failures = 0
        let input = SharingInput(cursor: .init(resources: resources, surface: surface), tapReadyOverride: { true },
                                 receiverWarp: { _ in warps += 1; return .success })
        input.failure = { _ in failures += 1 }; input.localResumed = { resumed += 1 }
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        try #require(await wait { surface.isPresented })

        system.time = 1_100_000_000
        input.maintainCapture() // Revokes before the fake watchdog completes cleanup.
        #expect(input.mode == .parked && !input.isParked && input.needsRecovery && warps == 1)
        #expect(!system.calls.contains("reattach") && failures == 0 && resumed == 0)
        #expect(throws: CancellationError.self) { try input.receiveDirectly(edge: .left, fraction: 0.5) }

        resources.expireIfStalled()
        // The next entry may arrive before the timer or presentation cleanup.
        try input.receiveDirectly(edge: .left, fraction: 0.5)
        #expect(input.mode == .receiving && !input.needsRecovery && !surface.isPresented)
        #expect(warps == 2 && resumed == 1 && failures == 0)
        #expect(system.calls == ["hide", "detach", "reattach", "show"])
    }

    @Test @MainActor func legacyCommitRetainsItsEntryWhenIdleParkingExpires() async throws {
        let system = CursorSystem(), resources = system.resources()
        var warps = 0, failures = 0
        let input = SharingInput(cursor: .init(resources: resources, surface: CursorSurface()), tapReadyOverride: { true },
                                 receiverWarp: { _ in warps += 1; return .success })
        input.failure = { _ in failures += 1 }
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        try await input.prepareReceiving(edge: .left, fraction: 0.75, deferPointer: true)
        system.time = 1_100_000_000; resources.expireIfStalled()
        try input.commitReceiving()
        #expect(input.mode == .receiving && warps == 2 && failures == 0)
        #expect(system.calls == ["hide", "detach", "reattach", "show"])
    }

    @Test(arguments: [false, true]) @MainActor func expiredParkingStillFailsIfTapOrCleanupFails(tapLost: Bool) async throws {
        let system = CursorSystem(), resources = system.resources()
        var ready = true, failures: [String] = [], resumed = false
        let input = SharingInput(cursor: .init(resources: resources, surface: CursorSurface()), tapReadyOverride: { ready },
                                 receiverWarp: { _ in .success })
        input.failure = { failures.append($0) }; input.localResumed = { resumed = true }
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        ready = !tapLost
        if !tapLost { system.set("show", .failure) }
        system.time = 1_100_000_000; resources.expireIfStalled()
        input.maintainCapture()
        #expect(failures.count == 1 && !resumed && input.mode == .local)
        if tapLost {
            #expect(failures.first == SharingCursorInterruption.tapLost.localizedDescription && !input.needsRecovery)
        } else {
            #expect(failures.first?.contains("恢复光标显示") == true && input.needsRecovery)
            #expect(throws: PluginError.self) { try input.start() }
            system.set("show", .success); resources.expireIfStalled()
            #expect(!input.needsRecovery)
        }
    }

    @Test @MainActor func parkedAndActiveExpiryKeepAuthenticatedSharingForAFreshHandoff() async throws {
        let one = "parked-expiry-a-\(UUID())", two = "parked-expiry-b-\(UUID())"
        let da = try #require(UserDefaults(suiteName: one)), db = try #require(UserDefaults(suiteName: two))
        let sa = CursorSystem(), sb = CursorSystem(), ra = sa.resources(), rb = sb.resources()
        let pa = TestPasteboard(), pb = TestPasteboard()
        let ca = SharingClipboard(board: pa, automatic: false), cb = SharingClipboard(board: pb, automatic: false)
        let ia = SharingInput(cursor: .init(resources: ra, surface: CursorSurface()), tapReadyOverride: { true })
        let ib = SharingInput(cursor: .init(resources: rb, surface: CursorSurface()), tapReadyOverride: { true },
                              receiverWarp: { _ in .success }, eventPoster: { _ in Issue.record("Unexpected replay") })
        let pixels = SharingScreenPixels(width: 1920, height: 1080)
        let a = PeripheralSharingController(defaults: da, input: ia, screenPixels: pixels, inputAccessAvailable: { true }, clipboard: ca)
        let b = PeripheralSharingController(defaults: db, input: ib, screenPixels: pixels, inputAccessAvailable: { true }, clipboard: cb)
        for controller in [a, b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        try a.startUserSession(localOnly: true); try b.startUserSession(localOnly: true)
        try #require(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        try #require(await wait { a.clipboardImageStatus == .ready && b.clipboardImageStatus == .ready })
        a.setLayoutEdge(.right)
        try #require(await wait { a.layoutReady && b.layoutReady && a.edge == .right && b.edge == .left })
        a.toggleControl()
        try #require(await wait { a.control == .controlling && b.control == .receiving })
        let turn = try motion()
        turn.setDoubleValueField(.mouseEventDeltaX, value: -20) // Back through B's left entry.
        #expect(ia.handle(.mouseMoved, turn))
        try #require(await wait { a.control == .local && b.control == .local && ib.isParked })

        let configure = cb.configureImages
        var imageChanges = 0
        cb.configureImages = { imageChanges += 1; configure($0) }
        sb.time = 1_100_000_000; rb.expireIfStalled()
        try #require(await wait { ib.mode == .local })
        #expect(b.inputDiagnostics["cursorOwnerStage"] as? String == "parking-expired")
        #expect(b.inputDiagnostics["tapReady"] as? Bool == true && !ib.needsRecovery && ib.canSwitch)
        #expect(a.keyboardMouseEnabled && b.keyboardMouseEnabled && a.transport.isConnected && b.transport.isConnected)
        #expect(a.clipboardStatus == .active && b.clipboardStatus == .active && imageChanges == 0)
        #expect(a.clipboardImageStatus == .ready && b.clipboardImageStatus == .ready)
        pb.copy("after parked recovery"); cb.sample()
        try #require(await wait { pa.text == "after parked recovery" })

        a.toggleControl()
        try #require(await wait { a.control == .controlling && b.control == .receiving })
        sa.time = 1_100_000_000; ra.expireIfStalled()
        try #require(await wait { a.control == .local && b.control == .local })
        #expect(!ia.isCapturing && !ia.needsRecovery && a.keyboardMouseEnabled && b.keyboardMouseEnabled)
        #expect(a.transport.isConnected && b.transport.isConnected && a.layoutReady && b.layoutReady)
        #expect(a.clipboardStatus == .active && b.clipboardStatus == .active && imageChanges == 0)
        a.toggleControl()
        try #require(await wait { a.control == .controlling && b.control == .receiving })
        #expect(ia.isCapturing && ra.snapshot["watchdogExpired"] as? Bool == false)
    }

    @Test @MainActor func disabledReceiverTapReleasesOldInputAndRepairsOnTheSameLink() async throws {
        let first = "tap-repair-a-\(UUID())", second = "tap-repair-b-\(UUID())"
        let da = try #require(UserDefaults(suiteName: first)), db = try #require(UserDefaults(suiteName: second))
        let sa = CursorSystem(), sb = CursorSystem()
        let pa = TestPasteboard(), pb = TestPasteboard()
        let ca = SharingClipboard(board: pa, automatic: false), cb = SharingClipboard(board: pb, automatic: false)
        let state = TapRepairFixture(), clock = SharingTestClock(10)
        var posted: [CGEvent] = []
        let ia = SharingInput(cursor: .init(resources: sa.resources(), surface: CursorSurface()), tapReadyOverride: { true })
        let ib = SharingInput(cursor: .init(resources: sb.resources(), surface: CursorSurface()), tapReadyOverride: { state.tap },
                              receiverWarp: { _ in .success }, eventPoster: { posted.append($0) },
                              repairTapOverride: { state.attempts += 1; state.tap = state.canRepair })
        let pixels = SharingScreenPixels(width: 1920, height: 1080)
        let a = PeripheralSharingController(defaults: da, input: ia, screenPixels: pixels, inputAccessAvailable: { true }, clipboard: ca)
        let b = PeripheralSharingController(defaults: db, input: ib, screenPixels: pixels, inputAccessAvailable: { state.allowed },
                                            clipboard: cb, monotonicNow: { clock.now })
        for c in [a,b] { c.isAllowed = { true }; c.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: first); db.removePersistentDomain(forName: second) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        try a.startUserSession(localOnly: true); try b.startUserSession(localOnly: true)
        try #require(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        try #require(await wait { a.layoutReady && b.layoutReady && a.clipboardStatus == .active && b.clipboardStatus == .active })
        let oldStamp = b.layoutStamp
        a.toggleControl()
        try #require(await wait { a.control == .controlling && b.control == .receiving })
        ib.apply(.init(kind: .keyDown, code: 12))
        let old = try #require(posted.first)
        #expect(!ib.handle(old.type, old))
        state.tap = false
        #expect(!ib.handleEventTap(.tapDisabledByTimeout, old))
        try #require(await wait { b.inputRecovering && a.peerKeyboardMouseEnabled == false && a.control == .local })
        #expect(a.transport.isConnected && b.transport.isConnected && b.layoutStamp == oldStamp)
        #expect(a.clipboardStatus == .active && b.clipboardStatus == .active && b.keyboardMouseEnabled)
        #expect(posted.count == 2 && posted.last?.type == .keyUp && state.attempts == 1)
        a.toggleControl()
        #expect(a.control == .local)
        state.canRepair = true; clock.now += 0.5
        try #require(await wait { !b.inputRecovering && a.peerKeyboardMouseEnabled == true })
        #expect(ib.tapReady && state.attempts == 2 && b.clipboardStatus == .active)
        a.toggleControl()
        try #require(await wait { a.control == .controlling && b.control == .receiving })
        #expect(ib.handle(old.type, old)) // A previous receiver epoch never types again.

        state.allowed = false; state.tap = false
        #expect(!ib.handleEventTap(.tapDisabledByUserInput, old))
        try #require(await wait { !b.keyboardMouseEnabled && a.clipboardStatus == .waiting && b.clipboardStatus == .paused })
        #expect(!b.inputRecovering && state.attempts == 2 && a.transport.isConnected && b.transport.isConnected)
    }

    @Test @MainActor func parkingDrainsReceiverReplayBeforeAnchoringAndDropsLateDuplicates() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
        var events: [CGEvent] = [], failures = 0, warps = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true },
            receiverWarp: { warps += 1; focus.position = $0; return .success }, eventPoster: { events.append($0) })
        input.failure = { _ in failures += 1 }
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        let original = try #require(focus.position)
        input.apply(.init(kind: .move, x: -75))
        let motion = try #require(events.first)
        #expect(motion.location != original)
        let parking = Task { try await input.parkAfterReturn() }
        try await Task.sleep(for: .milliseconds(15))
        #expect(input.mode == .receiving && !resources.isActive && !system.calls.contains("detach"))
        // Receipt at the tap can precede WindowServer's coordinate readback.
        #expect(!input.handle(motion.type, motion))
        try await parking.value
        #expect(focus.position == original)
        input.maintainCapture()
        #expect(input.isParked && failures == 0 && warps == 1)
        // A delayed duplicate may not move the parked cursor or a new receiver.
        #expect(input.handle(motion.type, motion))
        #expect(input.isParked && input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 0)
    }
    @Test @MainActor func missingPointerReadbackIsNotAReasonToCancelReturn() async throws {
        let surface = CursorSurface(), system = CursorSystem()
        surface.position = nil
        var replay: CGEvent?, warps = 0
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface), tapReadyOverride: { true },
                                 receiverWarp: { _ in warps += 1; return .success }, eventPoster: { replay = $0 })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        input.apply(.init(kind: .move, x: -75))
        let event = try #require(replay)
        #expect(!input.handle(event.type, event))
        try await input.parkAfterReturn()
        #expect(await wait { input.safetyDiagnostics["cursorOwnerStage"] as? String == "position-unavailable" })
        #expect(warps == 1 && system.calls == ["hide", "detach"] && input.isParked && !surface.isPresented)
    }
    @Test @MainActor func receiverReplayCannotCrossAResetOrNewHandoff() throws {
        let system = CursorSystem(), focus = CursorSurface()
        var events: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        input.apply(.init(kind: .move, x: -75))
        let old = try #require(events.first)
        input.reset(); try input.receive(edge: .right, fraction: 0.5)
        #expect(input.handle(old.type, old))
        input.apply(.init(kind: .move, x: 75))
        let fresh = try #require(events.last)
        #expect(!input.handle(fresh.type, fresh))
        #expect(input.handle(old.type, old))
        #expect(input.safetyDiagnostics["droppedStaleReceiverEvents"] as? Int == 2)
    }
    @Test @MainActor func physicalDownAndUpDuringReplayDrainCancelParking() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
        var events: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .move, x: -75))
        let task = Task { try await input.parkAfterReturn() }
        try await Task.sleep(for: .milliseconds(15))
        let event = try motion(); event.type = .keyDown; _ = input.handle(.keyDown, event)
        event.type = .keyUp; _ = input.handle(.keyUp, event)
        #expect(input.isNeutral)
        for replay in events { _ = input.handle(replay.type, replay) }
        switch await task.result { case .success: Issue.record("A complete local key cycle did not cancel parking"); case .failure: break }
        #expect(!resources.isActive && !system.calls.contains("detach"))
    }
    @Test @MainActor func stalledReceiverReplayCannotAcquireAParkingLease() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { _ in })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .move, x: -75))
        await #expect(throws: SharingCursorInterruption.replayBusy) { try await input.parkAfterReturn() }
        #expect(!resources.isActive && !system.calls.contains("detach") && !system.calls.contains("hide"))
    }
    @Test @MainActor func stopDuringReplayDrainCannotReacquireOrPrepareAReceiver() async throws {
        for prepare in [false, true] {
            let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
            let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true },
                receiverWarp: { _ in .success }, eventPoster: { _ in })
            try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .move, x: -75)); input.reset()
            let task = Task {
                if prepare { try await input.prepareReceiving(edge: .right, fraction: 0.5, deferPointer: true) }
                else { try await input.capture() }
            }
            try await Task.sleep(for: .milliseconds(15)); input.stop()
            switch await task.result { case .success: Issue.record("Stop was ignored during replay drain"); case .failure: break }
            #expect(!resources.isActive && system.calls.isEmpty && input.mode == .local)
            #expect(throws: PluginError.self) { try input.commitReceiving() }
        }
    }
    @Test @MainActor func cleanupKeyUpIsNeverDiscardedWithStaleReceiverKeyDown() throws {
        let system = CursorSystem(), focus = CursorSurface()
        var events: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .keyDown, code: 0))
        let down = try #require(events.first)
        #expect(!input.handle(down.type, down))
        input.reset(); let up = try #require(events.last)
        #expect(up.type == .keyUp)
        input.stop()
        #expect(!input.handle(up.type, up) && input.handle(down.type, down))
    }
    @Test @MainActor func cancelledQueuedUpStillReleasesADownThatAlreadyPassedTheTap() throws {
        for pair: (SharingInputPacket, SharingInputPacket) in [
            (.init(kind: .keyDown, code: 0), .init(kind: .keyUp, code: 0)),
            (.init(kind: .flags, code: 55, pressed: true), .init(kind: .flags, code: 55, pressed: false)),
            (.init(kind: .down, code: 0), .init(kind: .up, code: 0))
        ] {
            let system = CursorSystem(), focus = CursorSurface(); var events: [CGEvent] = []
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true },
                receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
            try input.receive(edge: .left, fraction: 0.5); input.apply(pair.0)
            let down = try #require(events.last); #expect(!input.handle(down.type, down))
            input.apply(pair.1); let up = try #require(events.last)
            input.reset()
            #expect(events.count == 3) // Desired state is neutral, but delivered down still needs cleanup.
            let cleanup = try #require(events.last)
            #expect(input.handle(up.type, up) && !input.handle(cleanup.type, cleanup))
            #expect(input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 0)
            input.stop()
        }
    }
    @Test @MainActor func receiverReplayQueueIsBoundedAndFailsClosed() throws {
        let system = CursorSystem(), focus = CursorSurface()
        var events: [CGEvent] = [], failures = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        input.failure = { _ in failures += 1 }
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        for _ in 0..<513 { input.apply(.init(kind: .move, x: -1)) }
        #expect(events.count == 512 && input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 512)
        #expect(input.mode == .local && failures == 1)
        for event in events { #expect(input.handle(event.type, event)) }
        #expect(input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 0)
    }
    @Test @MainActor func nextCaptureWaitsForGenuineLocalRepostsBeforeFreezingTheCursor() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources(); var posted: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { posted.append($0) })
        try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn()
        #expect(input.handle(.mouseMoved, try motion()))
        #expect(await wait { posted.count == 1 })
        let task = Task { try await input.capture(deferForwarding: true) }
        try await Task.sleep(for: .milliseconds(15))
        #expect(input.mode == .local && !resources.isActive && system.calls.filter { $0 == "detach" }.count == 1)
        let event = try #require(posted.first); #expect(!input.handle(event.type, event))
        try await task.value; #expect(input.isStaged)
        input.stop()
    }
    @Test @MainActor func stoppedOrOverflowedLocalResumeNeverReplaysAnOldPrefix() async throws {
        for overflow in [false, true] {
            let system = CursorSystem(), focus = CursorSurface(); var posted = 0
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in posted += 1 })
            try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn()
            let event = try motion(); event.type = .scrollWheel
            #expect(input.handle(.scrollWheel, event))
            if overflow { for _ in 0..<129 { _ = input.handle(.scrollWheel, event) } }
            else { input.stop() }
            try? await Task.sleep(for: .milliseconds(25))
            #expect(posted == 0 && input.safetyDiagnostics["queuedLocalEvents"] as? Int == 0)
            input.stop()
        }
    }
    @Test @MainActor func physicalActivityDuringReceivePreparationCancelsEvenAfterKeyUp() async throws {
        for keyboard in [false, true] {
            let system = CursorSystem(), focus = CursorSurface(); var warps = 0, events: [CGEvent] = []
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in warps += 1; return .success }, eventPoster: { events.append($0) })
            try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .move, x: -35))
            let task = Task { try await input.prepareReceiving(edge: .right, fraction: 0.5) }
            try await Task.sleep(for: .milliseconds(15))
            let event = try motion()
            if keyboard {
                event.type = .keyDown; _ = input.handle(.keyDown, event)
                event.type = .keyUp; _ = input.handle(.keyUp, event)
                #expect(input.isNeutral)
            } else { _ = input.handle(.mouseMoved, event) }
            for event in events { #expect(input.handle(event.type, event)) }
            switch await task.result { case .success: Issue.record("Local activity did not cancel preparation"); case .failure: break }
            #expect(input.mode == .local && warps == 1)
            input.stop()
        }
    }
    @Test @MainActor func bufferedPhysicalDownRemainsHeldAndWrongFocusNeverReceivesReplay() async throws {
        for correctFocus in [true, false] {
            let system = CursorSystem(), focus = CursorSurface(); var posted = 0, foreground: pid_t = 12
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in posted += 1 }, frontmostPID: { foreground })
            try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn()
            let event = try motion(); event.type = .keyDown
            #expect(input.handle(.keyDown, event) && !input.isNeutral)
            if !correctFocus { foreground = 42 }
            try? await Task.sleep(for: .milliseconds(25))
            #expect(posted == (correctFocus ? 1 : 0) && !input.isNeutral)
            await #expect(throws: CancellationError.self) { try await input.capture() }
            event.type = .keyUp; _ = input.handle(.keyUp, event); #expect(input.isNeutral)
            input.stop()
        }
    }
    @Test @MainActor func parkedReceiverRemainsHiddenUntilCommitAndLandsBeforeShow() async throws {
        let system = CursorSystem(), surface = CursorSurface(); var entryWarps = 0
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface), tapReadyOverride: { true },
                                 receiverWarp: { _ in entryWarps += 1; return .success })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn()
        #expect(await wait { surface.glyphSets == 1 })
        let installed = system.calls
        #expect(surface.isPresented && entryWarps == 1)
        try await input.prepareReceiving(edge: .right, fraction: 0.25, deferPointer: true)
        #expect(input.isParked && surface.isPresented && system.calls == installed)
        try input.commitReceiving()
        #expect(!surface.isPresented && input.mode == .receiving && entryWarps == 1)
        #expect(Array(system.calls.dropFirst(installed.count)) == ["warp", "reattach", "show"])
    }
    @Test @MainActor func receiverPointerWaitsForCommitAndCancelledPreparationCannotWarp() async throws {
        let system = CursorSystem(), focus = CursorSurface(); var warps = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in warps += 1; return .success }, eventPoster: { _ in })
        try await input.prepareReceiving(edge: .left, fraction: 0.5, deferPointer: true)
        #expect(warps == 0 && input.mode == .local)
        try input.commitReceiving(); #expect(warps == 1 && input.mode == .receiving)
        input.reset(); try await input.prepareReceiving(edge: .right, fraction: 0.5, deferPointer: true)
        _ = input.handle(.mouseMoved, try motion())
        #expect(throws: PluginError.self) { try input.commitReceiving() }
        #expect(warps == 1)
        input.stop()
    }
    @Test @MainActor func realLocalInputDuringPendingAppearanceReleasesThePark() async throws {
        let system = CursorSystem(), surface = CursorSurface(), resources = system.resources()
        surface.isHittable = false; surface.inset = CGPoint(x: 30, y: 40)
        let input = SharingInput(cursor: .init(resources: resources, surface: surface), tapReadyOverride: { true },
                                 receiverWarp: { _ in .success }, eventPoster: { _ in })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        #expect(await wait { surface.isPresented })
        #expect(input.isParked)
        #expect(input.handleEventTap(.mouseMoved, try motion()))
        surface.isHittable = true
        #expect(await wait { input.mode == .local && !surface.isPresented })
        #expect(!resources.isActive && !resources.needsRecovery && surface.glyphSets == 0)
        #expect(system.lastWarp != surface.inset)
    }
    @Test @MainActor func failedParkingRollsBackInsteadOfPretendingTheCursorIsHidden() async throws {
        let system = CursorSystem(), focus = CursorSurface(), resources = system.resources()
        system.set("hide", .failure)
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, surface: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success })
        try input.receive(edge: .left, fraction: 0.5)
        await #expect(throws: SharingCursorInterruption.self) { try await input.parkAfterReturn() }
        #expect(input.mode == .local && !resources.isActive && !resources.needsRecovery)
        #expect(system.calls == ["hide"])
        input.stop()
    }
    @Test func allPhysicalActivityCanTakeBackAReceiverIncludingScrollDragAndRelease() {
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                 .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel] {
            #expect(SharingInput.isPhysicalActivity(type))
        }
        #expect(!SharingInput.isPhysicalActivity(.tapDisabledByTimeout) && !SharingInput.isPhysicalActivity(.null))
    }
    @Test func returnContinuityIsBoundedAndCannotReplayOverNonMoveOrExpiredHistory() throws {
        var motion = SharingReturnMotion()
        motion.record(.init(kind: .move, x: -20))
        motion.record(.init(kind: .move, x: -15, y: 5))
        motion.record(.init(kind: .move, x: 3, y: 6))
        #expect(motion.after(1) == CGPoint(x: -12, y: 11))
        #expect(motion.after(3) == .zero && motion.after(4) == nil && motion.after(0) == nil)
        motion.record(.init(kind: .down, code: 0)); motion.record(.init(kind: .move, x: 129, y: -200))
        #expect(motion.after(1) == nil && motion.after(4) == CGPoint(x: 128, y: -128))
        for _ in 0..<SharingReturnMotion.capacity { motion.record(.init(kind: .move, x: 1)) }
        #expect(motion.after(5) == nil && motion.after(6) == CGPoint(x: 128, y: 0))
        let id = UUID().uuidString, position = SharingCursorPosition(x: 1, y: 0.4)
        let valid = SharingMessage(kind: .end, returnPosition: position, handoffID: id, returned: true, returnAfterInput: 8)
        var framer = SharingFramer()
        #expect(try framer.append(SharingFramer.encode(valid)).first?.returnAfterInput == 8)
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, returnPosition: position, handoffID: id, returnAfterInput: 8).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, handoffID: id, returned: true, returnAfterInput: 8).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, returnPosition: position, handoffID: id, returned: true, returnAfterInput: 0).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, continuousReturn: true).validate() }
    }
    @Test @MainActor func normalReturnLandingPreservesOnlyTailMotionAndInsetsBoundary() {
        let bounds = CGRect(x: -200, y: 0, width: 800, height: 600)
        let position = SharingCursorPosition(x: 1, y: 0.5)
        #expect(SharingInput.returnLanding(position, motion: .zero, bounds: bounds) == CGPoint(x: 595, y: 299.5))
        #expect(SharingInput.returnLanding(position, motion: CGPoint(x: -31, y: 9), bounds: bounds) == CGPoint(x: 568, y: 308.5))
        #expect(SharingInput.returnLanding(position, motion: CGPoint(x: 12, y: -3), bounds: bounds) == CGPoint(x: 595, y: 296.5))
    }
    @Test func normalReturnMustHaveAValidHandoffIdentity() throws {
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, returned: true).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, handoffID: "bad", returned: true).validate() }
        try SharingMessage(kind: .end, handoffID: UUID().uuidString, returned: true).validate()
        try SharingMessage(kind: .end).validate() // Explicit all-local emergency remains supported.
    }
    @Test @MainActor func directEntryRejectsAnUndrainedReceiverWithoutStoppingTheConnection() async throws {
        let one = "queue-a-\(UUID().uuidString)", two = "queue-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorSurface(), fb = CursorSurface()
        var pending: [CGEvent] = []
        let ia = SharingInput(cursor: .init(resources: sa.resources(), surface: fa), tapReadyOverride: { true })
        let ib = SharingInput(cursor: .init(resources: sb.resources(), surface: fb), tapReadyOverride: { true },
                              receiverWarp: { _ in .success }, eventPoster: { pending.append($0) })
        let a = PeripheralSharingController(defaults: da, input: ia, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, inputAccessAvailable: { true })
        for controller in [a,b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady && a.peerKeyboardMouseEnabled == true })
        try ib.receive(edge: .left, fraction: 0.5)
        ib.apply(.init(kind: .move, x: -6)); ib.reset()
        let stale = try #require(pending.first)
        a.toggleControl()
        #expect(await wait { a.control == .local && sa.calls.contains("show") })
        #expect(b.control == .local && a.keyboardMouseEnabled && b.keyboardMouseEnabled && a.layoutReady && b.layoutReady)
        #expect(b.receivedInputPackets == 0 && ib.handle(stale.type, stale))
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
    }
    @Test @MainActor func refusedNativeFreezeCancelsOneHandoffWithoutDisablingSharing() async throws {
        let one = "freeze-retry-a-\(UUID().uuidString)", two = "freeze-retry-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), surface = CursorSurface()
        sa.set("detach", .failure)
        let input = SharingInput(cursor: .init(resources: sa.resources(), surface: surface), tapReadyOverride: { true })
        let receiver = SharingInput(cursor: .init(resources: sb.resources(), surface: CursorSurface()), tapReadyOverride: { true }, receiverWarp: { _ in .success })
        let a = PeripheralSharingController(defaults: da, input: input, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: receiver, inputAccessAvailable: { true })
        for controller in [a, b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady && a.peerKeyboardMouseEnabled == true })
        a.toggleControl()
        #expect(await wait { a.control == .local && b.control == .local && a.inputStatus?.contains("解除本机鼠标关联失败") == true })
        #expect(a.keyboardMouseEnabled && b.keyboardMouseEnabled && a.layoutReady && b.layoutReady)
        #expect(a.sentInputPackets == 0 && b.receivedInputPackets == 0 && !input.needsRecovery)
        #expect(sa.calls == ["hide", "detach", "show"])
        sa.set("detach", .success)
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        #expect(a.transport.isConnected && b.transport.isConnected && a.inputStatus == nil)
    }
    @Test @MainActor func emergencyInTheNativeTapWithdrawsOutsideTheCallback() async throws {
        let surface = CursorSurface(), system = CursorSystem()
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface), tapReadyOverride: { true })
        input.returnLocal = { [weak input] _ in input?.reset() }
        var sent = 0; input.send = { _ in sent += 1 }
        defer { input.stop() }
        try await input.capture()
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false))
        for event in [down, up] {
            event.flags = [.maskControl, .maskAlternate, .maskCommand]
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        }
        #expect(input.handleEventTap(.keyDown, down))
        #expect(!input.isCapturing && system.calls == ["hide", "detach"])
        #expect(input.handleEventTap(.keyUp, up))
        #expect(await wait { input.mode == .local && !surface.isPresented })
        #expect(sent == 0 && input.isNeutral && !input.needsRecovery)
    }
    @Test @MainActor func peerSafetyPauseIsVisibleWithoutDisconnectOrAutomaticReenable() async throws {
        let one = "pause-a-\(UUID().uuidString)", two = "pause-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorSurface(), fb = CursorSurface()
        let ia = SharingInput(cursor: SharingCursorCapture(resources: sa.resources(), surface: fa), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let ib = SharingInput(cursor: SharingCursorCapture(resources: sb.resources(), surface: fb), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let state = TapRepairFixture()
        let a = PeripheralSharingController(defaults: da, input: ia, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, inputAccessAvailable: { state.allowed })
        for controller in [a,b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        #expect(await wait { a.peerKeyboardMouseEnabled == true && b.peerKeyboardMouseEnabled == true })
        // A genuine permission withdrawal still pauses; a transient tap
        // notification alone takes the self-repair path covered above.
        try await ib.capture()
        state.allowed = false
        _ = ib.handleEventTap(.tapDisabledByUserInput, try motion())
        #expect(await wait { a.peerKeyboardMouseEnabled == false })
        #expect(a.peerName != nil && b.peerName != nil && a.layoutReady && b.layoutReady)
        #expect(a.status.contains("键鼠暂不可用") && !b.keyboardMouseEnabled)
        a.toggleControl(); #expect(a.control == .local && !sa.calls.contains("detach"))
        a.returnToLocal(); state.allowed = true
        try await Task.sleep(for: .milliseconds(25))
        #expect(b.status.contains("暂停") && b.inputStatus != nil && !b.keyboardMouseEnabled)
        try b.setKeyboardMouse(true)
        #expect(await wait { a.peerKeyboardMouseEnabled == true })
        a.toggleControl(); #expect(await wait { a.control == .controlling && b.control == .receiving })
    }
    @Test @MainActor func normalReturnParksReceiverButEmergencyAndFreshHandoffReleaseIt() async throws {
        let one = "park-a-\(UUID().uuidString)", two = "park-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorSurface(), fb = CursorSurface()
        let ia = SharingInput(cursor: SharingCursorCapture(resources: sa.resources(), surface: fa), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let ib = SharingInput(cursor: SharingCursorCapture(resources: sb.resources(), surface: fb), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let a = PeripheralSharingController(defaults: da, input: ia, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, inputAccessAvailable: { true })
        for controller in [a,b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        #expect(await wait { a.peerKeyboardMouseEnabled == true && b.peerKeyboardMouseEnabled == true })
        a.status = "old failure"; a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        #expect(a.status != "old failure")
        ib.returnAcrossEdge(.init(x: 0.5, y: 0.5))
        #expect(await wait { a.control == .local && ib.mode == .parked })
        #expect(sb.calls.filter { $0 == "hide" }.count == sb.calls.filter { $0 == "show" }.count + 1)
        a.returnToLocal() // Emergency even though A has already regained local control.
        #expect(await wait { ib.mode == .local && sb.calls.contains("show") })
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        a.transport.send(.init(kind: .end, handoffID: UUID().uuidString))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(b.control == .receiving) // A stale end cannot release the fresh handoff.
        ib.returnAcrossEdge(.init(x: 0.5, y: 0.5))
        #expect(await wait { a.control == .local && ib.mode == .parked })
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        #expect(sb.calls.filter { $0 == "hide" }.count == sb.calls.filter { $0 == "show" }.count)
    }
    @Test @MainActor func unavailableAppearanceServicesNeverGateTheLease() async throws {
        for (region, updated, visible) in [(false, false, Optional(false)), (true, false, true), (true, true, nil)] {
            let surface = CursorSurface()
            let resources = SharingCursorResources(calls: .init(associate: { _ in .success }, hide: { .success },
                show: { .success }, warp: { _ in .success }, takeCursorRegion: { region },
                refreshDisplay: { updated }, cursorVisible: { visible }), watchdogEnabled: false)
            let capture = SharingCursorCapture(resources: resources, surface: surface)
            try await acquire(capture)
            #expect(capture.isCaptured && surface.isPresented)
            #expect(capture.snapshot["nativeHideEvidence"] as? String ==
                    (visible.map { $0 ? "still-visible" : "reported-hidden" } ?? "visibility-unavailable"))
            #expect(capture.release().isEmpty && !resources.needsRecovery)
        }
    }
    @Test @MainActor func liveMaintenanceDoesNotRenewAHideOrFailOnVisibilityChange() async throws {
        let system = CursorSystem(), surface = CursorSurface()
        let input = SharingInput(cursor: .init(resources: system.resources(native: true), surface: surface), tapReadyOverride: { true })
        defer { input.stop() }
        try await input.capture()
        #expect(await wait { surface.glyphSets == 1 })
        system.visible = true; surface.position = CGPoint(x: 50.96, y: 40)
        input.maintainCapture()
        #expect(input.isCapturing && system.calls == ["hide", "detach"])
        try await Task.sleep(for: .milliseconds(110))
        input.maintainCapture()
        #expect(input.isCapturing && system.calls == ["hide", "detach"])
        input.reset()
        #expect(system.calls == ["hide", "detach", "warp", "reattach", "show"])
    }
    @Test @MainActor func rejectedCosmeticPlacementKeepsTheOriginalNativeFreeze() async throws {
        let system = CursorSystem(), surface = CursorSurface()
        surface.inset = CGPoint(x: 30, y: 40); system.set("warp", .failure)
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface), tapReadyOverride: { true },
                                 receiverWarp: { _ in .success })
        defer { system.set("warp", .success); input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        #expect(await wait { input.safetyDiagnostics["cursorOwnerStage"] as? String == "parking-rejected" })
        #expect(input.isParked && surface.isPresented && system.calls == ["hide", "detach", "warp"])
        input.maintainCapture()
        #expect(input.isParked && !input.needsRecovery)
    }
    @Test func systemEdgeParkingLeavesOrdinaryEdgesAndOtherDisplaysAlone() {
        let screen = CGRect(x: -1200, y: -400, width: 1200, height: 800)
        let work = CGRect(x: -1200, y: -374, width: 1125, height: 774)
        let ordinary = CGPoint(x: -1199, y: 150)
        #expect(SharingCursorParkingGeometry.destination(from: ordinary, screen: screen, workArea: work) == ordinary)
        #expect(SharingCursorParkingGeometry.destination(from: CGPoint(x: -1, y: 150), screen: screen, workArea: work) == CGPoint(x: -83, y: 150))
        #expect(SharingCursorParkingGeometry.destination(from: CGPoint(x: -1, y: 150), screen: screen, workArea: screen,
                                                         autoHideDock: .right) == CGPoint(x: -48, y: 150))
        #expect(SharingCursorParkingGeometry.destination(from: CGPoint(x: -1199, y: -399), screen: screen, workArea: screen,
                                                         corners: .topLeft) == CGPoint(x: -1176, y: -376))
        let elsewhere = CGPoint(x: 5, y: -399)
        #expect(SharingCursorParkingGeometry.destination(from: elsewhere, screen: screen, workArea: work) == elsewhere)
    }
    @Test @MainActor func restoreFenceDropsOnlyPhysicalMotionOlderThanPlacement() async throws {
        let system = CursorSystem(), surface = CursorSurface()
        let input = SharingInput(cursor: .init(resources: system.resources(), surface: surface), tapReadyOverride: { true },
                                 eventClock: { 500 })
        defer { input.stop() }
        try await input.capture()
        input.reset(restoring: .init(x: 1, y: 0.5))
        let event = try motion()
        event.timestamp = 499
        #expect(input.handleEventTap(.mouseMoved, event))
        event.timestamp = 500
        #expect(!input.handleEventTap(.mouseMoved, event))
        #expect(input.safetyDiagnostics["droppedPreRestoreMotion"] as? Int == 1)
    }
    @Test @MainActor func twoPeersRouteWhileAppearanceIsUnownedAndFractionalParkingDiffers() async throws {
        let one = "direct-a-\(UUID().uuidString)", two = "direct-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorSurface(), fb = CursorSurface()
        fa.isHittable = false
        fb.inset = CGPoint(x: 30, y: 40)
        var framesFromA: [SharingMessage.Kind] = [], framesFromB: [SharingMessage.Kind] = [], receiverPosts: [CGEvent] = []
        let ia = SharingInput(cursor: .init(resources: sa.resources(), surface: fa), tapReadyOverride: { true })
        let ib = SharingInput(cursor: .init(resources: sb.resources(onWarp: { target in
            MainActor.assumeIsolated { fb.position = CGPoint(x: target.x + 0.96, y: target.y) }
        }), surface: fb), tapReadyOverride: { true }, receiverWarp: { fb.position = $0; return .success },
                              eventPoster: { receiverPosts.append($0) })
        let pixels = SharingScreenPixels(width: 1920, height: 1080)
        let a = PeripheralSharingController(defaults: da, input: ia, screenPixels: pixels, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, screenPixels: pixels, inputAccessAvailable: { true })
        for controller in [a, b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let onA = a.transport.received, onB = b.transport.received
        a.transport.received = { framesFromB.append($0.kind); onA($0) }
        b.transport.received = { framesFromA.append($0.kind); onB($0) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady && a.peerKeyboardMouseEnabled == true })
        a.setLayoutEdge(.right)
        #expect(await wait { a.layoutReady && b.layoutReady && a.edge == .right && b.edge == .left })
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        #expect(framesFromA.contains(.begin) && !framesFromA.contains(.commit) && !framesFromB.contains(.accepted))
        #expect(fa.glyphSets == 0 && !sa.calls.contains("warp"))
        let event = try motion()
        event.setDoubleValueField(.mouseEventDeltaX, value: 20)
        #expect(ia.handleEventTap(.mouseMoved, event))
        #expect(await wait { receiverPosts.count == 1 })
        let delivered = try #require(receiverPosts.first)
        #expect(!ib.handleEventTap(delivered.type, delivered))
        fb.position = delivered.location
        event.setDoubleValueField(.mouseEventDeltaX, value: -40)
        #expect(ia.handleEventTap(.mouseMoved, event))
        #expect(await wait { a.control == .local && ib.isParked })
        #expect(await wait { ib.safetyDiagnostics["cursorOwnerStage"] as? String == "parked" })
        #expect(fb.isPresented && sb.lastWarp == fb.inset)
        #expect((ib.safetyDiagnostics["maximumCursorDrift"] as? Double ?? 0) > 0.9)
        #expect(ib.isParked && !sb.calls.contains("show") && receiverPosts.count == 1)
        #expect(a.keyboardMouseEnabled && b.keyboardMouseEnabled && a.layoutReady && b.layoutReady)
        // Cross back again from the same hardware without resetting/re-enabling.
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        #expect(sb.calls.filter { $0 == "hide" }.count == sb.calls.filter { $0 == "show" }.count)
        // Reverse the roles on the same TLS connection. A can also return
        // without any background window hit or reported-visibility proof.
        a.returnToLocal()
        #expect(await wait { b.control == .local })
        b.toggleControl()
        #expect(await wait { b.control == .controlling && a.control == .receiving })
        ia.returnAcrossEdge(.init(x: 0, y: 0.4))
        #expect(await wait { b.control == .local && ia.isParked })
        #expect(a.keyboardMouseEnabled && b.keyboardMouseEnabled && a.transport.isConnected && b.transport.isConnected)
    }
    @Test @MainActor func legacyPeerStillReceivesBeginAndCommitInOrder() async throws {
        let domain = "legacy-route-\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        let surface = CursorSurface(), system = CursorSystem(), peer = SharingTransport()
        let input = SharingInput(cursor: .init(resources: system.resources(native: true), surface: surface), tapReadyOverride: { true })
        let pixels = SharingScreenPixels(width: 1920, height: 1080)
        let controller = PeripheralSharingController(defaults: defaults, input: input, screenPixels: pixels, inputAccessAvailable: { true })
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { controller.stop(); peer.stop(); defaults.removePersistentDomain(forName: domain) }
        let peerID = UUID().uuidString, key = try SharingPairingKey.generate()
        var start: SharingMessage?, commits = 0
        peer.connected = {
            peer.send(.init(kind: .hello, version: 1, deviceID: peerID, name: "Legacy Mac", layoutSync: true,
                            layoutVersion: 3, screenAspect: pixels.aspect, layoutStamp: .init(counter: 0, author: peerID),
                            screenPixels: pixels, cursorParking: true, keyboardEnabled: true))
        }
        peer.received = { message in
            switch message.kind {
            case .layout: peer.send(.init(kind: .layoutAck, layoutStamp: message.layoutStamp))
            case .begin: start = message
            case .commit: commits += 1
            default: break
            }
        }
        try controller.start(key: key, localOnly: true)
        try peer.start(key: SharingPairingKey.decode(key), name: "legacy-peer", localOnly: true)
        #expect(await wait { controller.transport.port != nil && peer.port != nil })
        try controller.setKeyboardMouse(true)
        try controller.connect(host: "127.0.0.1", port: String(try #require(peer.port).rawValue))
        #expect(await wait { controller.layoutReady && controller.peerKeyboardMouseEnabled == true })
        controller.toggleControl()
        #expect(await wait { start != nil && input.isStaged })
        #expect(commits == 0 && start?.directEntry == nil && start?.layoutStamp == nil && controller.sentInputPackets == 0)
        #expect(peer.send(.init(kind: .accepted, handoffID: try #require(start?.handoffID))))
        #expect(await wait { controller.control == .controlling && commits == 1 })
    }
    @Test @MainActor func directEntryWithStaleLayoutOrDeniedPermissionNeverPostsInput() async throws {
        let domain = "direct-reject-\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        var warps = 0, posts = 0, permitted = true
        let input = SharingInput(tapReadyOverride: { true }, receiverWarp: { _ in warps += 1; return .success },
                                 eventPoster: { _ in posts += 1 })
        let pixels = SharingScreenPixels(width: 1920, height: 1080), peer = SharingTransport()
        let controller = PeripheralSharingController(defaults: defaults, input: input, screenPixels: pixels, inputAccessAvailable: { true })
        controller.isAllowed = { true }
        controller.requirePermissions = { _ in if !permitted { throw HostPermissionError.missing } }
        defer { controller.stop(); peer.stop(); defaults.removePersistentDomain(forName: domain) }
        let peerID = UUID().uuidString, key = try SharingPairingKey.generate()
        var rejected: Set<String> = []
        peer.connected = {
            peer.send(.init(kind: .hello, version: 1, deviceID: peerID, name: "Direct Mac", layoutSync: true,
                            layoutVersion: 3, screenAspect: pixels.aspect, layoutStamp: .init(counter: 0, author: peerID),
                            screenPixels: pixels, cursorParking: true, directHandoff: true, keyboardEnabled: true))
        }
        peer.received = { message in
            if message.kind == .layout { peer.send(.init(kind: .layoutAck, layoutStamp: message.layoutStamp)) }
            if message.kind == .end, let id = message.handoffID { rejected.insert(id) }
        }
        try controller.start(key: key, localOnly: true)
        try peer.start(key: SharingPairingKey.decode(key), name: "direct-reject-peer", localOnly: true)
        #expect(await wait { controller.transport.port != nil && peer.port != nil })
        try controller.setKeyboardMouse(true)
        try controller.connect(host: "127.0.0.1", port: String(try #require(peer.port).rawValue))
        #expect(await wait { controller.layoutReady && controller.peerKeyboardMouseEnabled == true })
        for stale in [true, false] {
            let id = UUID().uuidString, stamp = stale ? SharingLayoutStamp(counter: 0, author: UUID().uuidString) : controller.layoutStamp
            permitted = stale
            #expect(peer.send(.init(kind: .begin, edge: .left, position: 0.5, layoutStamp: stamp, handoffID: id, directEntry: true)))
            #expect(peer.send(.init(kind: .input, input: .init(kind: .move, x: -10), handoffID: id)))
            #expect(await wait { rejected.contains(id) })
            #expect(controller.control == .local && input.mode == .local && controller.receivedInputPackets == 0 && warps == 0 && posts == 0)
        }
    }
    @Test @MainActor func twoPeersPreserveMovementSentDuringReturnWithoutPostingItOnTheOldScreen() async throws {
        let one = "continuity-a-\(UUID().uuidString)", two = "continuity-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorSurface(), fb = CursorSurface()
        var oldScreenPosts: [CGEvent] = []
        let ia = SharingInput(cursor: .init(resources: sa.resources(), surface: fa), tapReadyOverride: { true })
        let ib = SharingInput(cursor: .init(resources: sb.resources(), surface: fb), tapReadyOverride: { true },
                              receiverWarp: { _ in .success }, eventPoster: { oldScreenPosts.append($0) })
        let pixels = SharingScreenPixels(width: 1920, height: 1080)
        let a = PeripheralSharingController(defaults: da, input: ia, screenPixels: pixels, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, screenPixels: pixels, inputAccessAvailable: { true })
        for controller in [a, b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady && a.peerKeyboardMouseEnabled == true })
        a.setLayoutEdge(.right)
        #expect(await wait { a.layoutReady && b.layoutReady && a.edge == .right && b.edge == .left })
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        let event = try motion()
        event.setDoubleValueField(.mouseEventDeltaX, value: 20)
        #expect(ia.handle(.mouseMoved, event))
        #expect(await wait { oldScreenPosts.count == 1 })
        event.setDoubleValueField(.mouseEventDeltaX, value: -40)
        #expect(ia.handle(.mouseMoved, event))
        #expect(await wait { b.control == .returning })
        event.setDoubleValueField(.mouseEventDeltaX, value: -31)
        #expect(ia.handle(.mouseMoved, event))
        event.setDoubleValueField(.mouseEventDeltaX, value: -20)
        #expect(ia.handle(.mouseMoved, event))
        #expect(a.sentInputPackets == 4 && oldScreenPosts.count == 1)
        #expect(!ib.handleEventTap(.mouseMoved, try #require(oldScreenPosts.first)))
        #expect(await wait { a.control == .local && ib.isParked })
        let warp = try #require(sa.lastWarp)
        #expect(warp.x == SharingInput.bounds.maxX - 1 - 51)
        #expect(oldScreenPosts.count == 1)
    }
    @MainActor private func acquire(_ capture: SharingCursorCapture) async throws {
        try capture.acquire(tapReady: { true }, neutral: { true })
        capture.updateAppearance()
        #expect(await wait { capture.snapshot["cursorOwnerStage"] as? String == "glyph-set" })
    }
    @MainActor private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
    private func motion() throws -> CGEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 50, y: 40), mouseButton: .left))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setDoubleValueField(.mouseEventDeltaX, value: 5)
        return event // In-memory fixture only: never posted to the OS.
    }
}

@MainActor private final class TapRepairFixture {
    var tap = true
    var canRepair = false
    var allowed = true
    var attempts = 0
}

private final class CursorSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [String] = []
    private var errors: [String: CGError] = [:]
    private var clock: UInt64 = 0
    private var warpTarget: CGPoint?
    private var visibility: Bool?
    var visible: Bool? { get { lock.withLock { visibility } } set { lock.withLock { visibility = newValue } } }
    var calls: [String] { lock.withLock { history } }
    var lastWarp: CGPoint? { lock.withLock { warpTarget } }
    var time: UInt64 { get { lock.withLock { clock } } set { lock.withLock { clock = newValue } } }
    func set(_ action: String, _ result: CGError) { lock.withLock { errors[action] = result } }
    func call(_ action: String) -> CGError { lock.withLock { history.append(action); return errors[action] ?? .success } }
    func resources(watchdogEnabled: Bool = false, realClock: Bool = false, native: Bool = false,
                   onWarp: @escaping @Sendable (CGPoint) -> Void = { _ in }) -> SharingCursorResources {
        SharingCursorResources(calls: SharingCursorCalls(associate: { [self] in call($0 ? "reattach" : "detach") },
            hide: { [self] in
                let result = call("hide")
                if native && result == .success { visible = false }
                return result
            }, show: { [self] in call("show") }, warp: { [self] point in
                lock.withLock { warpTarget = point }
                let result = call("warp")
                if result == .success { onWarp(point) }
                return result
            }, takeCursorRegion: { native }, refreshDisplay: { native }, cursorVisible: { [self] in visible }),
            watchdogEnabled: watchdogEnabled, now: { [self] in realClock ? DispatchTime.now().uptimeNanoseconds : time })
    }
}
@MainActor private final class CursorSurface: SharingCursorSurface {
    var position: CGPoint? = CGPoint(x: 50, y: 40)
    var inset: CGPoint?
    func parkingPoint(for origin: CGPoint) -> CGPoint { inset ?? origin }
    var isPresented = false
    var isHittable = true
    var allowGlyph = true
    var glyphSets = 0
    var panelPoint: CGPoint?
    func makePanel(at point: CGPoint, covering target: CGPoint, refreshGlyph: @escaping () -> Void) throws -> SharingCursorPanelLease {
        panelPoint = point
        return SharingCursorPanelLease(retireGlyph: {}, withdraw: { true })
    }
    func presentPanel() { isPresented = true }
    func ownsPoint(_ point: CGPoint) -> Bool { isPresented && isHittable }
    func setGlyph(at point: CGPoint) -> Bool {
        guard ownsPoint(point), allowGlyph else { return false }
        glyphSets += 1; return true
    }
    func closePanel() { isPresented = false; panelPoint = nil }
}
