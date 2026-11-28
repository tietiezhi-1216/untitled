import AppKit
import UntitledPluginSDK
@preconcurrency import ApplicationServices
import Foundation

struct SharingCursorCalls: Sendable {
    var associate: @Sendable (Bool) -> CGError = { CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0) }
    var hide: @Sendable () -> CGError = { CGDisplayHideCursor(CGMainDisplayID()) }
    var show: @Sendable () -> CGError = { CGDisplayShowCursor(CGMainDisplayID()) }
    var warp: @Sendable (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) }
    var enableBackground: @Sendable () -> CGError = { .success }
    var takeCursorRegion: @Sendable () -> Bool = { false }
    var releaseCursorRegion: @Sendable () -> CGError = { .success }
    var refreshDisplay: @Sendable () -> Bool = { false }
    var cursorVisible: @Sendable () -> Bool? = { nil }
}

/// WindowServer parts only. The AppKit object stays on the main actor; the
/// watchdog can still retire the glyph and remove the panel from hit testing.
struct SharingCursorPanelLease: Sendable {
    let retireGlyph: @Sendable () -> Void
    let withdraw: @Sendable () -> Bool
}

/// Metadata never holds a lock across CG calls or an arbitrary send callback. The
/// watchdog can revoke a lease even if such a call stalls. CG recovery is serialized
/// separately; recovery still requires a responsive WindowServer, not hard realtime.
final class SharingCursorResources: @unchecked Sendable {
    private let lock = NSLock()
    private let operations = NSRecursiveLock()
    private let calls: SharingCursorCalls
    private let now: @Sendable () -> UInt64
    private let watchdogEnabled: Bool
    private let queue = DispatchQueue(label: "com.untitled.app.cursor-safety", qos: .userInteractive)
    private let recoveryQueue = DispatchQueue(label: "com.untitled.app.cursor-recovery", qos: .userInteractive)
    private var watchdog: DispatchSourceTimer?
    private var hidden = false, detached = false, active = false, acquiring = false
    private var region = false, panelConfirmed = false
    private var panel: SharingCursorPanelLease?
    private var revoked = true, recoveryQueued = false, shuttingDown = false
    private var leaseID: UInt64 = 0, lastHeartbeat: UInt64 = 0
    private var hardDeadline: UInt64?
    private var timedOut = false
    private var nativeEvidence = "not-checked"
    private var results: [String: Int32] = [:]
    private var errors: [String: String] = [:]
    private var recovered: (@Sendable () -> Void)?

