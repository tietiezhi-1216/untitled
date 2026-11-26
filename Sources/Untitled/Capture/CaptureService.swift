import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum CaptureSelectionPostAction { case copy, pin, save, quickSave, ocr, edit }

enum CaptureSelectionLiveAction: CaseIterable, Hashable {
    case scroll, record

    var action: ActionKind { self == .scroll ? .captureScrolling : .captureRecording }
    var isSupported: Bool {
        if #available(macOS 15, *) { return true }
        return self == .scroll
    }
}

@MainActor struct CaptureSelection {
    let display: SCDisplay
    let filter: SCContentFilter
    let rect: CGRect
    let scale: CGFloat
    let image: CGImage
    var windowID: CGWindowID?
    var presentationFrameOverride: CGRect? = nil
    var isComposite = false
    var initialTool: CaptureTool? = nil
    var postAction: CaptureSelectionPostAction? = nil
    var presentation: CaptureSelectionPresentation? = nil
    var outputHandled = false
    var editableExport: CaptureSelectionExport? = nil
    var initialAction: CaptureShortcutAction? = nil
    var liveAction: CaptureSelectionLiveAction? = nil
    func dismissPresentation() { presentation?.dismiss() }
    func completePresentation() { presentation?.complete() }
    var presentationFrame: CGRect? {
        if let presentationFrameOverride { return presentationFrameOverride }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }) else { return nil }
        return CaptureFloatingLayout.screenRect(rect, on: screen.frame)
    }
}

struct CaptureRegionMemory: Codable, Equatable {
    let displayID: UInt32
    let rect: CGRect
    func clamped(to size: CGSize) throws -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else {
            throw PluginError.invalid("上次截图区域无效，请重新框选。")
        }
        let value = rect.intersection(CGRect(origin: .zero, size: size))
        guard value.width >= 8, value.height >= 8 else { throw PluginError.invalid("显示器布局已变化，请重新框选截图区域。") }
        return value
    }
}

/// Classify host windows for the selection snapshot. A live recording instead
/// excludes its own pre-registered control windows by ID.
@MainActor enum CaptureWindowPolicy {
    static let controlPrefix = "capture.control."
    // An overlay joins the current stage instead of causing Stage Manager to shelve
    // the source app's windows. These flags also allow overlays above full-screen apps.
    static let floatingBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle,
    ]
    static func contentWindowIDs(in windows: [NSWindow]) -> Set<CGWindowID> {
        Set(windows.compactMap { window in
            guard window.isVisible, !(window.identifier?.rawValue.hasPrefix(controlPrefix) ?? false) else { return nil }
            return captureID(window.windowNumber)
        })
    }
    static func captureID(_ number: Int) -> CGWindowID? {
        guard number > 0, let id = CGWindowID(exactly: number) else { return nil }
        return id
    }
    static func markControl(_ window: NSWindow, name: String) {
        window.identifier = NSUserInterfaceItemIdentifier(controlPrefix + name)
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
    }
}

@MainActor final class CaptureService {
    enum Mode { case region, window, screen }
    private var selector: CaptureSelector?
    private weak var pendingPresentation: CaptureSelectionPresentation?
    private var generation = 0
    private var requestID: UUID?
    var hasActiveCapture:Bool { requestID != nil || pendingPresentation?.isActive == true }
    private let loadContent: @MainActor () async throws -> SCShareableContent
    init(loadContent: @escaping @MainActor () async throws -> SCShareableContent = {
        try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
    }) { self.loadContent=loadContent }
    private func beginRequest() -> UUID? {
        guard !hasActiveCapture else { return nil }
        let id=UUID();requestID=id;return id
    }
    private func endRequest(_ id:UUID) { if requestID == id { requestID=nil } }

