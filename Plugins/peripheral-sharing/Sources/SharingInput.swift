import AppKit
import UntitledPluginSDK
import Carbon
@preconcurrency import ApplicationServices

@MainActor final class SharingInput {
    enum Mode { case local, staged, controlling, receiving, parked }
    static let replayMarker: Int64 = 0x554E544C534852
    private static let receiverReplayPrefix: UInt64 = 0x554E_0000_0000_0000
    private static let releaseReplayPrefix: UInt64 = 0x554C_0000_0000_0000
    private static let localReplayPrefix: UInt64 = 0x554F_0000_0000_0000
    var send: (SharingInputPacket) -> Void = { _ in }
    var requestControl: (SharingEdge, Double) -> Void = { _, _ in }
    var returnLocal: (SharingCursorPosition?) -> Void = { _ in }
    var returnAcrossEdge: (SharingCursorPosition?) -> Void = { _ in }
    var localResumed: () -> Void = {}
    var physicalStateChanged: () -> Void = {}
    var failure: (String) -> Void = { _ in }
    var captureInterrupted: ((SharingCursorInterruption) -> Void)?
    var edge: SharingEdge = .right
    var workspace: SharingDisplayLayout?
    var canSwitch = false
    private(set) var mode: Mode = .local
    private var returnEdge: SharingEdge = .left
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var remoteHeld = SharingHeldInputState()
    private var deliveredRemoteHeld = SharingHeldInputState()
    private var physical = SharingHeldInputState()
    var routeHostShortcut: (CGEventType, CGEvent) -> Bool = { _, _ in false }
    var priorityOwnsKey: (UInt32) -> Bool = { _ in false }
    var priorityOwnsButton: (UInt32) -> Bool = { _ in false }
    var priorityHasOutstandingKeys: () -> Bool = { false }
    var isNeutral: Bool { physical.isNeutral && !priorityHasOutstandingKeys() }
    var allowsLocalPriorityShortcuts: Bool {
        mode == .local && !transitionPending && preparedReceiver == nil && !needsRecovery
            && pendingReceiverReplay.isEmpty && pendingReleaseReplay.isEmpty && pendingLocalReplay.isEmpty
    }
    // Bookkeeping only: remove a hardware-sampled down now owned by the host;
    // never run handoff/business callbacks from the priority tap's matcher.
    func notePriorityShortcutOwnership(_ code: UInt32, mouse: Bool = false) {
        physical.observe(.init(kind: mouse ? .up : .keyUp, code: Int(code)))
        physicalEpoch &+= 1
    }
    func priorityShortcutOwnershipChanged() { physicalStateChanged() }
    static func isHostShortcutReplay(_ event: CGEvent) -> Bool {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let prefix = UInt64(bitPattern: marker) & 0xFFFF_0000_0000_0000
        return marker == replayMarker || prefix == receiverReplayPrefix || prefix == releaseReplayPrefix || prefix == localReplayPrefix
    }
    private var heldKeys: Set<Int> { remoteHeld.keys }
    private var heldButtons: Set<Int> { remoteHeld.buttons }
    private var shortcutKeys = Set<Int>()
    private var switchAllowedAt: TimeInterval = 0
    private var stagedMotion = CGPoint.zero // One bounded move, never keys queued for remote delivery.
    private let handoffClock: () -> TimeInterval
    private let cursor: SharingCursorCapture
    private let tapReadyOverride: (() -> Bool)?
    private let repairTapOverride: (() -> Void)?
    private let receiverWarp: (CGPoint) -> CGError
    private let eventClock: () -> UInt64
    private var pointerRestoreInProgress = false
    private var pointerRestoredAt: UInt64 = 0
    private var droppedPreRestoreMotion = 0
    private var insideTap = false, tapTransitionPending = false
    var transitionPending: Bool { tapTransitionPending || localResumeTask != nil }
    private let frontmostPID: () -> pid_t?
    private(set) var physicalMouseMovements = 0
    private(set) var externalInputEvents = 0
    private(set) var lastSafetyFailure: String?
    private var receiverCursor: SharingPointerAccumulator?
    private var receiverEpoch: UInt64 = 0, replaySequence: UInt64 = 0
    private lazy var replaySource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private var pendingReceiverReplay: [Int64: (epoch: UInt64, held: SharingInputPacket?)] = [:] // At most 512 receiver events.
    private var pendingReleaseReplay: Set<Int64> = [] // At most 288 held key/button releases.
    private var pendingLocalReplay: [Int64: pid_t] = [:] // At most 128 genuine local resume events.
    private var droppedReceiverReplay = 0
    private var replayDrainMilliseconds: Double?
    private var localResumeTask: Task<Void, Never>?
    private var localResumeGeneration: UInt64 = 0
    private var localEvents: [CGEvent] = [] // At most 128, transient only; never logged.
    private var localPointer: CGPoint?
    private var physicalEpoch: UInt64 = 0
    private var preparedReceiver: (edge: SharingEdge, fraction: Double, epoch: UInt64)?
    private let eventPoster: (CGEvent) -> Void
    init(cursor: SharingCursorCapture = SharingCursorCapture(), tapReadyOverride: (() -> Bool)? = nil,
         receiverWarp: @escaping (CGPoint) -> CGError = SharingPointerWarp.move,
         eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         handoffClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         frontmostPID: (() -> pid_t?)? = nil,
         eventClock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         repairTapOverride: (() -> Void)? = nil) {
        self.handoffClock = handoffClock
        self.eventClock = eventClock
        self.frontmostPID = frontmostPID ?? (tapReadyOverride == nil ? { NSWorkspace.shared.frontmostApplication?.processIdentifier } : { 42 })
        self.cursor = cursor; self.tapReadyOverride = tapReadyOverride; self.receiverWarp = receiverWarp; self.eventPoster = eventPoster
        self.repairTapOverride = repairTapOverride
    }
    var tapReady: Bool {
        if let tapReadyOverride { return tapReadyOverride() }
        return tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }
    var needsRecovery: Bool { cursor.needsRecovery }
    var isCapturing: Bool { mode == .controlling && !transitionPending && cursor.isCaptured && tapReady }
    var isStaged: Bool { mode == .staged && !transitionPending && cursor.isCaptured && tapReady }
    var isParked: Bool { mode == .parked && !transitionPending && cursor.isCaptured && tapReady }
    var canAcceptHandoff: Bool { tapReady && !transitionPending && !needsRecovery && isNeutral }
    var canAcceptDirectEntry: Bool {
        canAcceptHandoff && (mode == .local || isParked) && preparedReceiver == nil
            && pendingReceiverReplay.isEmpty && pendingReleaseReplay.isEmpty && pendingLocalReplay.isEmpty
    }
    var safetyDiagnostics: [String: Any] {
        var value = cursor.snapshot
        value["mode"] = String(describing: mode); value["tapReady"] = tapReady
        value["queuedLocalEvents"] = localEvents.count
        value["queuedReceiverEvents"] = pendingReceiverReplay.count
        value["queuedReleaseEvents"] = pendingReleaseReplay.count
        value["queuedLocalReplayEvents"] = pendingLocalReplay.count
        value["droppedStaleReceiverEvents"] = droppedReceiverReplay
        value["droppedPreRestoreMotion"] = droppedPreRestoreMotion
        if let replayDrainMilliseconds { value["replayDrainMilliseconds"] = replayDrainMilliseconds }
        value["physicalMouseMovements"] = physicalMouseMovements; value["externalInputEvents"] = externalInputEvents
        if let lastSafetyFailure { value["failure"] = lastSafetyFailure }
        return value
    }
    func captureValidationError() -> String? {
        cursor.observeDrift() // Explicit diagnostic only; no position checks on the live routing path.
        do { try cursor.validate(tapReady: tapReady); return nil }
        catch { return error.localizedDescription }
    }
    func maintainCapture() {
        guard !transitionPending else { return }
        if mode == .parked {
            if reconcileParkedCapture(), mode == .parked { cursor.heartbeat() }
            return
        }
        guard mode == .controlling || mode == .staged else { return }
        do { try cursor.validate(tapReady: tapReady); cursor.heartbeat() }
        catch { failCapture(error) }
    }
    /// Outside the tap. Once control has gone back to the peer, parking only
    /// hides this screen's idle cursor. An expired, fully cleaned parking lease
    /// is not an input failure; keep the tap and the session as they were.
    func reconcileParkedCapture() -> Bool {
        guard mode == .parked else { return true }
        guard !transitionPending else { return false }
        do {
            guard tapReady else { throw SharingCursorInterruption.tapLost }
            if cursor.isCaptured { return true }
            guard try cursor.finishExpiredParking() else { return false }
            mode = .local
            localResumed() // Recompute edge readiness; do not send another .end.
            return true
        } catch {
            failCapture(error)
            return false
        }
    }
    #if DEBUG
    private(set) var appliedPacketCount = 0
    private(set) var replayedEventCount = 0
    #endif