    init(calls: SharingCursorCalls = .background, watchdogEnabled: Bool = true,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.calls = calls; self.watchdogEnabled = watchdogEnabled; self.now = now
    }
    deinit { locked { shuttingDown = true }; _ = release(); watchdog?.cancel() }
    var isActive: Bool { eligible(token: locked { leaseID }) }
    var needsRecovery: Bool { locked { acquiring || recoveryQueued || (!active && ownsResources) } }
    enum ExpiredRecovery { case pending, complete, failed }
    var expiredRecovery: ExpiredRecovery? {
        locked {
            guard timedOut, revoked else { return nil }
            if !errors.isEmpty { return .failed }
            return acquiring || recoveryQueued || ownsResources ? .pending : .complete
        }
    }
    // Access only under the metadata lock.
    private var ownsResources: Bool { detached || hidden || region || panel != nil }
    func onRecovery(_ callback: @escaping @Sendable () -> Void) { locked { recovered = callback } }
    func isActive(token: UInt64) -> Bool { eligible(token: token) }
    var snapshot: [String: Any] {
        locked { ["active": active && !revoked && !expiredLocked(), "ownsHiddenCursor": hidden,
                  "ownsDisassociation": detached, "ownsCursorRegion": region,
                  "ownsCursorPanel": panel != nil, "cursorOwnerAcknowledged": panelConfirmed,
                  "watchdogExpired": timedOut, "leaseGeneration": leaseID, "nativeHideEvidence": nativeEvidence,
                  "apiResults": results, "cleanupErrors": errors.values.sorted(),
                  "recoveryPending": recoveryQueued || acquiring || (!active && ownsResources)] }
    }
    @discardableResult func acquire(maximumDuration: TimeInterval? = nil) throws -> UInt64 {
        operations.lock()
        defer { operations.unlock(); finishWatchdogIfIdle(); notifyRecovery() }
        let token: UInt64 = try locked {
            guard !active, !acquiring, !recoveryQueued, !ownsResources else { throw PluginError.invalid("上次光标恢复尚未完成，已阻止再次接管。") }
            if let maximumDuration, !maximumDuration.isFinite || maximumDuration <= 0 || maximumDuration > 10 { throw PluginError.invalid("接管诊断必须在十秒内自动结束。") }
            leaseID &+= 1; revoked = false; acquiring = true
            lastHeartbeat = now(); hardDeadline = maximumDuration.map { lastHeartbeat + UInt64($0 * 1_000_000_000) }
            results = [:]; errors = [:]; timedOut = false
            nativeEvidence = "not-checked"
            return leaseID
        }
        ensureWatchdog()
        do {
            let background = calls.enableBackground()
            locked { results["background"] = background.rawValue }
            // Optional background/region APIs affect the cursor's appearance,
            // not the lifetime of an otherwise successful native freeze.
            let regionOwned = calls.takeCursorRegion()
            locked { region = regionOwned }
            guard acquisitionCurrent(token) else { throw CancellationError() }
            // Hide at the source before freezing it. Do not move it to another
            // spot just to hide it, and never stack native hide requests.
            let hide = calls.hide()
            locked { results["hide"] = hide.rawValue; hidden = hide == .success }
            guard hide == .success else { throw SharingCursorInterruption.hideRejected(hide.rawValue) }
            guard acquisitionCurrent(token) else { throw CancellationError() }
            let associate = calls.associate(false)
            locked { results["detach"] = associate.rawValue; detached = associate == .success }
            guard associate == .success else { throw SharingCursorInterruption.freezeRejected(associate.rawValue) }
            let committed = locked {
                acquiring = false
                guard token == leaseID, !revoked, !expiredLocked() else { revokeLocked(); return false }
                active = true; lastHeartbeat = now(); return true
            }
            guard committed else { throw CancellationError() }
            if watchdogEnabled, let deadline = locked({ hardDeadline }) {
                queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in self?.expireDeadline(token: token) }
            }
            return token
        } catch {
            locked { acquiring = false; revokeLocked() }
            _ = cleanup(warp: nil)
            throw error
        }
    }
    private func acquisitionCurrent(_ token: UInt64) -> Bool {
        locked { token == leaseID && !revoked && !expiredLocked() }
    }
    /// Register before ordering the panel in, so a watchdog release cannot race
    /// a late order-in. Never invoke these methods from the event tap callback.
    func placePanel(_ lease: SharingCursorPanelLease, token: UInt64, show: () -> Void) -> Bool {
        operations.lock(); defer { operations.unlock() }
        guard eligible(token: token), locked({ panel == nil }) else { return false }
        locked { panel = lease }
        show()
        return eligible(token: token)
    }
    func confirmPanel(token: UInt64, setGlyph: () -> Bool) -> Bool {
        operations.lock(); defer { operations.unlock() }
        guard eligible(token: token), locked({ panel != nil }), setGlyph() else { return false }
        // Keep the original balanced hide request. Do not show/re-hide just
        // to confirm a cosmetic effect or poll the visibility bit.
        locked { panelConfirmed = true }
        return eligible(token: token)
    }
    func refreshGlyph(token: UInt64, _ setGlyph: () -> Void) {
        guard operations.try() else { return }
        defer { operations.unlock() }
        guard eligible(token: token), locked({ panelConfirmed }) else { return }
        setGlyph()
    }
    func parkBehindPanel(at point: CGPoint, token: UInt64) -> Bool {
        operations.lock(); defer { operations.unlock() }
        guard eligible(token: token), locked({ panelConfirmed }) else { return false }
        // Synchronous and same lease. No posted relocation can arrive after
        // return and steal the freshly restored cursor position.
        let result = calls.warp(point)
        locked { results["parkAwayFromSystemEdge"] = result.rawValue }
        if result == .success { _ = calls.refreshDisplay() }
        return result == .success && eligible(token: token)
    }
    func observeAppearance(token: UInt64) {
        operations.lock(); defer { operations.unlock() }
        guard eligible(token: token) else { return }
        let submitted = calls.refreshDisplay()
        let visible = calls.cursorVisible()
        locked {
            results["displayUpdateSubmitted"] = submitted ? 1 : 0
            nativeEvidence = visible.map { $0 ? "still-visible" : "reported-hidden" } ?? "visibility-unavailable"
        }
    }
    func abandonPanel(token: UInt64) {
        operations.lock(); defer { operations.unlock() }
        guard eligible(token: token) else { return }
        cleanPanel()
    }
    func heartbeat(token: UInt64) {
        let recoveryGeneration: UInt64? = locked {
            guard token == leaseID, active, !revoked else { return nil }
            guard !expiredLocked() else { timedOut = true; revokeLocked(); return leaseID }
            lastHeartbeat = now(); return nil
        }
        if let recoveryGeneration { scheduleRecovery(forGeneration: recoveryGeneration) }
    }
    /// An issued frame can already be in flight when revocation occurs. Do not hold
    /// watchdog metadata hostage to encoding/network callbacks; the transport also
    /// rechecks the same lease immediately before enqueueing an input frame.
    @discardableResult func withActiveCapture(token: UInt64, _ action: () -> Void) -> Bool {
        guard eligible(token: token) else { return false }
        action(); return true
    }
    private func eligible(token: UInt64) -> Bool {
        let state = locked { () -> (Bool, UInt64?) in
            guard token == leaseID, active, !revoked, hidden, detached else { return (false, nil) }
            if expiredLocked() { timedOut = true; revokeLocked(); return (false, leaseID) }
            return (true, nil)
        }
        if let generation = state.1 { scheduleRecovery(forGeneration: generation) }
        return state.0
    }
    private func expiredLocked() -> Bool {
        let instant = now()
        return hardDeadline.map { instant >= $0 } == true || (instant >= lastHeartbeat && instant - lastHeartbeat > 1_000_000_000)
    }
    private func revokeLocked() {
        active = false
        if !revoked { leaseID &+= 1; revoked = true }
    }
    func expireIfStalled() {
        let recoveryGeneration: UInt64? = locked {
            if !revoked, (active || acquiring), expiredLocked() { timedOut = true; revokeLocked() }
            return revoked && (acquiring || ownsResources) ? leaseID : nil
        }
        if let recoveryGeneration {
            if watchdogEnabled { scheduleRecovery(forGeneration: recoveryGeneration) }
            else { _ = release() } // Deterministic fake-clock tests never need dispatch timers.
        }
    }
    private func expireDeadline(token: UInt64) {
        let recoveryGeneration: UInt64? = locked {
            guard token == leaseID, !revoked, let hardDeadline, now() >= hardDeadline else { return nil }
            timedOut = true; revokeLocked(); return leaseID
        }
        if let recoveryGeneration { scheduleRecovery(forGeneration: recoveryGeneration) }
    }
    @discardableResult func release(warp: CGPoint? = nil, requirePosition: Bool = false) -> [String] {
        locked { revokeLocked() }
        operations.lock()
        let positionUnavailable = requirePosition && (warp == nil || !locked({ hidden && detached }))
        let result = cleanup(warp: warp)
        operations.unlock()
        finishWatchdogIfIdle(); notifyRecovery()
        return positionUnavailable ? result + ["停放光标的租约已失效，未定位到入口。"] : result
    }
    /// Called only with the CG operation lock, never with the metadata lock held.
    private func cleanup(warp: CGPoint?) -> [String] {
        // At a normal return, restore position while still hidden. Retire our
        // glyph at the destination without overwriting a newer system cursor.
        if let warp, locked({ hidden && detached }) {
            let result = calls.warp(warp)
            locked { results["restorePosition"] = result.rawValue; if result == .success { errors.removeValue(forKey: "warp") } else { errors["warp"] = "恢复光标位置：\(result.rawValue)" } }
        }
        cleanPanel()
        if locked({ detached }) {
            let result = calls.associate(true)
            locked { results["reattach"] = result.rawValue; if result == .success { detached = false; errors.removeValue(forKey: "reattach") } else { errors["reattach"] = "恢复鼠标关联：\(result.rawValue)" } }
        }
        if locked({ hidden }) {
            let result = calls.show()
            locked { results["show"] = result.rawValue; if result == .success { hidden = false; errors.removeValue(forKey: "show") } else { errors["show"] = "恢复光标显示：\(result.rawValue)" } }
            if result == .success { _ = calls.refreshDisplay() }
        }
        if locked({ region && !hidden }) {
            let result = calls.releaseCursorRegion()
            locked { results["releaseRegion"] = result.rawValue; if result == .success { region = false; errors.removeValue(forKey: "region") } else { errors["region"] = "归还光标区域：\(result.rawValue)" } }
        }
        ensureWatchdog()
        return locked { errors.values.sorted() }
    }
    private func cleanPanel() {
        guard let panel = locked({ panel }) else { return }
        locked { panelConfirmed = false }
        panel.retireGlyph()
        let withdrawn = panel.withdraw()
        locked {
            if withdrawn { self.panel = nil; errors.removeValue(forKey: "panel") }
            else { errors["panel"] = "未能移除本机光标面板" }
        }
    }
    func scheduleRecovery(forGeneration generation: UInt64) {
        guard watchdogEnabled else { return }
        let queued = locked {
            guard generation == leaseID, revoked, !active, acquiring || ownsResources,
                  !shuttingDown, !recoveryQueued else { return false }
            recoveryQueued = true; return true
        }
        guard queued else { return }
        recoveryQueue.async { [weak self] in
            guard let self else { return }
            self.operations.lock()
            if self.locked({ generation == self.leaseID && self.revoked && !self.active }) { _ = self.cleanup(warp: nil) }
            self.operations.unlock()
            self.locked { self.recoveryQueued = false }
            self.finishWatchdogIfIdle(); self.notifyRecovery()
        }
    }
    private func ensureWatchdog() {
        guard watchdogEnabled else { return }
        locked {
            guard !shuttingDown, watchdog == nil, active || acquiring || ownsResources else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.expireIfStalled() }
            watchdog = timer; timer.resume()
        }
    }
    private func finishWatchdogIfIdle() {
        locked {
            if !active, !acquiring, !ownsResources, !recoveryQueued { watchdog?.cancel(); watchdog = nil }
        }
    }
    private func notifyRecovery() {
        let callback = locked { !active && !acquiring && !ownsResources && !recoveryQueued ? recovered : nil }
        callback?()
    }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
}