    func repeatRegion(_ memory: CaptureRegionMemory, permissions: PluginPermissionClient) async throws -> CaptureSelection? {
        guard let request=beginRequest() else { return nil };defer { endRequest(request) }
        let current = generation
        try permissions.require([.screenRecording])
        let content = try await loadContent()
        guard generation == current else { return nil };try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == memory.displayID }) else {
            throw PluginError.invalid("上次截图所在的显示器已断开，请重新框选。")
        }
        let rect = try memory.clamped(to: display.frame.size)
        let filter = contentFilter(display: display, content: content)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.sourceRect = rect; config.width = Int(rect.width * scale); config.height = Int(rect.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard generation == current else { return nil }
        return CaptureSelection(display: display, filter: filter, rect: rect, scale: scale, image: image)
    }

    func choose(_ mode: Mode, permissions: PluginPermissionClient, allowComplexSelection: Bool = true,
                automaticallyCopiesSelection: Bool = false, liveActions: Set<CaptureSelectionLiveAction> = [],
                outputHandler: CaptureSelectionOutputHandler? = nil) async throws -> CaptureSelection? {
        guard let request=beginRequest() else { return nil };defer { endRequest(request) }
        pendingPresentation?.dismiss()
        let currentGeneration = generation
        try permissions.require([.screenRecording])
        let content = try await loadContent()
        guard generation == currentGeneration else { return nil };try Task.checkCancellation()
        var screens: [(NSScreen, SCDisplay, SCContentFilter, CGImage)] = []
        var capturedPixels = 0
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            if mode == .screen, !screen.frame.contains(mouse) { continue }
            let filter = contentFilter(display: display, content: content)
            let config = SCStreamConfiguration()
            let scale = max(1, CGFloat(filter.pointPixelScale))
            config.width = max(1, Int(filter.contentRect.width * scale))
            config.height = max(1, Int(filter.contentRect.height * scale))
            config.showsCursor = false
            guard config.width > 0, config.height <= (CaptureImage.maximumPixels-capturedPixels)/config.width else {
                throw PluginError.invalid("当前显示器组合超过8000万像素，请使用单屏截图或降低显示分辨率。")
            }
            capturedPixels += config.width*config.height
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard generation == currentGeneration else { return nil };try Task.checkCancellation()
            screens.append((screen, display, filter, image))
        }
        guard !screens.isEmpty else { throw PluginError.invalid("没有可用的显示器。") }
        guard generation == currentGeneration else { return nil }
        if mode == .screen {
            let (screen, display, filter, image) = screens[0]
            return CaptureSelection(display: display, filter: filter,
                                    rect: CGRect(origin: .zero, size: screen.frame.size),
                                    scale: CGFloat(image.width) / screen.frame.width, image: image)
        }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let windows = content.windows.sorted { (ranks[$0.windowID] ?? .max) < (ranks[$1.windowID] ?? .max) }
        let elementDetectionAllowed = CaptureElementHitTesting.isAllowed(using: permissions)
        let selected: CaptureSelection? = await withCheckedContinuation { continuation in
            let selector = CaptureSelector()
            self.selector = selector
            selector.show(screens, windows: windows, allowsShapes: allowComplexSelection, elementDetectionAllowed: elementDetectionAllowed,
                          automaticallyCopiesSelection: automaticallyCopiesSelection, liveActions: liveActions,
                          outputHandler: outputHandler) { [weak self] selection in
                self?.selector = nil
                self?.pendingPresentation = selection?.presentation
                continuation.resume(returning: selection)
            }
            // The selector owns the single composite; do not retain all source
            // bitmaps in this suspended async frame through the editing session.
            screens.removeAll()
        }
        guard let selected else { return nil }
        if selected.liveAction == nil, !selected.outputHandled, selected.editableExport == nil, mode == .window, let id = selected.windowID, let window = content.windows.first(where: { $0.windowID == id }) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(window.frame.width * selected.scale))
            configuration.height = max(1, Int(window.frame.height * selected.scale))
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard generation == currentGeneration else { selected.dismissPresentation();return nil }
                try Task.checkCancellation()
                return CaptureSelection(display: selected.display, filter: selected.filter, rect: selected.rect,
                                        scale: selected.scale, image: image, windowID: id, initialTool:selected.initialTool,postAction:selected.postAction,
                                        presentation:selected.presentation)
            } catch {
                selected.dismissPresentation()
                throw error
            }
        }
        return selected
    }

    func capture(filter: SCContentFilter, rect: CGRect, scale: CGFloat, permissions: PluginPermissionClient) async throws -> CGImage {
        try permissions.require([.screenRecording])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func contentFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID == pid }
        let contentIDs = CaptureWindowPolicy.contentWindowIDs(in: NSApp.windows)
        let visibleContent = content.windows.filter { $0.owningApplication?.processID == pid && contentIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: visibleContent)
    }

    func pinCurrentSelection() {
        selector?.pinCurrentSelection()
    }

    func cancel() {
        generation += 1;requestID=nil
        selector?.finish(nil)
        pendingPresentation?.dismiss(); pendingPresentation = nil
    }

    /// Global mouse gestures use Quartz desktop coordinates, including negative origins.
    func captureGlobalRegion(_ globalRect: CGRect, permissions: PluginPermissionClient) async throws -> CaptureSelection {
        try permissions.require([.screenRecording])
        let content=try await loadContent()
        try Task.checkCancellation()
        let displays=content.displays.filter { $0.frame.intersects(globalRect) }
        guard let first=displays.first,globalRect.width>=8,globalRect.height>=8 else { throw PluginError.invalid("截图范围不在可用显示器内。") }
        let filters=displays.map { contentFilter(display:$0,content:content) }
        let scale=filters.map { max(1,CGFloat($0.pointPixelScale)) }.max() ?? 1
        let context=try CaptureImage.context(width:Int((globalRect.width*scale).rounded()),height:Int((globalRect.height*scale).rounded()))
        for (display,filter) in zip(displays,filters) {
            let visible=globalRect.intersection(display.frame)
            let config=SCStreamConfiguration();config.sourceRect=visible.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY)
            config.width=max(1,Int((visible.width*scale).rounded()));config.height=max(1,Int((visible.height*scale).rounded()));config.showsCursor=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            context.draw(image,in:CGRect(x:(visible.minX-globalRect.minX)*scale,y:(globalRect.maxY-visible.maxY)*scale,width:visible.width*scale,height:visible.height*scale))
        }
        guard let image=context.makeImage() else { throw PluginError.invalid("无法生成截图。") }
        let cocoaTop=NSScreen.screens.first?.frame.maxY ?? 0
        let presentation=CGRect(x:globalRect.minX,y:cocoaTop-globalRect.maxY,width:globalRect.width,height:globalRect.height)
        return CaptureSelection(display:first,filter:filters[0],rect:globalRect.offsetBy(dx:-first.frame.minX,dy:-first.frame.minY),scale:scale,image:image,presentationFrameOverride:presentation,isComposite:displays.count>1)
    }

    func recordingSelection(_ selection: CaptureSelection, excluding controls: [NSWindow]) async throws -> CaptureSelection {
        let unavailable = PluginError.invalid("录屏控件尚未准备好，请重试。")
        let ids = Set(controls.compactMap { CaptureWindowPolicy.captureID($0.windowNumber) })
        guard !ids.isEmpty, ids.count == controls.count else { throw unavailable }
        for attempt in 0..<8 {
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let filter = Self.recordingFilter(display: selection.display, in: content, excluding: ids) {
                return CaptureSelection(display: selection.display, filter: filter, rect: selection.rect, scale: selection.scale,
                                        image: selection.image, presentationFrameOverride: selection.presentationFrame)
            }
            if attempt < 7 { try await Task.sleep(for: .milliseconds(50)) }
        }
        // Do not start an unfiltered stream if WindowServer hasn't registered all the chrome.
        throw unavailable
    }

    static func recordingFilter(display: SCDisplay, in content: SCShareableContent,
                                excluding ids: Set<CGWindowID>) -> SCContentFilter? {
        let owner = ProcessInfo.processInfo.processIdentifier
        let controls = content.windows.filter { ids.contains($0.windowID) && $0.owningApplication?.processID == owner }
        guard !ids.isEmpty, Set(controls.map(\.windowID)) == ids else { return nil }
        // New plugin windows, camera previews and the drawing surface remain
        // ordinary display content. No application allowlist is frozen at Start.
        return SCContentFilter(display: display, excludingWindows: controls)
    }
}

