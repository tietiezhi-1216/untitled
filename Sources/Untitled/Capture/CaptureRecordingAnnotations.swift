import AppKit
import SwiftUI

/// A transparent drawing surface inside the capture filter. Ordinary pointer
/// input passes through until the user chooses an annotation tool.
@MainActor final class CaptureRecordingAnnotations: ObservableObject {
    @Published var tool: CaptureTool? {
        didSet {
            panel?.ignoresMouseEvents = tool == nil
            if tool != nil {
                if NSApp?.keyWindow !== panel { previousKeyWindow = NSApp?.keyWindow }
                panel?.makeKeyAndOrderFront(nil); panel?.makeFirstResponder(surface)
            } else if panel?.isKeyWindow == true { previousKeyWindow?.makeKeyAndOrderFront(nil) }
            surface?.needsDisplay = true
        }
    }
    @Published var color = Color.red
    @Published var width = 3.0
    @Published private(set) var marks: [CaptureMark] = []
    private var panel: NSPanel?
    private var surface: RecordingAnnotationSurface?
    private weak var previousKeyWindow: NSWindow?
    private(set) var draft: CaptureMark?
    private var nextNumber = 1

    func start(in selection: CaptureSelection) {
        guard let frame = selection.presentationFrame else { return }
        let panel = RecordingAnnotationPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureWindowPolicy.markControl(panel, name: "recordingAnnotations")
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .floating; panel.ignoresMouseEvents = true
        panel.collectionBehavior = CaptureWindowPolicy.floatingBehavior
        let surface = RecordingAnnotationSurface(owner: self)
        panel.contentView = surface; self.panel = panel; self.surface = surface
        panel.orderFrontRegardless()
    }
    func stop() { panel?.close(); panel = nil; surface = nil; draft = nil }
    func undo() {
        if let last = marks.popLast(), last.tool == .number { nextNumber = max(1, (last.numberValue ?? 1)) }
        surface?.needsDisplay = true
    }
    func clear() { marks = []; draft = nil; nextNumber = 1; surface?.needsDisplay = true; surface?.displayIfNeeded() }
    func begin(_ point: CGPoint) {
        guard let tool, marks.count < 1000 else { return }
        var mark = CaptureMark(tool: tool, points: [point, point], color: NSColor(color), width: CGFloat(width))
        if tool == .number { mark.numberValue = nextNumber; mark.text = String(nextNumber) }
        if tool == .rectangle { mark.style.cornerRadius = 6 }
        if tool == .highlight { mark.style.opacity = 0.35; mark.width = max(12, mark.width * 4) }
        draft = mark; surface?.needsDisplay = true
    }
    func drag(_ point: CGPoint) {
        guard var mark = draft else { return }
        if mark.tool == .pen || mark.tool == .highlight { mark.points.append(point) }
        else { mark.points[mark.points.count - 1] = point }
        draft = mark; surface?.needsDisplay = true
    }
    func end(_ point: CGPoint) {
        drag(point)
        if let draft { marks.append(draft); if draft.tool == .number { nextNumber += 1 } }
        draft = nil; surface?.needsDisplay = true
    }
}

private final class RecordingAnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class RecordingAnnotationSurface: NSView {
    private weak var owner: CaptureRecordingAnnotations?
    init(owner: CaptureRecordingAnnotations) { self.owner = owner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.begin(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { owner?.drag(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { owner?.end(convert(event.locationInWindow, from: nil)) }
    override func rightMouseDown(with event: NSEvent) { owner?.tool = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.tool = nil }
        else if event.modifierFlags.contains(.command), event.keyCode == 6 { owner?.undo() }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let owner, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        for mark in owner.marks + [owner.draft].compactMap({ $0 }) {
            context.saveGState()
            context.setStrokeColor(mark.color.cgColor); context.setFillColor(mark.color.cgColor)
            context.setLineWidth(mark.width); context.setLineCap(.round); context.setLineJoin(.round)
            context.setAlpha(mark.style.opacity)
            switch mark.tool {
            case .arrow: CaptureAnnotationRenderer.drawArrow(mark, in: context)
            case .number: CaptureAnnotationRenderer.drawNumber(mark, in: context)
            case .rectangle, .ellipse: context.addPath(CaptureAnnotationRenderer.shape(mark)); context.strokePath()
            default: context.addPath(CaptureAnnotationRenderer.path(mark)); context.strokePath()
            }
            context.restoreGState()
        }
    }
}

/// All actions stay in the recorder's pre-excluded popover surface.
struct RecordingAnnotationTools: View {
    @ObservedObject var annotations: CaptureRecordingAnnotations
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("录屏标注").fontWeight(.semibold)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("关闭标注工具")
            }
            HStack(spacing: 6) {
                toolButton(nil, symbol: "cursorarrow", label: "操作屏幕")
                ForEach([CaptureTool.arrow, .rectangle, .ellipse, .number, .pen, .highlight], id: \.self) { tool in
                    toolButton(tool, symbol: tool.symbol, label: tool.title)
                }
            }
            HStack(spacing: 6) {
                swatch(.red, title: "红色"); swatch(.blue, title: "蓝色")
                swatch(.yellow, title: "黄色"); swatch(.white, title: "白色")
                Divider().frame(height: 16)
                ForEach([2.0, 3.0, 5.0, 8.0], id: \.self) { value in
                    Button("\(Int(value))") { annotations.width = value }
                        .buttonStyle(.bordered).tint(annotations.width == value ? .accentColor : .secondary)
                        .accessibilityLabel("线宽 \(Int(value))")
                }
            }
            HStack {
                Button("撤销标注") { annotations.undo() }
                Button("清除标注") { annotations.clear() }
            }
            .buttonStyle(.bordered).disabled(annotations.marks.isEmpty)
        }
        .font(.system(size: 12)).controlSize(.small).padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .modifier(CaptureToolbarSurface())
    }

    private func toolButton(_ tool: CaptureTool?, symbol: String, label: String) -> some View {
        Button {
            close()
            annotations.tool = tool
        } label: {
            Image(systemName: symbol).frame(width: 30, height: 26)
        }
        .buttonStyle(.plain)
        .background(annotations.tool == tool ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(label).accessibilityAddTraits(annotations.tool == tool ? .isSelected : [])
    }

    private func swatch(_ color: Color, title: String) -> some View {
        Button { annotations.color = color } label: {
            Circle().fill(color).frame(width: 14, height: 14)
                .overlay { Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
                .padding(4)
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityAddTraits(annotations.color == color ? .isSelected : [])
    }
}