enum SharingCursorInterruption: LocalizedError, Equatable {
    case backgroundUnavailable, panelUnavailable
    case hideRejected(Int32), freezeRejected(Int32), leaseLost, tapLost, replayBusy

    /// A refused native operation or a busy queue can end one crossing.
    /// Only a revoked lease/tap or unbalanced cleanup disables sharing.
    var mayRetry: Bool {
        switch self {
        case .hideRejected, .freezeRejected, .replayBusy: true
        default: false
        }
    }
    var canRepairCapture: Bool { self == .tapLost || self == .leaseLost }
    var errorDescription: String? {
        switch self {
        case .backgroundUnavailable: "此 macOS 版本未提供可用的后台光标接口。"
        case .panelUnavailable: "后台光标面板不可用。"
        case .hideRejected(let code): "后台隐藏光标失败（\(code)），已取消本次交接。"
        case .freezeRejected(let code): "解除本机鼠标关联失败（\(code)），已取消本次交接。"
        case .leaseLost: "后台光标租约已失效，已归还本机控制。"
        case .tapLost: "键鼠监听已失效，已归还本机控制。"
        case .replayBusy: "上次输入尚未处理完，已取消本次交接。"
        }
    }
}

@MainActor protocol SharingCursorSurface: AnyObject {
    var position: CGPoint? { get }
    var isPresented: Bool { get }
    func parkingPoint(for origin: CGPoint) -> CGPoint
    func makePanel(at point: CGPoint, covering target: CGPoint, refreshGlyph: @escaping () -> Void) throws -> SharingCursorPanelLease
    func presentPanel()
    func ownsPoint(_ point: CGPoint) -> Bool
    func setGlyph(at point: CGPoint) -> Bool
    func closePanel()
}

