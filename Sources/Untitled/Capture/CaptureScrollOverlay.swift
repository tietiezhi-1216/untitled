import AppKit
import SwiftUI

/// Layout is in Cocoa screen coordinates. The output group stays right-aligned
/// at the original toolbar, including when the selection is near a display edge.
struct CaptureScrollOverlayLayout {
    static let toolbarSize = CGSize(width: 390, height: 40)
    let toolbar: CGRect
    let preview: CGRect?

    init(selection: CGRect, visible: CGRect, previousToolbar: CGRect?) {
        let safe = visible.insetBy(dx: 8, dy: 8)
        let width = min(Self.toolbarSize.width, safe.width)
        let height = Self.toolbarSize.height
        let below = selection.minY - height - 8
        let y = previousToolbar?.minY ?? (below >= safe.minY ? below : selection.maxY + 8)
        let right = previousToolbar?.maxX ?? selection.maxX
        toolbar = CGRect(x: max(safe.minX, min(right - width, safe.maxX - width)),
                         y: max(safe.minY, min(y, safe.maxY - height)), width: width, height: height)

        // Prefer a slim preview outside the live area. Never cover the selected
        // pixels or the toolbar; a near-full-screen selection can use the popover.
        let selectionWithGap = selection.insetBy(dx: -8, dy: -8)
        let toolbarWithGap = toolbar.insetBy(dx: -6, dy: -6)
        let candidates = [
            CGRect(x: selectionWithGap.maxX, y: safe.minY, width: safe.maxX - selectionWithGap.maxX, height: safe.height),
            CGRect(x: safe.minX, y: safe.minY, width: selectionWithGap.minX - safe.minX, height: safe.height),
            CGRect(x: safe.minX, y: selectionWithGap.maxY, width: safe.width, height: safe.maxY - selectionWithGap.maxY),
            CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: selectionWithGap.minY - safe.minY),
        ]
        var result: CGRect?
        for (index, region) in candidates.enumerated() where region.size.width >= 104 && region.size.height >= 92 {
            let size = CGSize(width: min(168, region.width), height: min(300, region.height))
            let x = index == 1 ? region.maxX - size.width : region.minX
            let y = max(region.minY, min(selection.maxY - size.height, region.maxY - size.height))
            let preferred = CGRect(origin: CGPoint(x: x, y: y), size: size)
            var alternatives = [preferred]
            alternatives.append(CGRect(x: x, y: region.minY, width: size.width, height: size.height))
            alternatives.append(CGRect(x: region.maxX - size.width, y: y, width: size.width, height: size.height))
            if let frame = alternatives.first(where: { !$0.intersects(toolbarWithGap) }) {
                result = frame
                break
            }
        }
        preview = result
    }
}

/// The dim surface is transparent and click-through. Only the small in-place
/// toolbar accepts input; wheel/drag events go to the app being captured.
@MainActor final class CaptureScrollOverlay {
    let backdrop: NSPanel
    let toolbar: NSPanel
    let layout: CaptureScrollOverlayLayout
    private var screenObserver: Any?
    private var onDisplayChange: (() -> Void)?

    init(session: ScrollCaptureSession, selection: CGRect, screenFrame: CGRect, visible: CGRect,
         previousToolbar: CGRect?, reusing panel: NSPanel?, displayChanged: @escaping () -> Void) {
        let layout = CaptureScrollOverlayLayout(selection: selection, visible: visible, previousToolbar: previousToolbar)
        self.layout = layout
        backdrop = panel ?? NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        toolbar = CaptureScrollToolbarPanel(contentRect: layout.toolbar, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        onDisplayChange = displayChanged
        backdrop.orderOut(nil)
        backdrop.setFrame(screenFrame, display: false)
        configure(backdrop, as: "scrollShade", level: .screenSaver, interactive: false)
        let local = selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let shade = CaptureScrollShade(frame: CGRect(origin: .zero, size: screenFrame.size), selection: local)
        backdrop.contentView = shade
        if let preview = layout.preview {
            let host = NSHostingView(rootView: CaptureScrollPreviewContent(session: session))
            host.sizingOptions = []
            host.frame = preview.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            shade.addSubview(host)
        }
        let host = CaptureFirstMouseHostingView(rootView: CaptureScrollToolbar(session: session, showPreview: layout.preview == nil))
        host.sizingOptions = []
        configure(toolbar, as: "scrollToolbar", level: NSWindow.Level(rawValue: backdrop.level.rawValue + 1),
                  interactive: true)
        toolbar.contentView = host
        (toolbar as? CaptureScrollToolbarPanel)?.cancel = { [weak session] in session?.requestClose() }
    }

    func show() {
        // Do not activate Untitled or steal keyboard focus from the source.
        backdrop.orderFrontRegardless()
        toolbar.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onDisplayChange?() } }
    }

    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        onDisplayChange = nil
        if let view = toolbar.contentView { CaptureToolbarHelpView.dismiss(in: view) }
        for panel in [toolbar, backdrop] {
            panel.orderOut(nil)
            panel.close()
            panel.contentView = nil
        }
    }

    private func configure(_ panel: NSPanel, as name: String, level: NSWindow.Level, interactive: Bool) {
        CaptureWindowPolicy.markControl(panel, name: name)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = CaptureWindowPolicy.floatingBehavior
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = !interactive
        panel.acceptsMouseMovedEvents = interactive
        panel.isMovable = false
        panel.alphaValue = 1
    }
}

private final class CaptureScrollToolbarPanel: NSPanel {
    var cancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

private final class CaptureScrollShade: NSView {
    let selection: CGRect
    init(frame: CGRect, selection: CGRect) { self.selection = selection; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.34).setFill()
        shade.fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -0.75, dy: -0.75))
        outline.lineWidth = 1.5
        outline.stroke()
    }
}

