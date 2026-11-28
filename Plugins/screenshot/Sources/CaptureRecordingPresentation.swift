import AppKit
@preconcurrency import AVFoundation
import Combine
import SwiftUI

/// Cocoa screen coordinates. Prefer the setup toolbar's exact position; avoid
/// the recording when there is space, including beside a tall selection.
struct CaptureRecordingLayout {
    let region: CGRect
    let toolbar: CGRect
    let reviewToolbar: CGRect
    let edges: [CGRect]

    init(region: CGRect, screen: CGRect, visible: CGRect, previousToolbar: CGRect?) {
        self.region = region
        let outline = region.insetBy(dx: -2, dy: -2).intersection(screen)
        let line = min(3, outline.width / 2, outline.height / 2)
        edges = [
            CGRect(x: outline.minX, y: outline.minY, width: outline.width, height: line),
            CGRect(x: outline.minX, y: outline.maxY - line, width: outline.width, height: line),
            CGRect(x: outline.minX, y: outline.minY + line, width: line, height: outline.height - 2 * line),
            CGRect(x: outline.maxX - line, y: outline.minY + line, width: line, height: outline.height - 2 * line),
        ].filter { !$0.isEmpty }

        let safe = visible.insetBy(dx: 8, dy: 8)
        let width = min(CaptureSelectionToolbarMetrics.recordingWidth, safe.width)
        let height = CaptureSelectionToolbarMetrics.height
        let gap: CGFloat = 8
        let right = previousToolbar?.maxX ?? region.maxX
        let x = min(max(safe.minX, right - width), safe.maxX - width)
        let y = min(max(safe.minY, previousToolbar?.minY ?? region.maxY - height), safe.maxY - height)
        func bar(x: CGFloat, y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: width, height: height) }
        let anchored = bar(x: x, y: y)
        let candidates = (previousToolbar == nil ? [] : [anchored]) + [
            bar(x: x, y: region.minY - gap - height),
            bar(x: x, y: region.maxY + gap),
            bar(x: region.maxX + gap, y: y),
            bar(x: region.minX - gap - width, y: y),
        ]
        toolbar = candidates.first { safe.contains($0) && !$0.intersects(outline) }
            ?? (previousToolbar == nil ? bar(x: x, y: safe.minY) : anchored)
        // Editing belongs under the video. Tight selections use the lower
        // edge of the visible screen rather than opening a separate editor.
        let bottom = min(max(safe.minY, region.minY - gap - height), safe.maxY - height)
        reviewToolbar = CGRect(x: x.rounded(.down), y: bottom.rounded(.down),
                               width: width.rounded(.down), height: height)
    }
}

/// The outline, toolbar and a single reusable popover are registered before
/// recording. Menus and hints must not spawn unfiltered windows mid-stream.
@MainActor final class CaptureRecordingPresentation {
    final class Countdown: ObservableObject {
        @Published var remaining = 0
    }

    let layout: CaptureRecordingLayout
    let toolbar: NSPanel
    let outlinePanels: [NSPanel]
    private(set) var playbackPanel: NSPanel?
    private(set) var recordingPopover: NSPanel?
    private(set) var playback: CaptureRecordingPlayback?
    private(set) var isClosed = false
    private let countdown = Countdown()
    private var screenObserver: (any NSObjectProtocol)?
    var onClose: (() -> Void)?

    init(layout: CaptureRecordingLayout) {
        self.layout = layout
        let toolbarLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let bar = CaptureRecordingRegionPanel(contentRect: layout.toolbar, styleMask: [.borderless, .nonactivatingPanel],
                                                backing: .buffered, defer: false)
        Self.configure(bar, name: "recordingToolbar", level: toolbarLevel, interactive: true)
        toolbar = bar
        outlinePanels = layout.edges.enumerated().map { index, edge in
            let panel = Self.makePanel(edge, name: "recordingOutline.\(index)", level: .screenSaver)
            panel.contentView = CaptureRecordingEdgeView(frame: CGRect(origin: .zero, size: edge.size))
            return panel
        }
    }

