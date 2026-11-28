import AppKit
import Combine
import QuartzCore

@MainActor final class DictationHUD {
    private let style: DictationHUDStyle
    private var panel: DictationPanel?
    private var stage: DictationHUDStage?
    private var presentation: AnyCancellable?, displayOptions: AnyCancellable?
    init(style: DictationHUDStyle = .defaults) { self.style = style }
    isolated deinit { close() }

    nonisolated static func preview(for text: String) -> String { DictationCaptionSlice(text).summary }

    static func frame(on visible: NSRect, expanded: Bool, style: DictationHUDStyle = .defaults) -> NSRect {
        let size = expanded ? style.expanded : style.compact
        let width = min(size.width, max(1, visible.width - 32))
        return .init(x: (visible.midX - width / 2).rounded(), y: visible.minY + 32, width: width, height: size.height)
    }

    func show(controller: DoubaoDictationController) {
        close()
        let point = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
        let frame = visible.map { Self.frame(on: $0, expanded: true, style: style) } ?? NSRect(origin: .zero, size: style.expanded)
        // Only the visible glass changes size; the nonactivating window never moves.
        let panel = DictationPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("doubao.dictation.hud")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let stage = DictationHUDStage(size: frame.size, readings: controller.waveReadings, style: style)
        panel.contentView = stage
        self.stage = stage; self.panel = panel
        stage.refreshDisplayOptions()
        displayOptions = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak stage] _ in stage?.refreshDisplayOptions() }
        presentation = controller.$captionSlice.combineLatest(controller.$phase).sink { [weak stage] slice, phase in
            stage?.display(slice, finishing: phase == .finishing || phase == .idle)
        }
        panel.orderFrontRegardless()
    }

    /// Replace the live surface with a static acknowledgement in the same window.
    func showReceipt(_ message: String) {
        guard let panel else { return }
        stopStage()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium); label.alignment = .center
        label.textColor = .labelColor; label.lineBreakMode = .byTruncatingTail; label.sizeToFit()
        let outer = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        let w = min(outer.bounds.width, label.frame.width + 26), h = style.compactHeight
        let content = NSView()
        let plate = DictationHUDPlate.make(in: NSRect(x: (outer.bounds.width - w) / 2, y: 0, width: w, height: h),
                                          content: content, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        label.frame = NSRect(x: 7, y: ((h - label.frame.height) / 2).rounded(), width: max(1, w - 14), height: label.frame.height)
        content.addSubview(label); outer.addSubview(plate); panel.contentView = outer; panel.invalidateShadow()
    }
    private func stopStage() {
        presentation?.cancel(); presentation = nil; displayOptions?.cancel(); displayOptions = nil
        stage?.stop(); stage = nil
    }
    func close() {
        stopStage()
        panel?.orderOut(nil); panel?.contentView = nil; panel?.close(); panel = nil
    }
}

/// Coordinates one glass surface, one caption viewport and the opening wave.
/// Its only repeating work is painting the small, visible glass while listening.
@MainActor final class DictationHUDStage: NSView {
    private struct Widening {
        let from, to: CGFloat
        let start, duration: TimeInterval
        var end: TimeInterval { start + duration }
        func width(at t: TimeInterval) -> CGFloat {
            let u = min(1, max(0, (t - start) / duration))
            return from + (to - from) * (1 - (1 - u) * (1 - u) * (1 - u))
        }
    }

    let style: DictationHUDStyle
    private let content = NSView(), viewport = NSView()
    private let caption: DictationCaptionView
    private let status = NSTextField(labelWithString: "")
    private let readings: CurrentValueSubject<DictationMeterReading, Never>?
    private let now: () -> TimeInterval
    private(set) var wave: DictationWaveView?
    let liquid: DictationLiquidBackdrop
    private(set) var plate: NSView?
    private(set) var openness: CGFloat = 0
    private var solid = false, reduceMotion = false, finishing = false
    private var slice = DictationCaptionSlice("")
    private var openedAt: TimeInterval?, widening: Widening?
    private var targetWidth: CGFloat, captionLayoutWidth: CGFloat = 1
    private var clock: Task<Void, Never>?
    var isAnimating: Bool { clock != nil }

