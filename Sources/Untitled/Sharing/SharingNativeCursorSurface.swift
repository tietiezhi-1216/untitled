import AppKit
@preconcurrency import ApplicationServices
import Darwin
import os

/// Undocumented cursor/window APIs, resolved at runtime. Only our own
/// WindowServer connection and one temporary panel are ever modified. The tap
/// and input posting still require the normal macOS user permissions.
private struct SharingWindowServer: Sendable {
    typealias Connection = @convention(c) () -> Int32
    typealias ConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    typealias Tags = @convention(c) (Int32, UInt32, UnsafePointer<UInt32>, Int) -> Int32
    typealias MouseEvents = @convention(c) (Int32, UInt32, Bool) -> Int32
    typealias Order = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32
    typealias Seed = @convention(c) () -> Int32
    typealias Visibility = @convention(c) () -> UInt32
    typealias SystemCursor = @convention(c) (Int32, Int, UnsafeMutablePointer<Int32>) -> Void
    typealias Region = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32
    typealias RegionLock = @convention(c) (Int32, UnsafeRawPointer?) -> Int32
    typealias Transaction = @convention(c) (Int32) -> UnsafeRawPointer?
    typealias Update = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    typealias Commit = @convention(c) (UnsafeRawPointer, UInt32) -> Void

    // Keep the framework loaded while the typed function pointers can be used
    // by the independent watchdog. No new linkage requirement on older systems.
    private static func load() -> Self? {
        let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        let process = UnsafeMutableRawPointer(bitPattern: -2) // Darwin RTLD_DEFAULT
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let address = dlsym(process, name) ?? framework.flatMap({ dlsym($0, name) }) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
        guard let connection = symbol("_CGSDefaultConnection", Connection.self) ?? symbol("SLSMainConnectionID", Connection.self),
              let property = symbol("CGSSetConnectionProperty", ConnectionProperty.self),
              let tags = symbol("CGSSetWindowTags", Tags.self),
              let events = symbol("CGSSetMouseEventEnableFlags", MouseEvents.self),
              let order = symbol("CGSOrderWindow", Order.self),
              let cursorSeed = symbol("CGSCurrentCursorSeed", Seed.self),
              let standardCursor = symbol("CGSSetSystemDefinedCursorWithSeed", SystemCursor.self) else { return nil }
        return Self(connection: connection, property: property, tags: tags, events: events, order: order,
                    cursorSeed: cursorSeed, standardCursor: standardCursor,
                    visibility: symbol("CGCursorIsVisible", Visibility.self),
                    makeRegion: symbol("CGSNewRegionWithRect", Region.self), regionLock: symbol("SLSSetCursorRegionLock", RegionLock.self),
                    transaction: symbol("SLSTransactionCreate", Transaction.self),
                    update: symbol("SLSTransactionUpdateRegion", Update.self), commit: symbol("SLSTransactionCommit", Commit.self))
    }
    static let shared = load()
    let connection: Connection
    let property: ConnectionProperty
    let tags: Tags
    let events: MouseEvents
    let order: Order
    let cursorSeed: Seed
    let standardCursor: SystemCursor
    let visibility: Visibility?
    let makeRegion: Region?
    let regionLock: RegionLock?
    let transaction: Transaction?
    let update: Update?
    let commit: Commit?

    func enableBackground() -> CGError {
        let id = connection()
        guard id != 0 else { return .failure }
        return CGError(rawValue: property(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)) ?? .failure
    }
    func allowCursorUpdates(in window: UInt32, connection id: Int32) -> Bool {
        // kCGSSetsCursorInBackgroundTagBit (5), in a 64-bit tag buffer.
        let bits: [UInt32] = [1 << 5, 0]
        return bits.withUnsafeBufferPointer { tags(id, window, $0.baseAddress!, 64) == 0 }
    }
    private func withRegion(_ bounds: CGRect, apply: (UnsafeRawPointer) -> Bool) -> Bool {
        guard let makeRegion else { return false }
        var bounds = bounds, raw: UnsafeRawPointer?
        let result = makeRegion(&bounds, &raw)
        guard let raw else { return false }
        defer { Unmanaged<CFTypeRef>.fromOpaque(raw).release() }
        return result == 0 && apply(raw)
    }
    func takeRegion() -> Bool {
        guard let regionLock else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success, count > 0 else { return false }
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        let id = connection()
        return id != 0 && withRegion(bounds) { regionLock(id, $0) == 0 }
    }
    func releaseRegion() -> CGError {
        guard let regionLock else { return .failure }
        let id = connection()
        guard id != 0 else { return .failure }
        return CGError(rawValue: regionLock(id, nil)) ?? .failure
    }
    func refreshDisplay() -> Bool {
        guard let transaction, let update, let commit, let point = CGEvent(source: nil)?.location,
              point.x.isFinite, point.y.isFinite else { return false }
        let id = connection()
        guard id != 0 else { return false }
        // A successful Hide can update the logical state before the hardware
        // cursor is redrawn. Invalidate one point, without posting input.
        return withRegion(CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)) { region in
            guard let display = transaction(id) else { return false }
            defer { Unmanaged<CFTypeRef>.fromOpaque(display).release() }
            update(display, region); commit(display, 1)
            return true
        }
    }
}