/// A bounded supply of requested screen points. Only an accepted stitch can
/// release the distance already requested before that frame was captured.
struct ScrollCaptureMotion {
    static let tick = Duration.milliseconds(25)
    static let idleTick = Duration.milliseconds(100)
    private static let ticksPerSecond = 40.0
    private static let rampTicks = 8

    let limit: Int
    let speed: Double
    private(set) var sent = 0
    private var confirmed = 0
    private var ticks = 0
    private var remainder = 0.0

    init(extent: CGFloat) {
        let length = extent.isFinite ? min(20_000, max(8, Double(extent))) : 8
        limit = Int(length * 0.48)
        speed = min(320, length * 0.5)
    }

    var hasPendingMovement: Bool { sent > confirmed }
    var isLimited: Bool { sent - confirmed >= limit }

    mutating func nextStep() -> Int {
        guard !isLimited else { resetRamp(); return 0 }
        ticks = min(Self.rampTicks, ticks + 1)
        let progress = Double(ticks) / Double(Self.rampTicks)
        // Smoothstep gives a gentle start without accumulating missed ticks.
        remainder += speed / Self.ticksPerSecond * progress * progress * (3 - 2 * progress)
        let whole = Int(remainder)
        remainder -= Double(whole)
        return min(whole, limit - (sent - confirmed))
    }