    init(size: NSSize, readings: CurrentValueSubject<DictationMeterReading, Never>? = nil,
         style: DictationHUDStyle = .defaults, now: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.now = now; self.readings = readings; self.style = style
        caption = DictationCaptionView(frame: .zero, now: now)
        liquid = DictationLiquidBackdrop(style: style)
        targetWidth = min(size.width, style.compactWidth)
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityHelp("使用听写快捷键结束。定稿优先插入当前输入框，否则复制；取消不提交草稿")
        status.setAccessibilityElement(false)
        status.alignment = .center; status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12, weight: .medium); status.lineBreakMode = .byTruncatingTail
        viewport.clipsToBounds = true
        let wave = DictationWaveView(frame: .zero, now: now)
        self.wave = wave
        content.addSubview(liquid); content.addSubview(wave)
        viewport.addSubview(caption); content.addSubview(viewport); content.addSubview(status)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { stop() }

    func refreshDisplayOptions() {
        configure(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  solid: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
    func configure(reduceMotion: Bool, solid: Bool) {
        if plate == nil || self.solid != solid {
            content.removeFromSuperview(); plate?.removeFromSuperview()
            let view = DictationHUDPlate.make(in: surfaceFrame(at: now()), content: content, reduceTransparency: solid)
            plate = view; addSubview(view)
        }
        self.solid = solid; self.reduceMotion = reduceMotion
        if reduceMotion { widening = nil }
        if let readings { wave?.bind(readings, reduceMotion: reduceMotion, solid: solid) }
        caption.display(slice, reduceMotion: reduceMotion, layoutWidth: captionLayoutWidth)
        refresh()
    }

    func display(_ next: DictationCaptionSlice, finishing: Bool) {
        let t = now(), opening = openedAt == nil && !next.line.isEmpty
        if opening { openedAt = t }
        self.slice = next; self.finishing = finishing
        setAccessibilityLabel(finishing ? "正在定稿" : "听写预览")
        setAccessibilityValue(next.summary)
        status.stringValue = finishing ? "正在定稿…" : "正在听写…"
        captionLayoutWidth = caption.display(next, reduceMotion: reduceMotion, fittingWidth: { [self] measured in
            if !next.line.isEmpty { widen(for: measured, opening: opening, at: t) }
            return style.captionWidth(in: targetWidth)
        })
        refresh()
    }

    private func widen(for measured: CGFloat, opening: Bool, at t: TimeInterval) {
        // Grow in small steps for new text. Corrections never squeeze the current line.
        let padded = (ceil((measured + 2 * style.contentInset + 1) / 8) * 8)
        let wanted = min(bounds.width, max(style.minimumCaptionWidth, padded))
        guard wanted > targetWidth else { return }
        let previous = widening?.width(at: t) ?? targetWidth
        targetWidth = wanted
        widening = reduceMotion ? nil : Widening(from: previous, to: wanted, start: t, duration: opening ? style.openingDuration : style.growthDuration)
    }
    private static func smooth(_ t: CGFloat) -> CGFloat {
        let p = min(1, max(0, t)); return p * p * (3 - 2 * p)
    }
    private func progress(at t: TimeInterval) -> CGFloat {
        guard let openedAt else { return 0 }
        return reduceMotion ? 1 : min(1, max(0, (t - openedAt) / style.openingDuration))
    }
    private func surfaceFrame(at t: TimeInterval) -> CGRect {
        let w = widening?.width(at: t) ?? targetWidth
        let h = style.compactHeight + (bounds.height - style.compactHeight) * Self.smooth(progress(at: t))
        return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: h)
    }

    private func render(at t: TimeInterval) {
        guard let plate else { return }
        let wasOpening = openness < 1, resized = widening != nil
        openness = progress(at: t)
        let frame = surfaceFrame(at: t)
        if let widening, t >= widening.end { self.widening = nil }
        DictationHUDPlate.resize(plate, to: frame)
        let size = frame.size
        content.setFrameSize(size)
        liquid.frame = CGRect(origin: .zero, size: size)
        liquid.alphaValue = solid ? 0 : Self.smooth((openness - 0.04) / 0.96)
        liquid.isHidden = liquid.alphaValue == 0
        sampleLight(at: t)

        if let wave {
            wave.alphaValue = finishing ? 0 : 1 - Self.smooth((openness - 0.07) / (style.waveFadeEnd - 0.07))
            if wave.alphaValue <= 0 {
                wave.disconnect(); wave.removeFromSuperview(); self.wave = nil
            } else {
                let w = min(size.width, DictationWaveMotion.compactWidth)
                wave.frame = CGRect(x: (size.width - w) / 2, y: (size.height - DictationWaveMotion.slotHeight) / 2,
                                    width: w, height: DictationWaveMotion.slotHeight)
            }
        }
        let visibleCaptionWidth = style.captionWidth(in: size.width), captionHeight = DictationHUDStyle.captionHeight
        let captionY = (size.height - captionHeight) / 2
        viewport.frame = CGRect(x: (size.width - visibleCaptionWidth) / 2, y: captionY,
                                width: visibleCaptionWidth, height: captionHeight)
        caption.frame = CGRect(x: (visibleCaptionWidth - captionLayoutWidth) / 2, y: 0,
                               width: captionLayoutWidth, height: captionHeight)
        viewport.alphaValue = Self.smooth((openness - style.captionFadeStart) / (0.92 - style.captionFadeStart))
        viewport.isHidden = slice.line.isEmpty || viewport.alphaValue == 0
        status.isHidden = !slice.line.isEmpty || (!finishing && openedAt == nil)
        status.frame = viewport.frame
        if (wasOpening && openness == 1) || (resized && widening == nil) { window?.invalidateShadow() }
    }

    private func sampleLight(at t: TimeInterval) {
        if drifts, let openedAt { liquid.sample(at: t - openedAt) }
    }
    private var drifts: Bool { openedAt != nil && !finishing && !solid && !reduceMotion }
    private var resizes: Bool { widening != nil || (openedAt != nil && openness < 1) }
    private var needsClock: Bool { window != nil && (resizes || drifts) }
    func refresh() {
        render(at: now())
        guard needsClock else { stopClock(); return }
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.resizes == true ? 16 : 33
                do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let time = self.now()
                if self.resizes { self.render(at: time) } else { self.sampleLight(at: time) }
                if !self.needsClock { self.clock = nil; return }
            }
        }
    }
    private func stopClock() { clock?.cancel(); clock = nil }
    func stop() { stopClock(); wave?.disconnect(); caption.stop() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
        else {
            if let readings { wave?.bind(readings, reduceMotion: reduceMotion, solid: solid) }
            refresh()
        }
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The system supplies the glass. The colour field is clipped content, not a second material.
@MainActor enum DictationHUDPlate {
    static func make(in frame: NSRect, content: NSView, reduceTransparency: Bool) -> NSView {
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        if !reduceTransparency {
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView(frame: frame)
                glass.style = .regular; glass.cornerRadius = radius(in: frame); glass.contentView = content
                return glass
            }
            let material = NSVisualEffectView(frame: frame)
            material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
            material.wantsLayer = true; material.layer?.cornerRadius = radius(in: frame)
            material.layer?.masksToBounds = true; material.addSubview(content)
            return material
        }
        let solid = Solid(frame: frame); solid.addSubview(content); return solid
    }
    static func resize(_ plate: NSView, to frame: NSRect) {
        guard plate.frame != frame else { return }
        let oldRadius = radius(in: plate.frame), next = radius(in: frame)
        plate.frame = frame
        if oldRadius != next {
            if #available(macOS 26, *), let glass = plate as? NSGlassEffectView { glass.cornerRadius = next }
            else if let material = plate as? NSVisualEffectView { material.layer?.cornerRadius = next }
        }
        if plate is Solid { plate.needsDisplay = true }
    }
    static func radius(in rect: CGRect) -> CGFloat { min(rect.width, rect.height) / 2 }
    private final class Solid: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let box = bounds.insetBy(dx: 0.5, dy: 0.5), r = DictationHUDPlate.radius(in: box)
            let path = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
            NSColor.windowBackgroundColor.withAlphaComponent(1).setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    }
}