extension SharingCursorCalls {
    static var background: Self {
        Self(warp: SharingPointerWarp.move,
             enableBackground: { SharingWindowServer.shared?.enableBackground() ?? .failure },
             takeCursorRegion: { SharingWindowServer.shared?.takeRegion() ?? false },
             releaseCursorRegion: { SharingWindowServer.shared?.releaseRegion() ?? .failure },
             refreshDisplay: { SharingWindowServer.shared?.refreshDisplay() ?? false },
             cursorVisible: { SharingWindowServer.shared?.visibility.map { $0() != 0 } })
    }
}

/// The CGEventSource suppression interval does not apply to the standalone Warp API.
/// Request the short interval on the legacy Quartz connection, not a system preference.
/// New macOS versions may ignore this deprecated function; no permission is obtained here.
nonisolated enum SharingPointerWarp {
    private typealias Suppression = @convention(c) (Double) -> Int32
    private static let setSuppression: Suppression? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSetLocalEventsSuppressionInterval")
        .map { unsafeBitCast($0, to: Suppression.self) }

    static func move(_ point: CGPoint) -> CGError {
        _ = setSuppression?(0.0001)
        return CGWarpMouseCursorPosition(point)
    }
}

struct SharingCursorParkingGeometry {
    struct Corners: OptionSet, Sendable {
        let rawValue: UInt8
        static let topLeft = Self(rawValue: 1), topRight = Self(rawValue: 2)
        static let bottomLeft = Self(rawValue: 4), bottomRight = Self(rawValue: 8)
    }

    /// Inputs are Quartz logical coordinates. Respect just the source display's
    /// reserved strips and configured hot corners, not every screen edge.
    static func destination(from point: CGPoint, screen: CGRect, workArea: CGRect,
                            autoHideDock: SharingEdge? = nil, corners: Corners = []) -> CGPoint {
        let work = screen.intersection(workArea)
        guard screen.contains(point), !work.isNull, work.width > 96, work.height > 96 else { return point }
        let l = point.x - screen.minX, r = screen.maxX - point.x
        let t = point.y - screen.minY, b = screen.maxY - point.y
        var target = point
        if work.minX > screen.minX, point.x < work.minX { target.x = work.minX + 8 }
        if work.maxX < screen.maxX, point.x >= work.maxX { target.x = work.maxX - 8 }
        if work.minY > screen.minY, point.y < work.minY { target.y = work.minY + 8 }
        if work.maxY < screen.maxY, point.y >= work.maxY { target.y = work.maxY - 8 }
        // Auto-hide does not reserve workArea. Leave its activation strip only
        // when the pointer is actually at the configured outside edge.
        if autoHideDock == .left, l < 3 { target.x = max(target.x, screen.minX + 48) }
        if autoHideDock == .right, r < 3 { target.x = min(target.x, screen.maxX - 48) }
        if autoHideDock == .bottom, b < 3 { target.y = min(target.y, screen.maxY - 48) }
        for (corner, dx, dy, left, top) in [(Corners.topLeft, l, t, true, true), (.topRight, r, t, false, true),
                                             (.bottomLeft, l, b, true, false), (.bottomRight, r, b, false, false)] {
            if corners.contains(corner), dx < 12, dy < 12 {
                target.x = left ? max(target.x, screen.minX + 24) : min(target.x, screen.maxX - 24)
                target.y = top ? max(target.y, screen.minY + 24) : min(target.y, screen.maxY - 24)
            }
        }
        return target
    }
}

@MainActor final class SharingNativeCursorSurface: SharingCursorSurface {
    private struct NativePanel {
        let window: SharingCursorPanel
        let view: SharingCursorPanelView
        let glyph: NSCursor
        let seed: OSAllocatedUnfairLock<Int32?>
        let closed: OSAllocatedUnfairLock<Bool>
        let origin: CGPoint
    }
    private var panel: NativePanel?
    var position: CGPoint? { CGEvent(source: nil)?.location }
    var isPresented: Bool { panel?.window.isVisible == true }