    mutating func record(_ step: Int) { sent += step }
    mutating func acceptFrame(capturedThrough mark: Int) { confirmed = max(confirmed, min(sent, mark)) }
    mutating func resetRamp() { ticks = 0; remainder = 0 }
}

@MainActor struct ScrollCaptureWheelDriver {
    let selection: CGRect
    let pointer: () throws -> CGPoint
    let authorize: () throws -> Void
    let post: (StitchAxis, Int, CGPoint) -> Bool
}

@MainActor final class ScrollCaptureSession: ObservableObject {
    typealias Output = @MainActor (CGImage, CaptureSelectionPostAction, URL?) async throws -> Void

    @Published private(set) var axis: StitchAxis
    @Published private(set) var count = 1
    @Published private(set) var status: String?
    @Published private(set) var size: CGSize
    var pixelDimensions: String { "\(Int(size.width)) × \(Int(size.height)) px" }
    @Published private(set) var automaticScroll = false
    @Published private(set) var isPaused = false
    @Published private(set) var isSaving = false
    @Published private(set) var completedSegments = 0
    @Published var trimOnReverse: Bool {
        didSet { defaults.set(trimOnReverse, forKey: "capture.scrollTrimOnReverse") }
    }
    @Published private(set) var preview: NSImage
    @Published private(set) var viewport: CGRect
    @Published var cropStart = 0.0
    @Published var cropEnd = 1.0

    private var collector: SegmentedScrollCapture
    private let sampleFrame: @MainActor () async throws -> CGImage
    private let wheel: ScrollCaptureWheelDriver?
    private var motion: ScrollCaptureMotion
    private var nextScrollPermissionCheck: ContinuousClock.Instant?
    private var limitedFramesWithoutMatch = 0
    private let output: Output
    private let defaults: UserDefaults
    private let pixelLimit: Int
    private let recoveryRoot: URL
    private let chooseURL: (@MainActor (NSSavePanel) async -> URL?)?
    private var sampleTask: Task<Void, Never>?
    private var autoScrollTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var overlay: CaptureScrollOverlay?
    private var sampling = false
    private(set) var closed = false
    private var closing = false
    private var sourceInvalidated = false
    private var chooser: NSSavePanel?
    var finished: (() -> Void)?