extension SharingCursorSurface {
    func parkingPoint(for origin: CGPoint) -> CGPoint { origin }
}

@MainActor final class SharingCursorCapture {
    private let resources: SharingCursorResources
    private let surface: any SharingCursorSurface
    private var acquiring = false
    private var anchor: CGPoint?
    private var resourceToken: UInt64?
    private var appearanceTask: Task<Void, Never>?
    private var ownerStage = "not-started"
    private let ownerWait: Duration
    private(set) var maximumDrift: Double = 0
    private var lastFailure: String?
    private var acquisitionMilliseconds: Double?
    private var ownershipMilliseconds: Double?

    init(resources: SharingCursorResources = SharingCursorResources(), surface: any SharingCursorSurface = SharingNativeCursorSurface(),
         ownerWait: Duration = .milliseconds(200)) {
        self.resources = resources; self.surface = surface; self.ownerWait = ownerWait
        resources.onRecovery { [weak self] in
            Task { @MainActor in
                guard let self, !self.acquiring, !self.resources.isActive, !self.resources.needsRecovery else { return }
                self.clearRecoveredPresentation()
            }
        }
    }
    private func clearRecoveredPresentation() {
        appearanceTask?.cancel(); appearanceTask = nil
        anchor = nil; resourceToken = nil
        surface.closePanel()
    }
    /// Called only for a parked cursor after its lease has been revoked. Do not
    /// wait on the CG operation lock or try to warp with the old lease.
    func finishExpiredParking() throws -> Bool {
        switch resources.expiredRecovery {
        case .pending: return false
        case .complete:
            clearRecoveredPresentation()
            ownerStage = "parking-expired"
            return true
        case .failed, nil: throw SharingCursorInterruption.leaseLost
        }
    }
    var cleanupPending: Bool { resources.needsRecovery || surface.isPresented && !isCaptured }
    var needsRecovery: Bool { acquiring || cleanupPending }
    var panelBlocksLocalInput: Bool { surface.isPresented }
    var frozenPosition: CGPoint? { anchor }
    var isCaptured: Bool {
        resourceToken.map { resources.isActive(token: $0) } ?? false
    }
    func heartbeat() {
        if let resourceToken { resources.heartbeat(token: resourceToken) }
    }
    func withActiveCapture(_ action: () -> Void) -> Bool {
        guard let resourceToken else { return false }
        return resources.withActiveCapture(token: resourceToken, action)
    }
    var snapshot: [String: Any] {
        var value = resources.snapshot
        value["cursorBackend"] = "background"
        value["cursorPanelVisible"] = surface.isPresented
        value["cursorOwnerStage"] = ownerStage
        value["acquiring"] = acquiring; value["maximumCursorDrift"] = maximumDrift; value["failure"] = lastFailure ?? ""
        if let acquisitionMilliseconds { value["acquisitionMilliseconds"] = acquisitionMilliseconds }
        if let ownershipMilliseconds { value["ownershipMilliseconds"] = ownershipMilliseconds }
        return value
    }