struct CaptureScrollToolbar: View {
    @ObservedObject var session: ScrollCaptureSession
    let showPreview: Bool
    @ViewState private var crop = false
    @ViewState private var preview = false
    @ViewState private var restart = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false).fixedSize()
            row(compact: true).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, CaptureSelectionToolbarMetrics.horizontalInset)
        .padding(.vertical, CaptureSelectionToolbarMetrics.verticalInset)
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .modifier(CaptureToolbarSurface())
        .confirmationDialog("从当前位置重新开始拼接？", isPresented: $restart, titleVisibility: .visible) {
            Button("重新开始") { session.restart() }
            Button("取消", role: .cancel) {}
        } message: { Text("已拼接的内容会先暂存。") }
        .panelRegion("capture.scroll.toolbar")
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 2) {
            if !compact {
                Menu {
                    directionButtons
                } label: {
                    glyph(session.axis == .vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                }
                .menuStyle(.button).menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .modifier(CaptureToolbarControl(hint: "滚动方向 · \(session.axis.title)"))
                .accessibilityLabel("滚动方向")
                .disabled(session.isSaving)
                action(session.isPaused ? "play" : "pause", session.isPaused ? "继续拼接" : "暂停拼接", "pause") {
                    session.togglePause()
                }
                action("arrow.down.to.line", "自动滚动", "auto", selected: session.automaticScroll) {
                    session.toggleAutomaticScroll()
                }.disabled(session.isPaused)
                action("crop", "裁剪长截图", "crop") { crop = true }
                    .popover(isPresented: $crop) { cropOptions.padding(14).frame(width: 260) }
            }
            Menu {
                if compact {
                    directionButtons
                    Button(session.isPaused ? "继续拼接" : "暂停拼接") { session.togglePause() }
                    Button(session.automaticScroll ? "停止自动滚动" : "自动滚动") { session.toggleAutomaticScroll() }
                        .disabled(session.isPaused)
                    Button("裁剪…") { crop = true }
                    Divider()
                }
                if showPreview { Button("查看拼接预览") { preview = true } }
                Button("重新开始…") { restart = true }
                Button("快速保存") { session.submit(.quickSave) }.disabled(session.completedSegments > 0)
                Button("分段导出…") { session.submit(.save, asSegments: true) }
                Button("暂存目录") { session.revealRecovery() }
                Button("保留并关闭") { session.requestClose() }
            } label: { CaptureToolbarMoreIcon() }
            .menuStyle(.button).menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .modifier(CaptureToolbarControl(hint: "长截图更多操作 · \(session.status ?? session.pixelDimensions)"))
            .accessibilityLabel("长截图更多操作")
            .disabled(session.isSaving)
            .popover(isPresented: Binding(get: { preview || (compact && crop) }, set: {
                if !$0 { preview = false; crop = false }
            })) {
                if preview { CaptureScrollPreviewContent(session: session).frame(width: 180, height: 300) }
                else { cropOptions.padding(14).frame(width: 260) }
            }

            Divider().frame(width: 1, height: 18).padding(.horizontal, 6)

            // The last three before Close match the ordinary selection tools.
            imageAction("square.and.pencil", "编辑长截图", "edit", .edit)
            imageAction("text.viewfinder", "识别文字并复制", "ocr", .ocr)
            imageAction("pin", "贴图", "pin", .pin)
            action("square.and.arrow.down", session.completedSegments > 0 ? "导出全部分段…" : "保存长截图…", "save") {
                session.submit(.save)
            }
            imageAction("doc.on.doc", "复制长截图并关闭", "copy", .copy, prominent: true)
            action("xmark", "保留并关闭长截图", "close") { session.requestClose() }
        }
    }

    private var directionButtons: some View {
        ForEach(StitchAxis.allCases) { axis in
            Button {
                session.chooseDirection(axis)
            } label: {
                if axis == session.axis { Label(axis.title, systemImage: "checkmark") }
                else { Text(axis.title) }
            }
        }
    }

    private var cropOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.completedSegments > 0 {
                Text("只裁剪当前段；已封存分段保持不变。").font(.caption)
            }
            Slider(value: $session.cropStart, in: 0...max(0.01, session.cropEnd - 0.01)) { Text("起点") }
            Slider(value: $session.cropEnd, in: min(0.99, session.cropStart + 0.01)...1) { Text("终点") }
            Toggle("回滚时裁掉多余部分", isOn: $session.trimOnReverse)
        }.disabled(session.isSaving)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name).frame(width: 28, height: 28).contentShape(Rectangle())
    }

    private func imageAction(_ symbol: String, _ title: String, _ id: String, _ output: CaptureSelectionPostAction,
                             prominent: Bool = false) -> some View {
        let segmented = session.completedSegments > 0
        return action(symbol, segmented ? title + " · 分段长截图请使用保存" : title, id, prominent: prominent) {
            session.submit(output)
        }
        .disabled(segmented)
    }

    private func action(_ symbol: String, _ title: String, _ id: String, selected: Bool = false,
                        prominent: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { glyph(symbol) }
            .modifier(CaptureToolbarControl(hint: title, selected: selected, prominent: prominent))
            .accessibilityLabel(title)
            .disabled(session.isSaving)
            .panelRegion("capture.scroll.action.\(id)")
    }
}

private struct CaptureScrollPreviewContent: View {
    @ObservedObject var session: ScrollCaptureSession
    var body: some View {
        VStack(spacing: 5) {
            ScrollCapturePreview(session: session)
            Text(session.pixelDimensions).monospacedDigit()
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let message = session.isSaving ? "正在保存…" : session.status {
                Text(message)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Leave the surrounding desktop shade visible through the margins.
        .padding(8)
        .allowsHitTesting(false)
    }
}
