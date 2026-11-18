import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor protocol CaptureAnnotationEditing: ObservableObject {
    var tool:CaptureTool { get }
    var allowsStyleEditing:Bool { get }
    var color: Color { get set }
    var width: Double { get set }
    var text: String { get set }
    var style: CaptureMarkStyle { get set }
    var inspectorTool: CaptureTool { get }
    var nextNumber: Int { get }
    var nextNumberOverride: Int? { get set }
    var captionFocusRequest: UUID { get }
    func setNumber(_ value: Int)
    func styleEditing(_ editing: Bool)
    func focusCanvas()
}

@MainActor struct CaptureSelectionExport {
    let image: CGImage
    let base: CGImage
    let marks: [CaptureMark]
}
typealias CaptureSelectionOutputHandler = @MainActor (CaptureSelectionExport, CaptureSelectionPostAction, CGRect, URL?) async throws -> Bool

/// One frozen source, one current viewport and one in-flight output. Marks use
/// source pixels so moving/resizing a crop never resamples or rescales them.
@MainActor final class CaptureSelectionSession: ObservableObject, CaptureAnnotationEditing {
    let document: CaptureDocument
    let allowsAnnotations: Bool
    weak var view: CaptureSelectionView?
    @Published var hasSelection = false
    @Published var sizeLabel = ""
    @Published var mode: CaptureSelectionView.Shape = .rectangle
    @Published var pendingMode: CaptureSelectionView.Shape = .rectangle
    @Published var choosingMode = false
    @Published var toolbarHidden = false
    @Published var stylesPresented = false
    @Published var exporting = false
    @Published var error: String?
    @Published var captionFocusRequest = UUID()
    @Published var tool: CaptureTool = .move {
        didSet {
            guard tool != oldValue else { return }
            document.finishMarkEdit(); document.selectedMarkID = nil
            synchronizing = true
            style = toolStyles[tool.rawValue] ?? CaptureMarkStyle()
            synchronizing = false
            stylesPresented = false
            if [.text,.watermark].contains(tool) { captionFocusRequest=UUID() }
            view?.configureAnnotationCanvas()
        }
    }
    @Published var color = Color.red { didSet { updateSelected { $0.color = NSColor(color) }; view?.configureAnnotationCanvas() } }
    @Published var width: Double = 3 { didSet { updateSelected { $0.width = width }; view?.configureAnnotationCanvas() } }
    @Published var text = "" { didSet { updateSelected { if $0.tool == .number { $0.caption = text } else { $0.text = text } }; view?.configureAnnotationCanvas() } }
    @Published var style = CaptureMarkStyle() {
        didSet {
            guard !synchronizing else { return }
            toolStyles[inspectorTool.rawValue] = style
            defaults.set(try? JSONEncoder().encode(toolStyles), forKey: "capture.annotation.styles")
            updateSelected { $0.style = style }; view?.configureAnnotationCanvas()
        }
    }
    @Published var nextNumberOverride: Int?
    var inspectorTool: CaptureTool { document.selectedMark?.tool ?? tool }
    var allowsStyleEditing:Bool { !exporting && !stopped }
    var nextNumber: Int { nextNumberOverride ?? document.nextNumber(format: style.numberFormat) }
    private let defaults: UserDefaults
    private var toolStyles: [String: CaptureMarkStyle] = [:]
    private var synchronizing = false
    private var subscriptions = Set<AnyCancellable>()
    private var outputTask: Task<Void, Never>?
    private var savePanel: NSSavePanel?
    var chooseSaveDestination: (@MainActor (CGImage) async -> URL?)?
    private(set) var stopped = false