    static var displayRects: [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return [CGDisplayBounds(CGMainDisplayID())] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    static var bounds: CGRect { displayRects.reduce(CGRect.null) { $0.union($1) } }
    static func clamp(_ point: CGPoint) -> CGPoint {
        displayRects.map { rect in
            CGPoint(x: min(rect.maxX - 1, max(rect.minX, point.x)), y: min(rect.maxY - 1, max(rect.minY, point.y)))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? point
    }
    func start() throws {
        guard !needsRecovery else { throw PluginError.invalid("本机光标尚未恢复，暂不能重新启用共享。") }
        // In-process dependency injection for ordinary tests: never create a real OS tap.
        if tapReadyOverride != nil {
            guard tapReady else { throw PluginError.invalid("测试事件通道未就绪。") }
            return
        }
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let suppress = MainActor.assumeIsolated {
                Unmanaged<SharingInput>.fromOpaque(pointer).takeUnretainedValue().handleEventTap(type, event)
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw PluginError.invalid("无法启动键鼠共享，请在应用权限管理中检查辅助功能和输入监控。")
        }
        self.tap = tap; self.source = source
        resamplePhysical()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    func stop() {
        reset(); removeTap()
        canSwitch = false; physical = SharingHeldInputState(); shortcutKeys.removeAll()
        pointerRestoredAt = 0
        discardUnobservedReplay()
    }
    /// A disabled tap may never acknowledge events already submitted to Quartz.
    /// Old input markers remain fenced by the replay epoch or missing receipt;
    /// cleanup releases always pass through, even without a receipt to remove.
    func discardUnobservedReplay() {
        pendingReceiverReplay.removeAll(); pendingReleaseReplay.removeAll(); pendingLocalReplay.removeAll()
    }
    /// Called outside the tap, only with permission and no live handoff.
    func repairTap() -> Bool {
        guard mode == .local, !transitionPending, !needsRecovery else { return false }
        if tapReadyOverride != nil { repairTapOverride?() }
        else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if !tapReady { removeTap(); try? start() }
            if tapReady { resamplePhysical() }
        }
        guard tapReady else { return false }
        shortcutKeys.removeAll(); physicalEpoch &+= 1
        return true
    }
    func capture(maximumDuration: TimeInterval? = nil, deferForwarding: Bool = false) async throws {
        guard mode == .local || mode == .parked, canAcceptHandoff else { throw CancellationError() }
        reset()
        let epoch = receiverEpoch, physicalEpoch = self.physicalEpoch
        try await drainReplay()
        try Task.checkCancellation()
        guard receiverEpoch == epoch, self.physicalEpoch == physicalEpoch, mode == .local,
              !transitionPending else { throw CancellationError() }
        try freeze(into: deferForwarding ? .staged : .controlling, maximumDuration: maximumDuration)
    }
    private func freeze(into next: Mode, maximumDuration: TimeInterval? = nil) throws {
        physicalMouseMovements = 0; externalInputEvents = 0; lastSafetyFailure = nil
        try cursor.acquire(tapReady: { self.tapReady }, neutral: { self.isNeutral && !self.transitionPending },
                           maximumDuration: maximumDuration)
        mode = next
        cursor.updateAppearance(avoidSystemEdges: next == .parked, allowed: { [weak self] in
            guard let self else { return false }
            return self.tapReady && !self.transitionPending
        })
    }
    func validateStaged() throws {
        guard mode == .staged, !transitionPending, isNeutral else { throw CancellationError() }
        try cursor.validate(tapReady: tapReady)
    }
    func beginForwarding() throws {
        try validateStaged()
        mode = .controlling
        let motion = stagedMotion; stagedMotion = .zero
        guard motion != .zero else { return }
        guard cursor.withActiveCapture({ send(.init(kind: .move, x: motion.x, y: motion.y)) }) else { throw SharingCursorInterruption.leaseLost }
    }
    func parkAfterReturn() async throws {
        guard mode == .receiving, remoteHeld.isNeutral, isNeutral else { throw CancellationError() }
        let epoch = physicalEpoch, receiver = receiverEpoch
        // Wait for events we have actually posted. Do not wait for fractional
        // pointer coordinates to converge or an appearance callback to run.
        try await drainReplay()
        guard mode == .receiving, receiverEpoch == receiver, physicalEpoch == epoch,
              !transitionPending, remoteHeld.isNeutral, isNeutral else { throw CancellationError() }
        reset()
        try freeze(into: .parked)
        canSwitch = false
    }
    func prepareReceiving(edge: SharingEdge, fraction: Double, deferPointer: Bool = false) async throws {
        let epoch = physicalEpoch
        await localResumeTask?.value
        guard !Task.isCancelled, physicalEpoch == epoch, reconcileParkedCapture() else { throw CancellationError() }
        // Keep a parked cursor hidden until the new sender has acquired its lease.
        // A stale receiver (e.g. on a cancelled negotiation) still needs a reset.
        if mode != .parked { reset() }
        let receiver = receiverEpoch
        try await drainReplay()
        try Task.checkCancellation()
        guard receiverEpoch == receiver, mode == .local || isParked, physicalEpoch == epoch, canAcceptHandoff else { throw CancellationError() }
        if deferPointer { preparedReceiver = (edge, fraction, epoch) }
        else { try receive(edge: edge, fraction: fraction) }
    }
    func commitReceiving() throws {
        guard reconcileParkedCapture() else { throw CancellationError() }
        guard let preparedReceiver, preparedReceiver.epoch == physicalEpoch, canAcceptHandoff else { throw PluginError.invalid("接收准备已失效，未显示对端光标。") }
        try receive(edge: preparedReceiver.edge, fraction: preparedReceiver.fraction)
    }
    func receiveDirectly(edge: SharingEdge, fraction: Double) throws {
        guard reconcileParkedCapture(), canAcceptDirectEntry else { throw CancellationError() }
        try receive(edge: edge, fraction: fraction)
    }
    func receive(edge: SharingEdge, fraction: Double) throws {
        let entry = edge.opposite
        let position = Self.clamp(entry.entryPoint(fraction: fraction, bounds: Self.bounds))
        let wasParked = mode == .parked
        let errors = reset(restoringPoint: wasParked ? position : nil, requirePosition: wasParked)
        guard errors.isEmpty, canAcceptHandoff, pendingReleaseReplay.isEmpty else { throw PluginError.invalid("本机光标或按键释放尚未完成，已拒绝对端接管。") }
        if !wasParked {
            pointerRestoreInProgress = true
            let result = receiverWarp(position)
            if result == .success { pointerRestoredAt = eventClock() }
            pointerRestoreInProgress = false
            guard result == .success else { throw PluginError.invalid("无法准备接收端指针（\(result.rawValue)），未确认接管。") }
        }
        receiverCursor = SharingPointerAccumulator(position: position)
        returnEdge = entry; mode = .receiving
    }
    @discardableResult func reset(restoring normalized: SharingCursorPosition? = nil, returnMotion: CGPoint? = nil,
                                  handoffDelay: TimeInterval = 0) -> [String] {
        let restorePoint = normalized.map { Self.clamp(Self.returnLanding($0, motion: returnMotion ?? .zero, bounds: Self.bounds)) }
        return reset(restoringPoint: restorePoint, handoffDelay: handoffDelay)
    }
    static func returnLanding(_ point: SharingCursorPosition, motion: CGPoint, bounds: CGRect) -> CGPoint {
        let x = bounds.minX + point.x * (bounds.width - 1), y = bounds.minY + point.y * (bounds.height - 1)
        // Land inside the receiving edge, not on its re-crossing threshold.
        // Genuine subsequent motion may still turn around without a timer.
        var target = CGPoint(x: x + motion.x, y: y + motion.y)
        if point.x <= 0.00001 { target.x = max(bounds.minX + 4, target.x) }
        if point.x >= 0.99999 { target.x = min(bounds.maxX - 5, target.x) }
        if point.y <= 0.00001 { target.y = max(bounds.minY + 4, target.y) }
        if point.y >= 0.99999 { target.y = min(bounds.maxY - 5, target.y) }
        return target
    }
    private func reset(restoringPoint: CGPoint?, requirePosition: Bool = false, handoffDelay: TimeInterval = 0) -> [String] {
        tapTransitionPending = false
        localResumeGeneration &+= 1; localResumeTask?.cancel(); localResumeTask = nil
        localEvents.removeAll(); localPointer = nil; preparedReceiver = nil
        receiverEpoch &+= 1; stagedMotion = .zero
        let wasCaptured = cursor.isCaptured
        pointerRestoreInProgress = wasCaptured
        let recoveryErrors = cursor.release(restoring: restoringPoint, requirePosition: requirePosition)
        if wasCaptured { pointerRestoredAt = eventClock() }
        pointerRestoreInProgress = false
        mode = .local; switchAllowedAt = handoffClock() + min(0.65, max(0, handoffDelay))
        // Release on the target as well as on disconnect, lock, disable and tap timeout.
        // Include delivered state: a queued key-up can be invalidated even after
        // the desired remote state is neutral. Its matching down still needs up.
        let releases = remoteHeld.releasePlan(including: deliveredRemoteHeld)
        remoteHeld = SharingHeldInputState(); deliveredRemoteHeld = SharingHeldInputState()
        for packet in releases {
            let event: CGEvent?
            if packet.kind == .up {
                let button = packet.code
                event = CGEvent(mouseEventSource: replaySource, mouseType: button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp,
                    mouseCursorPosition: receiverCursor?.position ?? CGEvent(source: nil)?.location ?? .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)
            } else {
                event = CGEvent(keyboardEventSource: replaySource, virtualKey: CGKeyCode(packet.code), keyDown: false)
                if packet.kind == .flags { event?.type = .flagsChanged }
            }
            event?.flags = []; postRelease(event)
        }
        receiverCursor = nil
        return recoveryErrors
    }
    private func failCapture(_ error: Error) {
        failCapture(error.localizedDescription, interruption: error as? SharingCursorInterruption)
    }
    private func failCapture(_ message: String, interruption: SharingCursorInterruption? = nil) {
        afterTap { [weak self] in
            guard let self else { return }
            self.lastSafetyFailure = message
            self.canSwitch = false
            if let interruption, interruption.canRepairCapture, let recover = self.captureInterrupted {
                recover(interruption) // The controller owns ending this handoff exactly once.
                return
            }
            let errors = self.reset()
            self.failure(errors.isEmpty ? message : message + "（" + errors.joined(separator: "；") + "）")
        }
    }
    // Suppression/routing decisions are synchronous. WindowServer must not be
    // asked to hide, show, warp, or withdraw a panel while it awaits the tap.
    func handleEventTap(_ type: CGEventType, _ event: CGEvent) -> Bool {
        insideTap = true; defer { insideTap = false }
        return handle(type, event)
    }
    private func afterTap(_ work: @escaping () -> Void) {
        guard insideTap else { work(); return }
        guard !tapTransitionPending else { return }
        tapTransitionPending = true
        let epoch = receiverEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.receiverEpoch == epoch, self.tapTransitionPending else { return }
            self.tapTransitionPending = false; work()
        }
    }
    private func resamplePhysical() {
        physical = SharingHeldInputState()
        for code in 0...127 where code != 57 && !priorityOwnsKey(UInt32(code)) && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) {
            physical.observe(.init(kind: .keyDown, code: code))
        }
        for button in 0...31 where !priorityOwnsButton(UInt32(button)) && CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: UInt32(button))!) {
            physical.observe(.init(kind: .down, code: button))
        }
    }
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            failCapture(SharingCursorInterruption.tapLost)
            return false
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let prefix = UInt64(bitPattern: marker) & 0xFFFF_0000_0000_0000
        if prefix == Self.localReplayPrefix {
            guard let target = pendingLocalReplay.removeValue(forKey: marker) else { return true }
            return frontmostPID() != target || (tapReadyOverride == nil && IsSecureEventInputEnabled())
        }
        if prefix == Self.releaseReplayPrefix {
            pendingReleaseReplay.remove(marker)
            return false // Never discard a key/button-up needed by a prior receiver.
        }
        if prefix == Self.receiverReplayPrefix {
            let replay = pendingReceiverReplay.removeValue(forKey: marker)
            guard replay?.epoch == receiverEpoch, mode == .receiving else { droppedReceiverReplay += 1; return true }
            if let held = replay?.held { deliveredRemoteHeld.observe(held) }
            #if DEBUG
            replayedEventCount += 1
            #endif
            return false
        }
        if marker == Self.replayMarker {
            #if DEBUG
            replayedEventCount += 1
            #endif
            return false
        }
        // Don't forward or use injected events from other automation as a handoff trigger.
        if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
            if mode == .controlling || mode == .staged { externalInputEvents += 1 }
            return false
        }
        if routeHostShortcut(type, event) { return true }
        if Self.isPointerMotion(type), pointerRestoreInProgress || (event.timestamp != 0 && event.timestamp < pointerRestoredAt) {
            droppedPreRestoreMotion += 1
            return true // A queued pre-warp movement must not reposition or re-enter an edge.
        }
        observePhysical(type, event)
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, shortcutKeys.remove(code) != nil { return true }
        if tapTransitionPending { return cursor.panelBlocksLocalInput }
        let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if type == .keyDown, event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == chord,
           code == 53 || code == 40 {
            shortcutKeys.insert(code)
            if code == 53 || mode != .local { afterTap { [weak self] in self?.returnLocal(nil) } }
            else if canSwitch {
                if let entry = workspace?.defaultEntry { requestAfterTap(entry.wireEdge, entry.fraction, needsNeutral: false) }
                else { requestAfterTap(edge, 0.5, needsNeutral: false) }
            }
            return true
        }
        if localResumeTask != nil { resumeLocalInput(event); return true }
        if mode == .staged {
            if type != .mouseMoved {
                resumeLocalInput(event) // Withdraw first, then replay only to the unchanged foreground.
                return true
            }
            guard cursor.isCaptured else { failCapture(SharingCursorInterruption.leaseLost); return insideTap }
            let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            stagedMotion.x = min(4096, max(-4096, stagedMotion.x + dx)); stagedMotion.y = min(4096, max(-4096, stagedMotion.y + dy))
            if dx != 0 || dy != 0 { physicalMouseMovements += 1 }
            return true // No network input before entry/commit is sent with a live lease.
        }
        if mode == .parked {
            resumeLocalInput(event)
            return true
        }
        if mode == .controlling {
            if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type),
               event.getDoubleValueField(.mouseEventDeltaX) != 0 || event.getDoubleValueField(.mouseEventDeltaY) != 0 { physicalMouseMovements += 1 }
            do {
                if insideTap { guard cursor.isCaptured else { throw SharingCursorInterruption.leaseLost } }
                else { try cursor.validate(tapReady: tapReady) }
            } catch { failCapture(error); return insideTap }
        }
        if mode == .receiving {
            // Real native callbacks queue cleanup and replay, so there is no
            // WindowServer round trip while it waits for this event's decision.
            if Self.isPhysicalActivity(type) {
                if insideTap { resumeLocalInput(event); return true }
                returnLocal(nil)
            }
            return false
        }
        let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX), y: event.getDoubleValueField(.mouseEventDeltaY))
        if mode == .local {
            if canSwitch, type == .mouseMoved, isNeutral,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
               handoffClock() >= switchAllowedAt {
                if let workspace {
                    if let entry = workspace.handoff(point: event.location, delta: delta, screen: Self.bounds) {
                        switchAllowedAt = handoffClock() + 0.65; requestAfterTap(entry.wireEdge, entry.fraction, needsNeutral: true)
                    }
                } else if edge.isCrossing(event.location, delta: delta, bounds: Self.bounds) {
                    switchAllowedAt = handoffClock() + 0.65; requestAfterTap(edge, edge.fraction(event.location, bounds: Self.bounds), needsNeutral: true)
                }
            }
            return false
        }
        var packet = SharingInputPacket(kind: .move, flags: event.flags.rawValue & SharingInputPacket.allowedFlags)
        switch type {
        case .keyDown: packet.kind = .keyDown; packet.code = code
        case .keyUp: packet.kind = .keyUp; packet.code = code
        case .flagsChanged:
            packet.kind = .flags; packet.code = code
            packet.pressed = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            packet.x = min(4096, max(-4096, delta.x)); packet.y = min(4096, max(-4096, delta.y))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            packet.kind = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) ? .down : .up
            packet.code = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            packet.clickCount = min(3, max(1, Int(event.getIntegerValueField(.mouseEventClickState))))
        case .scrollWheel:
            packet.kind = .scroll
            packet.x = min(4096, max(-4096, event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)))
            packet.y = min(4096, max(-4096, event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)))
        default: return false
        }
        // The watchdog and the send callback serialize on the same generational lease.
        // A stale .controlling enum can never reopen forwarding after background recovery.
        guard cursor.withActiveCapture({ send(packet) }) else {
            failCapture(SharingCursorInterruption.leaseLost)
            return insideTap
        }
        return true
    }
    private func requestAfterTap(_ edge: SharingEdge, _ fraction: Double, needsNeutral: Bool) {
        if !insideTap { requestControl(edge, fraction); return }
        let epoch = receiverEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.receiverEpoch == epoch, self.canSwitch, self.mode == .local,
                  !self.transitionPending, !needsNeutral || self.isNeutral else { return }
            self.requestControl(edge, fraction)
        }
    }
    func apply(_ packet: SharingInputPacket) {
        guard mode == .receiving, !transitionPending, (try? packet.validate()) != nil else { return }
        guard pendingReceiverReplay.count < 512 else { failCapture("接收输入回放积压，已安全归还控制。"); return }
        #if DEBUG
        appliedPacketCount += 1
        #endif
        remoteHeld.observe(packet)
        var event: CGEvent?
        // CGEvent.post is asynchronous. Later packets in the same network batch
        // must use our logical cursor, not a still-stale system cursor snapshot.
        let current = receiverCursor?.position ?? CGEvent(source: nil)?.location ?? .zero
        switch packet.kind {
        case .move:
            let next = CGPoint(x: current.x + packet.x, y: current.y + packet.y)
            if heldButtons.isEmpty, heldKeys.isEmpty, handoffClock() >= switchAllowedAt {
                if let workspace {
                    if let entry = workspace.handoff(point: next, delta: .init(x: packet.x, y: packet.y), screen: Self.bounds) { returnAcrossEdge(entry.position); return }
                } else if returnEdge.isCrossing(next, delta: .init(x: packet.x, y: packet.y), bounds: Self.bounds) { returnAcrossEdge(nil); return }
            }
            let button = heldButtons.sorted().first
            let type: CGEventType = button == nil ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
            var pointer = receiverCursor ?? SharingPointerAccumulator(position: current)
            let position = pointer.advance(x: packet.x, y: packet.y) { Self.clamp($0) }
            receiverCursor = pointer
            event = CGEvent(mouseEventSource: replaySource, mouseType: type, mouseCursorPosition: position, mouseButton: CGMouseButton(rawValue: UInt32(button ?? 0))!)
            // This is already an absolute target position. Reapplying deltas at
            // the HID tap can introduce a second round of pointer acceleration.
        case .down, .up:
            let down = packet.kind == .down
            let type: CGEventType = packet.code == 0 ? (down ? .leftMouseDown : .leftMouseUp) : packet.code == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            event = CGEvent(mouseEventSource: replaySource, mouseType: type, mouseCursorPosition: current, mouseButton: CGMouseButton(rawValue: UInt32(packet.code))!)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(packet.clickCount))
        case .keyDown, .keyUp, .flags:
            let down = packet.kind == .keyDown
            event = CGEvent(keyboardEventSource: replaySource, virtualKey: CGKeyCode(packet.code), keyDown: packet.kind == .flags ? packet.pressed : down)
            if packet.kind == .flags { event?.type = .flagsChanged }
        case .scroll:
            event = CGEvent(scrollWheelEvent2Source: replaySource, units: .pixel, wheelCount: 2, wheel1: Int32(packet.y), wheel2: Int32(packet.x), wheel3: 0)
        }
        event?.flags = CGEventFlags(rawValue: packet.flags)
        postReceiver(event, packet: packet)
    }
    private func replayToken(prefix: UInt64) -> Int64 {
        replaySequence = (replaySequence &+ 1) & 0x0000_FFFF_FFFF_FFFF
        return Int64(bitPattern: prefix | replaySequence)
    }
    private func postReceiver(_ event: CGEvent?, packet: SharingInputPacket) {
        guard let event else { return }
        let token = replayToken(prefix: Self.receiverReplayPrefix)
        let held: SharingInputPacket? = [.keyDown, .keyUp, .flags, .down, .up].contains(packet.kind) ? packet : nil
        pendingReceiverReplay[token] = (receiverEpoch, held)
        event.setIntegerValueField(.eventSourceUserData, value: token)
        eventPoster(event)
    }
    private func postRelease(_ event: CGEvent?) {
        guard let event else { return }
        let token = replayToken(prefix: Self.releaseReplayPrefix)
        pendingReleaseReplay.insert(token)
        event.setIntegerValueField(.eventSourceUserData, value: token)
        eventPoster(event)
    }
    private func drainReplay() async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { replayDrainMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 }
        let deadline = started + 250_000_000
        while !pendingReceiverReplay.isEmpty || !pendingReleaseReplay.isEmpty || !pendingLocalReplay.isEmpty {
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw SharingCursorInterruption.replayBusy }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
    }
    private func observePhysical(_ type: CGEventType, _ event: CGEvent) {
        if Self.isPhysicalActivity(type) { physicalEpoch &+= 1 }
        let old = physical, code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown: physical.observe(.init(kind: .keyDown, code: code))
        case .keyUp: physical.observe(.init(kind: .keyUp, code: code))
        case .flagsChanged: physical.observe(.init(kind: .flags, code: code, pressed: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: physical.observe(.init(kind: .down, code: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: physical.observe(.init(kind: .up, code: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        default: break
        }
        if old != physical { physicalStateChanged() }
        if preparedReceiver != nil, mode == .local, Self.isPhysicalActivity(type) { afterTap { [weak self] in self?.returnLocal(nil) } }
    }
    private static func isPointerMotion(_ type: CGEventType) -> Bool {
        type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
    }
    nonisolated static func isPhysicalActivity(_ type: CGEventType) -> Bool {
        [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
         .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel].contains(type)
    }
    private func resumeLocalInput(_ event: CGEvent) {
        if localResumeTask == nil {
            canSwitch = false
            localPointer = cursor.frozenPosition ?? event.location
            let generation = localResumeGeneration, target = frontmostPID()
            localResumeTask = Task { @MainActor [weak self] in
                guard let self, generation == self.localResumeGeneration, !Task.isCancelled else { return }
                let events = self.localEvents; self.localEvents.removeAll(); self.localPointer = nil
                self.localResumeTask = nil
                let epoch = self.receiverEpoch
                self.returnLocal(nil) // Revoke a still-forwarding peer before replay.
                let errors = epoch == self.receiverEpoch ? self.reset(handoffDelay: 0.65) : []
                guard errors.isEmpty, !self.cursor.cleanupPending, self.tapReady else { return }
                // No app is activated/restored. If a different app is now in
                // front, drop the batch rather than type or click into it.
                if let target, self.frontmostPID() == target, self.tapReadyOverride != nil || !IsSecureEventInputEnabled() {
                    events.forEach { self.post($0, to: target) }
                }
                self.localResumed()
            }
        }
        guard let copy = event.copy() else { return }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(copy.type), let point = localPointer {
            let next = Self.clamp(CGPoint(x: point.x + copy.getDoubleValueField(.mouseEventDeltaX), y: point.y + copy.getDoubleValueField(.mouseEventDeltaY)))
            copy.location = next; localPointer = next
            if localEvents.last?.type == copy.type { localEvents.removeLast() }
        }
        guard localEvents.count < 128, pendingLocalReplay.count + localEvents.count < 128 else {
            localResumeTask?.cancel(); localResumeTask = nil; localEvents.removeAll()
            failCapture("本机输入恢复队列已满，共享已暂停。"); return
        }
        localEvents.append(copy)
    }
    private func post(_ event: CGEvent, to target: pid_t) {
        let token = replayToken(prefix: Self.localReplayPrefix)
        pendingLocalReplay[token] = target
        event.setIntegerValueField(.eventSourceUserData, value: token)
        eventPoster(event)
    }
}