    func watchDisplay(_ displayID: CGDirectDisplayID, frame: CGRect, changed: @escaping @MainActor () -> Void) {
        guard !isClosed, screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                  object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID }
                if screen?.frame != frame { changed() }
            }
        }
    }

    func showPreparing(seconds: Int) {
        guard !isClosed else { return }
        countdown.remaining = min(60, max(0, seconds))
        for panel in outlinePanels { panel.orderFrontRegardless() }
        if recordingPopover == nil {
            let frame = CGRect(origin: toolbar.frame.origin, size: CGSize(width: 1, height: 1))
            let level = NSWindow.Level(rawValue: toolbar.level.rawValue + 1)
            let panel = Self.makePanel(frame, name: "recordingPopover", level: level, interactive: true)
            panel.alphaValue = 0; panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            recordingPopover = panel
        }
        let cancel: () -> Void = { [weak self] in self?.close() }
        showToolbar(CaptureRecordingWaitingBar(countdown: countdown, saving: false, cancel: cancel), escape: cancel)
    }

    func waitForStart(isAllowed: () -> Bool) async -> Bool {
        guard !isClosed, !Task.isCancelled, isAllowed() else { return false }
        while countdown.remaining > 0 {
            for _ in 0..<10 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
                guard !isClosed, !Task.isCancelled, isAllowed() else { return false }
            }
            countdown.remaining -= 1
        }
        return true
    }

    func showToolbar<Content: View>(_ content: Content, escape: (() -> Void)? = nil, frame: CGRect? = nil) {
        guard !isClosed else { return }
        if let view = toolbar.contentView { CaptureToolbarHelpView.dismiss(in: view) }
        let host = CaptureFirstMouseHostingView(rootView: content)
        host.sizingOptions = []
        (toolbar as? CaptureRecordingRegionPanel)?.escape = escape
        toolbar.contentView = host
        toolbar.setFrame(frame ?? layout.toolbar, display: false)
        toolbar.orderFrontRegardless()
    }

    func setOutlineColor(_ color: NSColor) {
        for panel in outlinePanels {
            (panel.contentView as? CaptureRecordingEdgeView)?.color = color
        }
    }

    var streamControlWindows: [NSWindow] {
        outlinePanels + [toolbar] + [recordingPopover].compactMap { $0 }
    }

    func showRecordingPopover<Content: View>(_ content: Content, size: CGSize) {
        guard !isClosed, let panel = recordingPopover,
              let visible = toolbar.screen?.visibleFrame else { return }
        let safe = visible.insetBy(dx: 8, dy: 8), bar = toolbar.frame
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        let x = min(max(safe.minX, bar.maxX - width), safe.maxX - width)
        let above = bar.maxY + 6
        let y = above + height <= safe.maxY ? above : max(safe.minY, bar.minY - height - 6)
        let host = CaptureFirstMouseHostingView(rootView: content)
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        panel.alphaValue = 1; panel.ignoresMouseEvents = false
        (panel as? CaptureRecordingRegionPanel)?.escape = { [weak self] in self?.hideRecordingPopover() }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hideRecordingPopover() {
        guard let panel = recordingPopover else { return }
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil); panel.contentView = nil
        (panel as? CaptureRecordingRegionPanel)?.escape = nil
        if wasKey { toolbar.makeKey() }
    }

    func showSaving() {
        hideRecordingPopover()
        showToolbar(CaptureRecordingWaitingBar(countdown: countdown, saving: true, cancel: {}))
    }

    func showReview(url: URL, clipboardCache: URL = RecordingClipboard.directory,
                    pasteboard: @escaping () -> NSPasteboard = { .general }) {
        guard !isClosed, playback == nil else { return }
        recordingPopover?.close(); recordingPopover = nil
        let playback = CaptureRecordingPlayback(url: url)
        // AppKit rounds NSWindow frames to points. The viewport sits precisely
        // inside the integral window, with its video snapped to backing pixels.
        let frame = layout.region.integral
        let panel = Self.makePanel(frame, name: "recordingPlayback", level: .screenSaver, interactive: true)
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let video = CaptureRecordingReviewCanvas(playback: playback,
                      frame: layout.region.offsetBy(dx: -frame.minX, dy: -frame.minY))
        container.addSubview(video)
        panel.contentView = container
        self.playback = playback; playbackPanel = panel
        panel.orderFrontRegardless()
        setOutlineColor(.controlAccentColor)
        for edge in outlinePanels { edge.orderFrontRegardless() }

        let copy: () -> Void = { [weak self, weak playback] in
            playback?.copy(to: pasteboard(), cache: clipboardCache) { [weak self] in self?.close() }
        }
        let close: () -> Void = { [weak self, weak playback] in
            if playback?.cropping == true { playback?.cancelCrop() }
            else { self?.close() }
        }
        let export: () -> Void = { [weak self, weak playback] in
            guard let self else { return }
            playback?.chooseExportDestination(above: toolbar)
        }
        (panel as? CaptureRecordingRegionPanel)?.copyVideo = copy
        (panel as? CaptureRecordingRegionPanel)?.escape = close
        showToolbar(CaptureRecordingPlaybackBar(playback: playback, copy: copy, export: export, close: { [weak self] in self?.close() }),
                    escape: close, frame: layout.reviewToolbar)
        (toolbar as? CaptureRecordingRegionPanel)?.copyVideo = copy
        toolbar.makeKey()
    }

    func focusReview() {
        guard !isClosed, playback != nil else { return }
        toolbar.orderFrontRegardless()
        toolbar.makeKey()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        if let view = toolbar.contentView { CaptureToolbarHelpView.dismiss(in: view) }
        playback?.stop(); playback = nil
        for panel in streamControlWindows + [playbackPanel].compactMap({ $0 }) {
            if let region = panel as? CaptureRecordingRegionPanel { region.copyVideo = nil; region.escape = nil }
            panel.orderOut(nil); panel.close(); panel.contentView = nil
        }
        playbackPanel = nil; recordingPopover = nil
        let callback = onClose; onClose = nil; callback?()
    }

    private static func makePanel(_ frame: CGRect, name: String, level: NSWindow.Level, interactive: Bool = false) -> NSPanel {
        let panel = CaptureRecordingRegionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                                backing: .buffered, defer: false)
        configure(panel, name: name, level: level, interactive: interactive)
        panel.setFrame(frame, display: false)
        return panel
    }

    private static func configure(_ panel: NSPanel, name: String, level: NSWindow.Level, interactive: Bool) {
        CaptureWindowPolicy.markControl(panel, name: name)
        panel.level = level; panel.collectionBehavior = CaptureWindowPolicy.floatingBehavior
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isMovable = false; panel.hasShadow = false
        panel.ignoresMouseEvents = !interactive; panel.acceptsMouseMovedEvents = interactive
    }
}