    init(image: CGImage, allowsAnnotations: Bool, defaults: UserDefaults = .standard) {
        document = CaptureDocument(image: image, copyDefaults: defaults)
        self.allowsAnnotations = allowsAnnotations; self.defaults = defaults
        toolStyles = defaults.data(forKey: "capture.annotation.styles").flatMap { try? JSONDecoder().decode([String: CaptureMarkStyle].self, from: $0) } ?? [:]
        document.$image.dropFirst().sink { [weak self] image in
            self?.view?.configureAnnotationCanvas(image:image); self?.view?.needsDisplay = true
        }.store(in: &subscriptions)
        document.$selectedMarkID.dropFirst().receive(on:RunLoop.main).sink { [weak self] id in
            guard let self else { return }
            if let mark = document.marks.first(where: { $0.id == id }) {
                synchronizing = true
                color = Color(nsColor: mark.color); width = mark.width; style = mark.style
                text = mark.tool == .number ? mark.caption : mark.text
                synchronizing = false
            }
            view?.configureAnnotationCanvas()
        }.store(in: &subscriptions)
    }
    func updateSelection(_ rect: CGRect?, scale: CGFloat, confirmed: Bool) {
        let available=confirmed && rect != nil
        if hasSelection != available { hasSelection=available }
        guard let rect, confirmed else { view?.configureAnnotationCanvas(); return }
        do {
            try document.setCaptureViewport(CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
            if let pixels=document.captureViewport { sizeLabel="\(Int(pixels.width)) × \(Int(pixels.height))" }
        }
        catch { self.error = error.localizedDescription }
        view?.configureAnnotationCanvas()
    }
    private func updateSelected(_ action: (inout CaptureMark) -> Void) {
        guard !synchronizing, var mark = document.selectedMark else { return }
        action(&mark)
        if document.isEditingMark { document.previewMark(mark) } else { document.replaceMark(mark) }
    }
    func setNumber(_ value: Int) {
        if document.selectedMark?.tool == .number { document.updateSelected { $0.numberValue = value } }
        else { nextNumberOverride = value }
    }
    func styleEditing(_ editing: Bool) {
        if editing, let id = document.selectedMarkID { document.beginMarkEdit(id) }
        else if !editing { document.finishMarkEdit() }
    }
    func focusCanvas() { view?.window?.makeKey(); view?.window?.makeFirstResponder(view) }
    func editCaption(_ id: UUID) { document.selectedMarkID = id;stylesPresented=false;captionFocusRequest=UUID();view?.positionSessionControls() }
    func addMark(_ mark: CaptureMark) {
        guard document.marks.count < 10_000 else { error = "本次标注已达上限，请先完成截图。"; return }
        document.add(mark); nextNumberOverride = nil
        if [.text, .watermark].contains(mark.tool) { editCaption(mark.id) }
    }
    func selectTool(_ next: CaptureTool,toggleIfSelected:Bool=true) {
        if [.erase, .inpaint].contains(next) { view?.initialTool = next; submit(.edit); return }
        if next.isDefaultInteraction || next == .crop { tool = .move }
        else { tool = toggleIfSelected && next == tool ? .move:next }
    }
    func perform(_ action: CaptureShortcutAction) {
        guard !stopped, !exporting else { return }
        if let next = action.tool { selectTool(next); return }
        switch action {
        case .copy, .copyAndClose: submit(.copy)
        case .pin: submit(.pin)
        case .save: submit(.save)
        case .quickSave: submit(.quickSave)
        case .undo: document.undo()
        case .redo: document.redo()
        case .clearMarks: document.clearMarks()
        case .hideToolbar: toolbarHidden.toggle(); view?.positionSessionControls()
        case .close:
            if view?.cancelAnnotationDraft() == true { return }
            if !tool.isDefaultInteraction { tool = .move }
            else if document.selectedMarkID != nil { document.selectedMarkID = nil }
            else { view?.resetCaptureSelection() }
        case .ocr: submit(.ocr)
        case .translation, .document, .table, .formula, .autoMosaic, .printImage:
            view?.initialAction=action;submit(.edit)
        default: break
        }
    }
    func submit(_ action: CaptureSelectionPostAction) {
        guard hasSelection, !exporting, !stopped, let view else { return }
        if !allowsAnnotations { view.confirmCaptureRange(); return }
        if view.outputHandler == nil || action == .edit {
            do { document.finishMarkEdit();view.completeCaptureOutput(try view.prepareSelectionExport(),action:action,handled:false) }
            catch { self.error=error.localizedDescription }
            return
        }
        exporting = true; stylesPresented = false; error = nil
        outputTask = Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            defer { exporting = false; outputTask = nil }
            do {
                document.finishMarkEdit()
                let output = try view.prepareSelectionExport()
                var target: URL?
                if action == .save, view.outputHandler != nil {
                    if let chooseSaveDestination { target = await chooseSaveDestination(output.image) }
                    else { target = await chooseSaveURL(image: output.image) }
                    guard target != nil else { return }
                }
                try Task.checkCancellation()
                guard !stopped else { return }
                let handled: Bool
                if action == .edit { handled = false }
                else if let handler = view.outputHandler {
                    guard try await handler(output, action, view.selectionPresentationFrame, target) else { return }
                    handled = true
                } else { handled = false }
                try Task.checkCancellation()
                guard !stopped else { return }
                view.completeCaptureOutput(output, action: action, handled: handled)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func chooseSaveURL(image: CGImage) async -> URL? {
        let panel = NSSavePanel(); savePanel = panel
        CaptureWindowPolicy.markControl(panel, name: "captureSave")
        panel.level = NSWindow.Level(rawValue: (view?.window?.level.rawValue ?? NSWindow.Level.screenSaver.rawValue) + 2)
        panel.allowedContentTypes = CaptureOutputPreferences.supportedFormats.compactMap { UTType(filenameExtension: $0) } + [.pdf]
        panel.nameFieldStringValue = CaptureOutputPreferences.filename(width: image.width, height: image.height) + "." + CaptureOutputPreferences.format
        panel.directoryURL = CaptureOutputPreferences.directory
        let result: URL? = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
        savePanel = nil
        return result
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        outputTask?.cancel(); outputTask = nil; savePanel?.cancel(nil); savePanel = nil
        subscriptions.removeAll(); stylesPresented = false
    }
}

struct CaptureSelectionInfoBar: View {
    @ObservedObject var session: CaptureSelectionSession
    var body: some View {
        HStack(spacing: 8) {
            Button { session.view?.showSelectionDetails() } label: {
                Text(session.sizeLabel).monospacedDigit().font(.system(size: 11))
            }.frame(height: 22).modifier(CaptureToolbarControl(hint: "位置与尺寸；点击精确调整"))
            Button { session.view?.showSelectionAppearance() } label: { Image(systemName: "square.dashed").frame(width: 22, height: 22).contentShape(Rectangle()) }.modifier(CaptureToolbarControl(hint: "圆角、阴影与边框"))
            Menu {
                ForEach(CaptureSelectionView.Shape.allCases, id: \.rawValue) { shape in
                    Button(shape.title) { session.view?.setCaptureShape(shape) }
                }
                if session.mode != .rectangle {
                    Divider()
                    Button("替换区域") { session.view?.setCaptureOperation(0) }
                    Button("增加区域") { session.view?.setCaptureOperation(1) }
                    Button("扣除区域") { session.view?.setCaptureOperation(2) }
                }
                Divider()
                Button("重新框选") { session.view?.resetCaptureSelection() }
                Button("刷新画面") { session.view?.refreshCaptureImage() }
            } label: { Image(systemName: session.mode.symbol).frame(width: 22, height: 22) }.menuStyle(.button).menuIndicator(.hidden).frame(width: 22, height: 22)
            .modifier(CaptureToolbarControl(hint: "\(session.mode.title) · ⌃Tab 切换截图模式"))
        }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
            .modifier(CaptureToolbarSurface(cornerRadius: 6))
            .accessibilityIdentifier("capture.selection.info")
    }
}

enum CaptureSelectionToolbarMetrics {
    static let itemSide: CGFloat = 28
    static let spacing: CGFloat = 2
    static let groupSpacing: CGFloat = 8
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 6
    static let height = itemSide + verticalInset * 2
    static func groupWidth(_ count: Int) -> CGFloat { CGFloat(count) * itemSide + CGFloat(max(0, count - 1)) * spacing }
    static func toolsWidth(_ groups:[CaptureToolGroup]) -> CGFloat { CaptureToolbarPreferences.toolsWidth(groups) }
    static func width(allowsAnnotations: Bool) -> CGFloat {
        guard allowsAnnotations else { return 80 + itemSide + groupSpacing + horizontalInset * 2 }
        return toolsWidth(CaptureToolGroup.allCases) + groupWidth(3) + groupWidth(5)
            + groupSpacing * 4 + 2 + horizontalInset * 2
    }
}

struct CaptureSelectionToolbar: View {
    @ObservedObject var session: CaptureSelectionSession
    @ObservedObject var document: CaptureDocument
    @ObservedObject private var shortcuts = CaptureShortcutSettings.shared
    @AppStorage("capture.toolbarOrder") private var toolbarOrder = ""
    @ViewState private var toolbarSettings = false
    var tools: [CaptureTool] { CaptureToolbarPreferences.ordered(toolbarOrder) }
    var groups: [CaptureToolGroup] { CaptureToolbarPreferences.groups(toolbarOrder) }
    var body: some View {
        HStack(spacing: CaptureSelectionToolbarMetrics.groupSpacing) {
            if session.allowsAnnotations {
                toolStrip
                separator
                editingActions.fixedSize()
                separator
                outputActions.fixedSize()
            } else {
                Button { session.view?.confirmCaptureRange() } label: {
                    Text("确认范围").frame(width: 80, height: CaptureSelectionToolbarMetrics.itemSide).contentShape(Rectangle())
                }.modifier(CaptureToolbarControl(hint: "确认录屏或长截图范围（Return）"))
                action("xmark", title: "取消截图", id: "close", shortcut: .close) { session.view?.cancelCapture() }
            }
        }
        .frame(height: CaptureSelectionToolbarMetrics.itemSide)
        .buttonStyle(.plain).font(.system(size: 13))
        .padding(.horizontal, CaptureSelectionToolbarMetrics.horizontalInset)
        .padding(.vertical, CaptureSelectionToolbarMetrics.verticalInset)
        .contentShape(Rectangle())
        .disabled(session.exporting)
        .modifier(CaptureToolbarSurface())
        .popover(isPresented: $session.stylesPresented) {
            CaptureAnnotationInspector(editor: session, document: document, focusCaptionOnAppear: [.text, .watermark].contains(session.tool))
        }
        .sheet(isPresented: $toolbarSettings) { CaptureToolbarSettingsView() }
        .background {
            if session.hasSelection && session.allowsAnnotations {
                CaptureShortcutMonitor(scope: .editor, handle: session.perform).frame(width: 0, height: 0)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("好") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .accessibilityIdentifier("capture.selection.toolbar")
    }
    private var toolStrip: some View {
        CaptureExpandedToolStrip(groups:groups,active:session.tool,order:toolbarOrder,prefix:"capture.selection",select:{ session.selectTool($0,toggleIfSelected:$1) })
    }
    private var separator: some View { Divider().frame(width: 1, height: 18) }
    private var editingActions: some View {
        HStack(spacing: CaptureSelectionToolbarMetrics.spacing) {
            action("arrow.uturn.forward",title:"重做标注",id:"redo",shortcut:.redo) { document.redo() }.disabled(document.redoCount == 0)
            action("arrow.uturn.backward", title: document.undoCount == 0 ? "没有可撤销的标注" : "撤销标注", id: "undo", shortcut: .undo) { document.undo() }
                .disabled(document.undoCount == 0)
            Menu {
                Button("工具顺序") { toolbarSettings = true }
                Button("更多样式…") { session.stylesPresented = true }.disabled(!canShowStyles)
                Button("清除标注") { document.clearMarks() }.disabled(document.marks.isEmpty)
                Button("在独立图片编辑器中继续…") { session.submit(.edit) }
            } label: { CaptureToolbarMoreIcon() }
            .menuStyle(.button).menuIndicator(.hidden)
            .frame(width: CaptureSelectionToolbarMetrics.itemSide, height: CaptureSelectionToolbarMetrics.itemSide)
            .modifier(CaptureToolbarControl(hint: "工具顺序与更多操作"))
            .accessibilityLabel("更多操作").panelRegion("capture.selection.action.more")
        }
    }
    private var outputActions: some View {
        HStack(spacing: CaptureSelectionToolbarMetrics.spacing) {
            action("text.viewfinder", title: "识别文字并复制", id: "ocr", shortcut: .ocr) { session.submit(.ocr) }
            action("pin", title: "贴图", id: "pin", shortcut: .pin) { session.submit(.pin) }
            action("square.and.arrow.down", title: "保存", id: "save", shortcut: .save) { session.submit(.save) }
            action("doc.on.doc", title: "复制并结束截图", id: "copy", shortcut: .copy) { session.submit(.copy) }
            action("xmark", title: "取消截图", id: "close", shortcut: .close) { session.view?.cancelCapture() }
        }.panelRegion("capture.selection.outputs")
    }
    private var canShowStyles: Bool { session.inspectorTool.hasAnnotationStyle }
    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: CaptureSelectionToolbarMetrics.itemSide, height: CaptureSelectionToolbarMetrics.itemSide)
            .contentShape(Rectangle())
    }
    private func hint(_ title: String, shortcut: CaptureShortcutAction?) -> String {
        title + (shortcut.flatMap { shortcuts.binding($0) }.map { "（\($0.display)）" } ?? "")
    }
    private func action(_ symbol: String, title: String, id: String, shortcut: CaptureShortcutAction? = nil, selected: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { icon(symbol) }
            .modifier(CaptureToolbarControl(hint: hint(title, shortcut: shortcut), selected: selected, prominent: id == "copy"))
            .accessibilityLabel(title).panelRegion("capture.selection.action.\(id)")
    }
}

struct CaptureSelectionModePalette: View {
    @ObservedObject var session: CaptureSelectionSession
    var body: some View {
        HStack(spacing: 16) {
            ForEach(CaptureSelectionView.Shape.allCases, id: \.rawValue) { shape in
                Button { session.view?.setCaptureShape(shape); session.choosingMode = false } label: {
                    VStack(spacing: 7) { Image(systemName: shape.symbol).font(.system(size: 22)); Text(shape.title).font(.caption) }
                        .frame(width: 74, height: 58)
                        .contentShape(Rectangle())
                }.modifier(CaptureToolbarControl(hint: shape.title + " · ⌃Tab 切换模式", selected: session.pendingMode == shape))
            }
        }.buttonStyle(.plain).padding(12).modifier(CaptureToolbarSurface())
            .accessibilityIdentifier("capture.selection.modes")
    }
}