    func acquire(tapReady: () -> Bool, neutral: () -> Bool, maximumDuration: TimeInterval? = nil) throws {
        try Task.checkCancellation()
        guard !needsRecovery, !isCaptured else { throw SharingCursorInterruption.leaseLost }
        guard tapReady() else { throw SharingCursorInterruption.tapLost }
        guard neutral() else { throw CancellationError() }
        let started = DispatchTime.now().uptimeNanoseconds
        acquiring = true; maximumDrift = 0; lastFailure = nil; ownershipMilliseconds = nil; ownerStage = "freezing"
        defer {
            acquisitionMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            acquiring = false
        }
        do {
            let token = try resources.acquire(maximumDuration: maximumDuration)
            resourceToken = token
            try Task.checkCancellation()
            guard tapReady() else { throw SharingCursorInterruption.tapLost }
            guard neutral() else { throw CancellationError() }
            try validate(tapReady: true)
            anchor = position
            ownerStage = "native-frozen"
        } catch {
            lastFailure = error.localizedDescription
            // Resources.acquire rolls back its own failed attempts.
            if resourceToken != nil { _ = release() }
            throw error
        }
    }
    func validate(tapReady: Bool) throws {
        guard tapReady else { throw SharingCursorInterruption.tapLost }
        guard isCaptured else { throw SharingCursorInterruption.leaseLost }
    }
    private var position: CGPoint? {
        guard let p = surface.position, p.x.isFinite, p.y.isFinite else { return nil }
        return p
    }
    func observeDrift() {
        recordOffset(from: anchor, to: position)
    }
    private func recordOffset(from expected: CGPoint?, to actual: CGPoint?) {
        if let expected, let actual { maximumDrift = max(maximumDrift, hypot(expected.x - actual.x, expected.y - actual.y)) }
    }

