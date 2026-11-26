import AppKit
import Combine
import SwiftUI

@MainActor final class DictationHUD {
    static let compact = NSSize(width: 88, height: 38)
    static let expanded = NSSize(width: 296, height: 62)
    static let contentInset: CGFloat = 9, captionHeight: CGFloat = 23
    // One optical margin: a typical speaking stem extends ~8 pt above its centre;
    // a single line of 15.5 pt type has ~3 pt of leading below the ink in its slot.
    // Use fixed offsets, never chase individual glyphs or the current audio level.
    fileprivate static let expandedWaveCenterY = contentInset + 8, captionBottomInset = contentInset - 3
    static func captionWidth(in width: CGFloat) -> CGFloat { max(1, width - 2 * contentInset) }
    private var panel: DictationPanel?
    private var stage: DictationHUDStage?
    private var expansion: AnyCancellable?, displayOptions: AnyCancellable?
    isolated deinit { close() }

    nonisolated static func preview(for text: String) -> String { DictationCaptionSlice(text).summary }

    static func frame(on visible: NSRect, expanded: Bool) -> NSRect {
        let size = expanded ? Self.expanded : Self.compact
        let width = min(size.width, max(1, visible.width - 32))
        return .init(x: (visible.midX - width / 2).rounded(), y: visible.minY + 32, width: width, height: size.height)
    }

    func show(controller: DoubaoDictationController) {
        close()
        let point = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
        let frame = visible.map { Self.frame(on: $0, expanded: true) } ?? NSRect(origin: .zero, size: Self.expanded)
        // The nonactivating, mouse-transparent window stays still. Only its small visible
        // glass surface expands, pinned to the same bottom centre, once per utterance.
        let panel = DictationPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("doubao.dictation.hud")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: DictationHUDView(controller: controller, captionWidth: Self.captionWidth(in: frame.width)))
        host.sizingOptions = []; host.autoresizingMask = [.width, .height]
        let stage = DictationHUDStage(size: frame.size, content: host)
        panel.contentView = stage
        self.stage = stage; self.panel = panel
        stage.refreshDisplayOptions()
        displayOptions = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak stage] _ in stage?.refreshDisplayOptions() }
        expansion = controller.$captionSlice.first(where: { !$0.line.isEmpty }).sink { [weak stage] _ in stage?.expand() }
        panel.orderFrontRegardless()
    }
    /// Replace the live wave/caption with a static acknowledgement in the same
    /// mouse-transparent window. No focus, new screen capture, animation or input events.
    func showReceipt(_ message: String) {
        guard let panel else { return }
        expansion?.cancel(); expansion = nil; displayOptions?.cancel(); displayOptions = nil
        stage?.stop(); stage = nil
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium); label.alignment = .center
        label.textColor = .labelColor; label.lineBreakMode = .byTruncatingTail; label.sizeToFit()
        let outer = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        let w = min(outer.bounds.width, label.frame.width + 26), h = Self.compact.height
        let content = NSView()
        let plate = DictationHUDPlate.make(in: NSRect(x: (outer.bounds.width - w) / 2, y: 0, width: w, height: h),
                                          content: content, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        label.frame = NSRect(x: 7, y: ((h - label.frame.height) / 2).rounded(), width: max(1, w - 14), height: label.frame.height)
        content.addSubview(label); outer.addSubview(plate); panel.contentView = outer; panel.invalidateShadow()
    }
    func close() {
        expansion?.cancel(); expansion = nil; displayOptions?.cancel(); displayOptions = nil
        stage?.stop(); stage = nil
        panel?.orderOut(nil); panel?.contentView = nil; panel?.close(); panel = nil
    }
}