    func parkingPoint(for origin: CGPoint) -> CGPoint {
        let mainY = CGDisplayBounds(CGMainDisplayID()).maxY
        func quartz(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: mainY - rect.maxY, width: rect.width, height: rect.height)
        }
        guard let screen = NSScreen.screens.first(where: { quartz($0.frame).contains(origin) }) else { return origin }
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let autoHideEdge = dock?.bool(forKey: "autohide") == true
            ? SharingEdge(rawValue: dock?.string(forKey: "orientation") ?? "bottom") : nil
        let corners: [(String, SharingCursorParkingGeometry.Corners)] = [
            ("tl", .topLeft), ("tr", .topRight), ("bl", .bottomLeft), ("br", .bottomRight)]
        let active = corners.reduce(into: SharingCursorParkingGeometry.Corners()) { active, entry in
            if (dock?.integer(forKey: "wvous-\(entry.0)-corner") ?? 0) > 1 { active.insert(entry.1) }
        }
        return SharingCursorParkingGeometry.destination(from: origin, screen: quartz(screen.frame), workArea: quartz(screen.visibleFrame),
                                                        autoHideDock: autoHideEdge, corners: active)
    }

    func makePanel(at point: CGPoint, covering target: CGPoint, refreshGlyph: @escaping () -> Void) throws -> SharingCursorPanelLease {
        guard panel == nil, let server = SharingWindowServer.shared else { throw SharingCursorInterruption.backgroundUnavailable }
        let id = server.connection()
        guard id != 0, let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32),
              let bytes = image.bitmapData else { throw SharingCursorInterruption.panelUnavailable }
        memset(bytes, 0, 16 * image.bytesPerRow)
        let transparent = NSImage(size: NSSize(width: 16, height: 16)); transparent.addRepresentation(image)
        let cursor = NSCursor(image: transparent, hotSpot: .zero)
        let source = Self.cocoaPoint(point), destination = Self.cocoaPoint(target)
        let frame = CGRect(x: min(source.x, destination.x) - 8, y: min(source.y, destination.y) - 8,
                           width: abs(source.x - destination.x) + 16, height: abs(source.y - destination.y) + 16)
        let window = SharingCursorPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.hasShadow = false
        window.backgroundColor = NSColor(white: 0, alpha: 0.01)
        window.ignoresMouseEvents = false; window.animationBehavior = .none
        window.isFloatingPanel = true; window.level = .popUpMenu; window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false; window.canHide = false; window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        let view = SharingCursorPanelView(frame: CGRect(origin: .zero, size: window.frame.size))
        view.refreshGlyph = refreshGlyph
        window.contentView = view
        guard let number = UInt32(exactly: window.windowNumber), number > 0,
              server.allowCursorUpdates(in: number, connection: id) else {
            window.close()
            throw SharingCursorInterruption.panelUnavailable
        }
        let seed = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        let closed = OSAllocatedUnfairLock(initialState: false)
        panel = NativePanel(window: window, view: view, glyph: cursor, seed: seed, closed: closed, origin: point)
        return SharingCursorPanelLease(retireGlyph: {
            let owned = seed.withLock { seed in defer { seed = nil }; return seed }
            guard let owned, server.cursorSeed() == owned else { return }
            // Only remove our own installed glyph. Do not overwrite another
            // window's I-beam/resize cursor after a return warp or app switch.
            var replacement: Int32 = 0
            server.standardCursor(id, 0, &replacement)
        }, withdraw: {
            if closed.withLock({ $0 }) { return true }
            let disabled = server.events(id, number, false) == 0
            let removed = server.order(id, number, 0, 0) == 0
            return disabled || removed
        })
    }
    func presentPanel() { panel?.window.orderFrontRegardless() }
    func ownsPoint(_ point: CGPoint) -> Bool {
        guard let panel, panel.window.isVisible else { return false }
        return Self.hit(at: point) == panel.window.windowNumber
    }
    func setGlyph(at point: CGPoint) -> Bool {
        guard let panel, let server = SharingWindowServer.shared, ownsPoint(point) else { return false }
        // Called under the resource operation lock, serialized with retirement.
        panel.glyph.set()
        let seed = server.cursorSeed()
        panel.seed.withLock { $0 = seed }
        if panel.view.cursor == nil {
            // Register only after tracking the installed glyph for cleanup.
            panel.view.cursor = panel.glyph
            panel.window.invalidateCursorRects(for: panel.view)
        }
        return true
    }
    func closePanel() {
        guard let panel else { return }
        self.panel = nil
        panel.view.refreshGlyph = nil; panel.view.cursor = nil; panel.view.discardCursorRects()
        panel.window.ignoresMouseEvents = true
        let number = panel.window.windowNumber
        panel.window.orderOut(nil); panel.window.close()
        if !panel.window.isVisible, Self.hit(at: panel.origin) != number { panel.closed.withLock { $0 = true } }
    }
    private static func cocoaPoint(_ point: CGPoint) -> CGPoint {
        let main = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: point.x, y: main.maxY - point.y)
    }
    private static func hit(at point: CGPoint) -> Int {
        // AppKit truncates the hit-test coordinates. Choose the pixel in
        // Quartz space first, including negative coordinates on other displays.
        NSWindow.windowNumber(at: cocoaPoint(CGPoint(x: floor(point.x), y: floor(point.y))), belowWindowWithWindowNumber: 0)
    }
}

private final class SharingCursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SharingCursorPanelView: NSView {
    var refreshGlyph: (() -> Void)?
    var cursor: NSCursor?
    private var cursorTracking: NSTrackingArea?
    override func resetCursorRects() {
        super.resetCursorRects()
        if let cursor { addCursorRect(bounds, cursor: cursor) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        cursorTracking = tracking; addTrackingArea(tracking)
    }
    override func cursorUpdate(with event: NSEvent) { refreshGlyph?() }
    override func mouseEntered(with event: NSEvent) { refreshGlyph?() }
    override func mouseMoved(with event: NSEvent) { refreshGlyph?() }
}