    /// Cosmetics follow the native freeze on a separate main-actor turn. No
    /// acknowledgement, polling result, or placement here can decide routing.
    /// There is no posted mouse move; only the active, already hidden receiver
    /// can make a synchronous departure from an occupied system edge.
    func updateAppearance(avoidSystemEdges: Bool = false, allowed: @escaping () -> Bool = { true }) {
        guard let token = resourceToken, appearanceTask == nil, isCaptured else { return }
        appearanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAppearance(token: token, avoidSystemEdges: avoidSystemEdges, allowed: allowed)
        }
    }
    private func prepareAppearance(token: UInt64, avoidSystemEdges: Bool, allowed: () -> Bool) async {
        let started = DispatchTime.now().uptimeNanoseconds
        var keepPanel = false
        defer {
            // A late task must not close a newer lease's panel or write its diagnostics.
            if resourceToken == token {
                appearanceTask = nil
                if !keepPanel {
                    resources.abandonPanel(token: token)
                    surface.closePanel()
                }
                ownershipMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            }
        }
        guard isCurrent(token), allowed() else { return }
        resources.observeAppearance(token: token)
        guard let origin = position else { ownerStage = "position-unavailable"; return }
        recordOffset(from: anchor, to: origin); anchor = origin
        let target = avoidSystemEdges ? surface.parkingPoint(for: origin) : origin
        do {
            let panel = try surface.makePanel(at: origin, covering: target, refreshGlyph: { [weak self] in
                guard let self, self.resourceToken == token, let point = self.position else { return }
                self.resources.refreshGlyph(token: token) { _ = self.surface.setGlyph(at: point) }
            })
            guard resources.placePanel(panel, token: token, show: { surface.presentPanel() }) else { return }
            ownerStage = "awaiting-window-hit"
            let deadline = ContinuousClock.now.advanced(by: ownerWait)
            repeat {
                guard isCurrent(token), allowed() else { return }
                if let point = position, resources.confirmPanel(token: token, setGlyph: { surface.setGlyph(at: point) }) {
                    keepPanel = true; ownerStage = "glyph-set"; anchor = point
                    // Recompute from the observed point, not the last posted
                    // receiver packet or any exact coordinate readback.
                    let destination = avoidSystemEdges ? surface.parkingPoint(for: point) : point
                    if destination != point, surface.ownsPoint(destination), isCurrent(token), allowed() {
                        if resources.parkBehindPanel(at: destination, token: token) {
                            let observed = position
                            recordOffset(from: destination, to: observed)
                            anchor = observed ?? destination
                            ownerStage = "parked"
                        } else { ownerStage = "parking-rejected" }
                    }
                    return
                }
                guard ContinuousClock.now < deadline else { ownerStage = "window-not-owned"; return }
                try await Task.sleep(for: .milliseconds(8))
            } while true
        } catch {
            if isCurrent(token) { ownerStage = "panel-unavailable" }
        }
    }
    private func isCurrent(_ token: UInt64) -> Bool {
        !Task.isCancelled && resourceToken == token && resources.isActive(token: token)
    }
    @discardableResult func release(restoring point: CGPoint? = nil, requirePosition: Bool = false) -> [String] {
        appearanceTask?.cancel(); appearanceTask = nil
        let restore = isCaptured ? (point ?? position) : nil
        anchor = nil; resourceToken = nil
        let errors = resources.release(warp: restore, requirePosition: requirePosition)
        // If the native withdraw failed, leave a tracked recovery obligation for
        // the watchdog, but still make our AppKit window ignore the pointer.
        surface.closePanel()
        if !errors.isEmpty { lastFailure = errors.joined(separator: "；") }
        return errors
    }
}