private final class CaptureRecordingRegionPanel: NSPanel {
    var escape: (() -> Void)?
    var copyVideo: (() -> Void)?
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
    // Don't move the captured pixels away from the Dock or menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { escape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performCopy(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !performCopy(event) { super.keyDown(with: event) }
    }
    private func performCopy(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard let copyVideo, flags == .control || flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c" || event.keyCode == 8,
              attachedSheet == nil, !CaptureKeyboardRouting.isEditingText(in: self) else { return false }
        if !event.isARepeat { copyVideo() }
        return true
    }
}

private final class CaptureRecordingEdgeView: NSView {
    var color = NSColor.systemRed { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.75).setFill(); bounds.fill()
        let horizontal = bounds.width >= bounds.height
        color.setFill(); bounds.insetBy(dx: horizontal ? 0 : 0.5, dy: horizontal ? 0.5 : 0).fill()
    }
}

private struct CaptureRecordingWaitingBar: View {
    @ObservedObject var countdown: CaptureRecordingPresentation.Countdown
    let saving: Bool
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(saving ? "正在保存录屏…" : countdown.remaining > 0 ? "\(countdown.remaining) 秒后开始录屏" : "正在开始录屏…")
                .monospacedDigit().lineLimit(1)
            Spacer(minLength: 0)
            if !saving {
                Button("取消", action: cancel)
                    .modifier(CaptureToolbarControl(hint: ""))
                    .accessibilityHint("按 Esc 取消录屏")
            }
        }
        .modifier(CaptureRecordingBarStyle())
    }
}

struct CaptureRecordingBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .buttonStyle(.plain).modifier(CaptureToolbarSurface())
    }
}

/// Pixel geometry of the saved file, not a scaled image of the display.
/// Avoid enlarging a smaller encode, or introducing half-pixel interpolation
/// when H.264 rounded an odd source dimension down by a pixel.
enum CaptureRecordingVideoGeometry {
    static func frame(pixels: CGSize, within bounds: CGRect, backingScale: CGFloat) -> CGRect {
        guard pixels.width > 0, pixels.height > 0, !bounds.isEmpty else { return bounds }
        let scale = max(1, backingScale)
        let left = ceil(bounds.minX * scale), bottom = ceil(bounds.minY * scale)
        let right = floor(bounds.maxX * scale), top = floor(bounds.maxY * scale)
        guard right > left, top > bottom else { return bounds }
        let factor = min(1, (right - left) / pixels.width, (top - bottom) / pixels.height)
        let size = CGSize(width: factor * pixels.width, height: factor * pixels.height)
        let x = max(left, ((left + right - size.width) / 2).rounded(.down))
        let y = max(bottom, ((bottom + top - size.height) / 2).rounded(.down))
        return CGRect(x: x / scale, y: y / scale, width: size.width / scale, height: size.height / scale)
    }
}

final class CaptureRecordingReviewCanvas: NSView {
    let video: NSView
    private let crop: NSHostingView<CaptureRecordingCropOverlay>
    private var observers: Set<AnyCancellable> = []
    private var pixels = CGSize.zero

    init(playback: CaptureRecordingPlayback, frame: CGRect) {
        video = CaptureRecordingVideoSurface(player: playback.player)
        crop = NSHostingView(rootView: CaptureRecordingCropOverlay(playback: playback))
        crop.sizingOptions = []
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(video); addSubview(crop)
        playback.$videoPixels.sink { [weak self] pixels in self?.pixels = pixels; self?.needsLayout = true }.store(in: &observers)
        playback.$cropping.sink { [weak self] editing in self?.crop.isHidden = !editing }.store(in: &observers)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1
        let windowBounds = convert(bounds, to: nil)
        let frame = CaptureRecordingVideoGeometry.frame(pixels: pixels, within: windowBounds, backingScale: scale)
        video.frame = convert(frame, from: nil)
        video.layer?.contentsScale = scale
        crop.frame = video.frame
    }
}

private final class CaptureRecordingVideoSurface: NSView {
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        guard let surface = layer as? AVPlayerLayer else { return }
        surface.player = player; surface.videoGravity = .resizeAspect
        surface.backgroundColor = NSColor.black.cgColor
        setAccessibilityLabel("原位录屏预览")
    }
    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}