    init(image: CGImage, axis: StitchAxis, defaults: UserDefaults = .standard,
         pixelLimit: Int = CaptureImage.maximumPixels, recoveryRoot: URL = SegmentedScrollCapture.recoveryDirectory,
         sampleFrame: @escaping @MainActor () async throws -> CGImage,
         wheel: ScrollCaptureWheelDriver? = nil,
         chooseURL: (@MainActor (NSSavePanel) async -> URL?)? = nil,
         output: @escaping Output) {
        self.axis = axis
        self.sampleFrame = sampleFrame; self.wheel = wheel; self.output = output; self.chooseURL = chooseURL
        motion = Self.motion(for: axis, wheel: wheel)
        self.defaults = defaults; self.pixelLimit = pixelLimit; self.recoveryRoot = recoveryRoot
        trimOnReverse = defaults.bool(forKey: "capture.scrollTrimOnReverse")
        let collector = SegmentedScrollCapture(image: image, axis: axis, pixelLimit: pixelLimit,
            directory: recoveryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
        self.collector = collector
        size = CGSize(width: image.width, height: image.height)
        preview = NSImage(cgImage: CaptureImage.thumbnail(image, maximum: 640), size: .zero)
        viewport = collector.viewport
    }

    func start(selection: CGRect, screen: NSScreen, presentation: CaptureSelectionPresentation?) {
        guard sampleTask == nil, !closed else { return }
        let handoff = presentation?.takePanelForLiveCapture(at: CGPoint(x: selection.midX, y: selection.midY))
        let overlay = CaptureScrollOverlay(session: self, selection: selection, screenFrame: screen.frame,
            visible: screen.visibleFrame, previousToolbar: handoff?.toolbar, reusing: handoff?.panel) { [weak self] in
                self?.invalidateSource()
            }
        self.overlay = overlay
        overlay.show()
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.automaticScroll == true ? 440 : 650
                do { try await Task.sleep(for: .milliseconds(interval)) } catch { break }
                guard let self, !Task.isCancelled else { break }
                await sample()
            }
        }
    }

    func sample() async { await sample(finishing: false) }

    private func sample(finishing: Bool) async {
        guard finishing || (!isPaused && !isSaving),
              !sampling, !closed, !closing, !sourceInvalidated else { return }
        sampling = true
        defer { sampling = false }
        let capturedThrough = motion.sent
        do {
            let image = try await sampleFrame()
            let trim = trimOnReverse
            let result = try await Task.detached { [collector] in
                var next = collector
                let outcome = try next.appendFrame(image, trimOnReverse: trim)
                let thumbnail = outcome == .appended ? CaptureImage.thumbnail(next.image, maximum: 640) : nil
                return (next, thumbnail, outcome)
            }.value
            guard !Task.isCancelled, !closed else { return }
            let rolled = result.0.segments.count > collector.segments.count
            collector = result.0
            if let thumbnail = result.1 {
                motion.acceptFrame(capturedThrough: capturedThrough)
                limitedFramesWithoutMatch = 0
                count += 1; completedSegments = collector.segments.count
                if rolled { cropStart = 0; cropEnd = 1 }
                updatePreview(thumbnail)
                status = rolled ? "前一段已暂存，可继续滚动。" : nil
            } else {
                didNotMatch(capturedThrough: capturedThrough, unchanged: result.2 == .unchanged)
            }
        } catch is CancellationError {
            stopAutomaticScroll()
        } catch {
            stopAutomaticScroll(); isPaused = true
            status = error.localizedDescription
        }
    }

    private func updatePreview(_ thumbnail: CGImage? = nil) {
        size = CGSize(width: collector.image.width, height: collector.image.height)
        viewport = collector.viewport
        preview = NSImage(cgImage: thumbnail ?? CaptureImage.thumbnail(collector.image, maximum: 640), size: .zero)
    }

    func togglePause() {
        guard !isSaving, !closed, !sourceInvalidated else { return }
        isPaused.toggle()
        if isPaused { stopAutomaticScroll() }
    }

    func toggleAutomaticScroll() {
        guard !isSaving, !isPaused, !closed, !closing, !sourceInvalidated, let wheel else { return }
        if automaticScroll { stopAutomaticScroll(); return }
        guard !motion.isLimited else {
            status = "请先手动滚动或回滚，等画面拼接成功再开启自动滚动。"
            return
        }
        do { try wheel.authorize() }
        catch { status = "自动滚动需要辅助功能权限；仍可手动滚动。"; return }
        motion.resetRamp()
        nextScrollPermissionCheck = .now.advanced(by: .milliseconds(500))
        limitedFramesWithoutMatch = 0
        automaticScroll = true
        status = "自动滚动已开启；将鼠标移入选区开始。"
        autoScrollTask = Task { [weak self] in
            var delay = ScrollCaptureMotion.tick
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                delay = self.tickAutomaticScroll(using: wheel)
            }
        }
    }

    private func tickAutomaticScroll(using wheel: ScrollCaptureWheelDriver) -> Duration {
        guard automaticScroll, !isPaused, !isSaving, !closing, !closed, !sourceInvalidated else {
            stopAutomaticScroll()
            return ScrollCaptureMotion.idleTick
        }
        do {
            let pointer = try wheel.pointer()
            guard wheel.selection.contains(pointer), overlay?.toolbar.frame.contains(pointer) != true else {
                motion.resetRamp()
                nextScrollPermissionCheck = nil
                return ScrollCaptureMotion.idleTick
            }
            guard !motion.isLimited else {
                motion.resetRamp()
                return ScrollCaptureMotion.idleTick
            }
            let now = ContinuousClock.now
            if nextScrollPermissionCheck.map({ $0 <= now }) ?? true {
                try wheel.authorize()
                nextScrollPermissionCheck = now.advanced(by: .milliseconds(500))
            }
            let step = motion.nextStep()
            if step > 0 {
                guard wheel.post(axis, step, pointer) else {
                    stopAutomaticScroll()
                    status = "未能发送滚动；可继续手动滚动。"
                    return ScrollCaptureMotion.idleTick
                }
                motion.record(step)
            }
            return ScrollCaptureMotion.tick
        } catch is CancellationError {
            stopAutomaticScroll()
        } catch {
            stopAutomaticScroll()
            status = "自动滚动权限不可用；仍可手动滚动。"
        }
        return ScrollCaptureMotion.idleTick
    }

    private func stopAutomaticScroll() {
        autoScrollTask?.cancel(); autoScrollTask = nil
        if automaticScroll { automaticScroll = false }
        nextScrollPermissionCheck = nil
        motion.resetRamp()
    }

    private static let alignmentHint = "画面未对齐，请慢慢回滚到上次位置。"

    private func didNotMatch(capturedThrough mark: Int, unchanged: Bool) {
        if automaticScroll {
            guard motion.isLimited, mark == motion.sent else { return }
            limitedFramesWithoutMatch += 1
            if limitedFramesWithoutMatch >= 2 {
                stopAutomaticScroll()
                status = "页面可能已到底或暂时无法拼接，已停下。可手动滚动或回滚一点。"
            }
        } else if unchanged {
            if status == Self.alignmentHint { status = nil }
        } else if !motion.isLimited, status != Self.alignmentHint {
            status = Self.alignmentHint
        }
    }

    private static func motion(for axis: StitchAxis, wheel: ScrollCaptureWheelDriver?) -> ScrollCaptureMotion {
        let size = wheel?.selection.size ?? .zero
        return ScrollCaptureMotion(extent: axis == .vertical ? size.height : size.width)
    }

    private func settle() async {
        isPaused = true; stopAutomaticScroll()
        // Let the already captured frame commit before exporting or checkpointing.
        while sampling { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func invalidateSource() {
        guard !closed else { return }
        sourceInvalidated = true
        isPaused = true; stopAutomaticScroll()
        status = "显示器布局已变化，已停止采集。可保存现有长截图。"
    }

    func chooseDirection(_ next: StitchAxis) {
        guard next != axis else { return }
        restart(axis: next)
    }

    func restart() { restart(axis: axis) }

    private func restart(axis next: StitchAxis) {
        guard !isSaving, !closed, !closing, !sourceInvalidated else { return }
        runOutput { [self] in
            // A direction change starts a fresh stitcher at the same range.
            // Preserve anything already stitched before switching.
            if count > 1 || collector.isSegmented {
                _ = try await Task.detached { [collector] in try collector.checkpoint() }.value
            }
            guard !closing, !sourceInvalidated else { return }
            let image = try await sampleFrame()
            guard !closing, !sourceInvalidated else { return }
            collector = SegmentedScrollCapture(image: image, axis: next, pixelLimit: pixelLimit,
                directory: recoveryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
            axis = next; completedSegments = 0; count = 1
            motion = Self.motion(for: next, wheel: wheel)
            limitedFramesWithoutMatch = 0
            defaults.set(next.rawValue, forKey: "capture.scrollAxis")
            updatePreview(); cropStart = 0; cropEnd = 1
            status = nil
            isPaused = false
        }
    }

    func revealRecovery() {
        do {
            try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recoveryRoot)
        } catch { status = error.localizedDescription }
    }

    func requestClose() {
        guard !isSaving, !closed, !closing else { return }
        stopAutomaticScroll()
        Task { await preserveAndClose() }
    }

    func submit(_ action: CaptureSelectionPostAction, asSegments: Bool = false) {
        guard !isSaving, !closed, !closing else { return }
        let mayNeedLastFrame = !isPaused && motion.hasPendingMovement
        runOutput { [self] in
            // Wait for the wheel to stop, then include the final visible portion
            // when it still matches. On failure the accepted stitch is kept.
            if mayNeedLastFrame, motion.hasPendingMovement {
                await sample(finishing: true)
                guard !closed, !closing else { return }
            }
            if collector.isSegmented, action != .save {
                status = "长截图已分段，请使用保存导出全部分段。"
                return
            }
            if collector.isSegmented || asSegments {
                let picker = NSOpenPanel()
                picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.canCreateDirectories = true
                picker.prompt = "导出全部分段"
                picker.message = "选择保存位置，将创建编号 PNG 和拼接索引。"
                guard let folder = await destination(using: picker), !closing else { return }
                let start = cropStart, end = cropEnd
                let result = try await Task.detached { [collector] in
                    try collector.export(to: folder, start: start, end: end)
                }.value
                complete()
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } else {
                let image = collector.croppedImage(start: cropStart, end: cropEnd).0
                var url: URL?
                if action == .save {
                    let picker = NSSavePanel()
                    picker.allowedContentTypes = CaptureOutputPreferences.supportedFormats.compactMap { UTType(filenameExtension: $0) } + [.pdf]
                    picker.directoryURL = CaptureOutputPreferences.directory
                    picker.nameFieldStringValue = CaptureOutputPreferences.filename(width: image.width, height: image.height) +
                        "." + CaptureOutputPreferences.format
                    url = await destination(using: picker)
                    guard url != nil, !closing else { return }
                }
                try await output(image, action, url)
                complete()
            }
        }
    }

    private func runOutput(_ work: @escaping @MainActor () async throws -> Void) {
        isSaving = true
        stopAutomaticScroll()
        outputTask = Task { [weak self] in
            guard let self else { return }
            defer {
                outputTask = nil
                if !closed, !closing { isSaving = false }
            }
            await settle()
            guard !closed, !closing else { return }
            do { try await work() }
            catch { status = "操作失败，长截图仍保留：" + error.localizedDescription }
        }
    }

    private func destination(using picker: NSSavePanel) async -> URL? {
        CaptureWindowPolicy.markControl(picker, name: "scrollSave")
        picker.level = NSWindow.Level(rawValue: (overlay?.toolbar.level ?? .floating).rawValue + 1)
        chooser = picker
        defer { chooser = nil }
        let url: URL?
        if let chooseURL { url = await chooseURL(picker) }
        else {
            url = await withCheckedContinuation { continuation in
                picker.begin { response in continuation.resume(returning: response == .OK ? picker.url : nil) }
            }
        }
        if url == nil { status = "已取消保存，拼接结果仍保留。" }
        return url
    }

    /// Await this before termination or deactivation: keep all current pixels
    /// until the checkpoint succeeds, even if the normal export was cancelled.
    @discardableResult func preserveAndClose() async -> Bool {
        guard !closed else { return true }
        if closing {
            while closing && !closed { try? await Task.sleep(for: .milliseconds(20)) }
            return closed
        }
        closing = true; isSaving = true
        defer { closing = false }
        isPaused = true; stopAutomaticScroll()
        chooser?.cancel(nil)
        if let outputTask { await outputTask.value; if closed { return true } }
        await settle()
        do {
            _ = try await Task.detached { [collector] in try collector.checkpoint() }.value
            complete()
            return true
        } catch {
            isSaving = false
            status = "当前段暂存失败，可尝试保存到另一位置：" + error.localizedDescription
            return false
        }
    }

    func suspendPresentation() {
        sourceInvalidated = true
        isPaused = true; stopAutomaticScroll()
        sampleTask?.cancel(); sampleTask = nil
        overlay?.close(); overlay = nil
    }

    private func complete() {
        guard !closed else { return }
        closed = true
        suspendPresentation()
        let callback = finished
        finished = nil
        callback?()
    }
}

struct ScrollCapturePreview: View {
    @ObservedObject var session: ScrollCaptureSession
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / max(1, session.size.width), geometry.size.height / max(1, session.size.height))
            let size = CGSize(width: session.size.width * scale, height: session.size.height * scale)
            let vertical = session.axis == .vertical
            Image(nsImage: session.preview).resizable().frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.black.opacity(0.55)).frame(width: vertical ? size.width : size.width * session.cropStart, height: vertical ? size.height * session.cropStart : size.height)
                        Rectangle().fill(.black.opacity(0.55)).frame(width: vertical ? size.width : size.width * (1-session.cropEnd), height: vertical ? size.height * (1-session.cropEnd) : size.height)
                            .offset(x: vertical ? 0 : size.width * session.cropEnd, y: vertical ? size.height * session.cropEnd : 0)
                        Rectangle().strokeBorder(.green, lineWidth: 2).frame(width: session.viewport.width * scale, height: session.viewport.height * scale)
                            .offset(x: session.viewport.minX * scale, y: session.viewport.minY * scale)
                    }.allowsHitTesting(false)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