/// One bounded transition, independent of microphone/ASR updates. There is no animated
/// NSWindow resize, implicit spring, or per-word change of the glass's target width.
@MainActor final class DictationHUDStage: NSView {
    private let content: NSView
    private(set) var plate: NSView?
    private var solid: Bool?, reduceMotion = false
    private(set) var openness: CGFloat = 0
    private var hasExpanded = false, transition: Task<Void, Never>?
    init(size: NSSize, content: NSView) {
        self.content = content; super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { stop() }

    func refreshDisplayOptions() {
        configure(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  solid: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
    func configure(reduceMotion: Bool, solid: Bool) {
        self.reduceMotion = reduceMotion
        if solid != self.solid {
            self.solid = solid
            content.removeFromSuperview(); plate?.removeFromSuperview()
            let view = DictationHUDPlate.make(in: surfaceFrame, content: content, reduceTransparency: solid)
            plate = view; addSubview(view)
        }
        if reduceMotion && hasExpanded { stop(); apply(1) }
    }
    private var surfaceFrame: NSRect {
        let w0 = min(bounds.width, DictationHUD.compact.width)
        let w = w0 + (bounds.width - w0) * openness
        let h = DictationHUD.compact.height + (bounds.height - DictationHUD.compact.height) * openness
        return NSRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: h)
    }
    private func apply(_ p: CGFloat) { openness = p; plate?.frame = surfaceFrame }
    func expand() {
        guard !hasExpanded else { return }
        hasExpanded = true
        guard !reduceMotion else { apply(1); return }
        let start = CACurrentMediaTime()
        transition = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = min(1, (CACurrentMediaTime() - start) / 0.30)
                self.apply(t * t * (3 - 2 * t))
                if t >= 1 { self.transition = nil; self.window?.invalidateShadow(); return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    func stop() { transition?.cancel(); transition = nil }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Embed the content *inside* native glass; no black tint, second material, or forced dark mode.
@MainActor enum DictationHUDPlate {
    static func make(in frame: NSRect, content: NSView, reduceTransparency: Bool) -> NSView {
        let radius = DictationHUD.compact.height / 2
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        if !reduceTransparency {
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView(frame: frame)
                glass.style = .regular; glass.cornerRadius = radius; glass.contentView = content
                return glass
            }
            let material = NSVisualEffectView(frame: frame)
            material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
            material.wantsLayer = true; material.layer?.cornerRadius = radius; material.layer?.cornerCurve = .continuous
            material.layer?.masksToBounds = true; material.addSubview(content)
            return material
        }
        let solid = Solid(frame: frame); solid.addSubview(content); return solid
    }
    private final class Solid: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let r = DictationHUD.compact.height / 2
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
            NSColor.windowBackgroundColor.withAlphaComponent(1).setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    }
}

private struct DictationHUDView: View {
    @ObservedObject var controller: DoubaoDictationController
    let captionWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let p = min(1, max(0, (size.height - DictationHUD.compact.height) / (DictationHUD.expanded.height - DictationHUD.compact.height)))
            let waveWidth = DictationWaveMotion.compactWidth + (DictationWaveMotion.expandedWidth - DictationWaveMotion.compactWidth) * p
            let compactCenterY = DictationHUD.compact.height / 2
            let headerY = compactCenterY + (DictationHUD.expandedWaveCenterY - compactCenterY) * p
            let captionY = size.height - DictationHUD.captionBottomInset - DictationHUD.captionHeight / 2
            ZStack {
                if controller.phase == .finishing {
                    DictationHUDLabel(text: p < 0.5 ? "正在定稿" : controller.statusTitle, size: 11.5)
                        .fixedSize().position(x: size.width / 2, y: headerY)
                } else {
                    DictationWave(readings: controller.waveReadings, reduceMotion: reduceMotion)
                        .frame(width: min(waveWidth, size.width), height: DictationWaveMotion.slotHeight)
                        .position(x: size.width / 2, y: headerY)
                }
                if !controller.captionSlice.line.isEmpty && p >= 0.99 {
                    // Mount once the fixed-width, single-line viewport fits inside the glass.
                    DictationDraftCaption(slice: controller.captionSlice, reduceMotion: reduceMotion, layoutWidth: captionWidth)
                        .frame(width: captionWidth, height: DictationHUD.captionHeight)
                        .position(x: size.width / 2, y: captionY)
                } else if p >= 1 {
                    DictationHUDLabel(text: "等待识别结果…", size: 14).fixedSize()
                        .position(x: size.width / 2, y: captionY)
                }
            }
            .frame(width: size.width, height: size.height).clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.phase == .finishing ? controller.statusTitle : "听写预览")
        .accessibilityValue(controller.bubblePreview)
        .accessibilityHint("使用听写快捷键结束。定稿优先插入当前输入框，否则复制；取消不提交草稿")
    }
}

private struct DictationHUDLabel: NSViewRepresentable {
    let text: String, size: CGFloat
    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .center; label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: size, weight: .medium); return label
    }
    func updateNSView(_ label: NSTextField, context: Context) { label.stringValue = text }
}
