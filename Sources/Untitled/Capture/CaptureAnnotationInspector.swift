import SwiftUI
import AppKit

struct CaptureAnnotationInspector<Editor: CaptureAnnotationEditing>: View {
    @ObservedObject var editor: Editor
    @ObservedObject var document: CaptureDocument
    var focusCaptionOnAppear = false
    @Environment(\.dismiss) private var dismiss
    @ViewState private var captionFocus: UUID?
    @ViewState private var contentHeight: CGFloat = 280
    private var tool: CaptureTool { editor.inspectorTool }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(tool.title)设置").font(.headline).padding(.bottom, 2)
                if [.text, .watermark].contains(tool) { caption }
                if showsColor { colorSettings }
                primaryParameter
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: CaptureInspectorHeightKey.self, value: geometry.size.height)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 340, height: min(contentHeight, 440))
        .background(CaptureInputWindowFocus().frame(width: 0, height: 0))
        .controlSize(.small)
        .buttonStyle(.bordered)
        .onPreferenceChange(CaptureInspectorHeightKey.self) { contentHeight = $0 }
        .onAppear { if focusCaptionOnAppear { captionFocus = UUID() } }
        .onChange(of: editor.captionFocusRequest) { _, _ in
            if [.arrow, .number, .text, .watermark].contains(tool) { captionFocus = UUID() }
        }
        .accessibilityIdentifier("capture.annotation.styles")
    }

    private var showsColor: Bool {
        if tool == .mosaic { return editor.style.mosaic == .solid }
        return [.arrow, .rectangle, .ellipse, .line, .pen, .highlight, .text, .number, .cover, .watermark].contains(tool)
    }

    private var colorSettings: some View {
        row("颜色") {
            HStack(spacing: 5) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, item in
                    Button { editor.color = item.color } label: {
                        Circle().fill(item.color).frame(width: 18, height: 18)
                            .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                    .accessibilityLabel(item.name)
                }
                Spacer(minLength: 0)
                CaptureCompactColorWell(color:$editor.color,owner:tool.rawValue).frame(width:22,height:24)
            }
        }
    }

    private var palette: [(name: String, color: Color)] {
        [("红色", .red), ("黄色", .yellow), ("绿色", .green), ("蓝色", .blue), ("白色", .white), ("黑色", .black)]
    }

    @ViewBuilder private var primaryParameter: some View {
        switch tool {
        case .arrow, .rectangle, .ellipse, .line, .pen, .highlight:
            slider("粗细", value: $editor.width, range: 1...30, display: "\(Int(editor.width))")
        case .text, .watermark, .number:
            slider("字号", value: binding(\.fontSize), range: 12...80, display: "\(Int(editor.style.fontSize))")
        case .mosaic:
            if editor.style.mosaic != .solid {
                slider("强度", value: binding(\.strength), range: 4...64, display: "\(Int(editor.style.strength))")
            }
        case .spotlight:
            slider("暗度", value: binding(\.dimming), range: 0.15...0.85, display: "\(Int(editor.style.dimming * 100))%")
        case .magnify:
            slider("放大", value: binding(\.magnification), range: 1.25...5, display: String(format: "%.1f×", editor.style.magnification))
        default: EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        switch tool {
        case .ellipse: ellipseSettings
        case .rectangle:
            option("填充", \.fill)
            option("线型", \.line)
            slider("圆角", value: binding(\.cornerRadius), range: 0...120, display: "\(Int(editor.style.cornerRadius))")
            opacity
        case .arrow:
            option("箭头", \.arrow)
            option("线型", \.line)
            caption
            if document.selectedMark?.control != nil {
                Button("恢复直线") { document.updateSelected { $0.control = nil } }
            } else {
                hint("拖动箭头中间的圆点可调整弧度。")
            }
        case .number: numberSettings
        case .mosaic:
            option("效果", \.mosaic)
            option("范围", \.coverage)
            if editor.style.coverage == .brush {
                slider("画笔", value: binding(\.brushSize), range: 8...120, display: "\(Int(editor.style.brushSize))")
            }
        case .text: textSettings
        case .line:
            Toggle("连续绘制折线", isOn: binding(\.polyline))
            option("线型", \.line)
            hint(editor.style.polyline ? "连续点击添加节点，双击或右键完成。" : "按住 ⇧ 可对齐 45°。")
        case .pen, .highlight:
            Toggle("平滑笔迹", isOn: binding(\.smooth))
            opacity
        case .spotlight:
            Toggle("椭圆聚光区域", isOn: binding(\.ellipse))
        case .watermark: watermarkSettings
        case .magnify:
            Toggle("旁置放大", isOn: binding(\.detachedMagnifier))
            Toggle("圆形放大区域", isOn: binding(\.ellipse))
        default: EmptyView()
        }
    }

    private var ellipseSettings: some View {
        Group {
            row("形状") {
                CaptureVisualStylePicker(title:"形状",value:Binding(get:{ editor.style.ellipseKind },set:{ kind in
                    var value=editor.style;value.ellipseKind=kind
                    if [.sector,.ringSector].contains(kind),value.arcSpan>=360 { value.arcSpan=270 }
                    editor.style=value
                }),width:76)
            }
            option("填充", \.fill)
            option("线型", \.line)
            if [.sector, .ringSector].contains(editor.style.ellipseKind) {
                slider("角度", value: binding(\.arcSpan), range: 5...360, display: "\(Int(editor.style.arcSpan))°")
            }
            if [.ring, .ringSector].contains(editor.style.ellipseKind) {
                slider("内径", value: binding(\.innerRatio), range: 0.05...0.95, display: "\(Int(editor.style.innerRatio * 100))%")
            }
        }
    }

    private var numberSettings: some View {
        Group {
            option("样式", \.number)
            option("编号", \.numberFormat)
            row("数值") {
                HStack {
                    Stepper(value: Binding(get: { document.selectedMark?.numberValue ?? editor.nextNumber }, set: { editor.setNumber($0) }), in: 0...9999) {
                        Text("\(document.selectedMark?.numberValue ?? editor.nextNumber)").monospacedDigit()
                    }
                    Button("从 1 开始") { document.selectedMarkID = nil; editor.nextNumberOverride = 1 }
                }
            }
            caption
        }
    }

    private var textSettings: some View {
        Group {
            row("字体") {
                Picker("字体", selection: Binding(get: { editor.style.fontName ?? "" }, set: {
                    var value = editor.style; value.fontName = $0.isEmpty ? nil : $0; editor.style = value
                })) {
                    Text("系统字体").tag("")
                    ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            row("字形") {
                HStack {
                    Toggle("粗体", isOn: binding(\.bold)).toggleStyle(.button)
                    Toggle("斜体", isOn: binding(\.italic)).toggleStyle(.button)
                    Spacer(minLength: 0)
                }
            }
            Toggle("文字背景", isOn: binding(\.textBackground))
            Toggle("文字描边", isOn: Binding(get: { editor.style.textOutline ?? false }, set: {
                var value = editor.style; value.textOutline = $0; editor.style = value
            }))
            Toggle("自动换行", isOn: Binding(get: { editor.style.textWrapWidth != nil }, set: {
                var value = editor.style; value.textWrapWidth = $0 ? 240 : nil; editor.style = value
            }))
            if let width = editor.style.textWrapWidth {
                slider("文本宽度", value: Binding(get: { editor.style.textWrapWidth ?? 240 }, set: {
                    var value = editor.style; value.textWrapWidth = $0; editor.style = value
                }), range: 40...1000, display: "\(Int(width))")
            }
            opacity
        }
    }

    private var watermarkSettings: some View {
        Group {
            Toggle("平铺水印", isOn: binding(\.watermarkTiled))
            slider("角度", value: Binding(get: { editor.style.rotation * 180 / .pi }, set: {
                var value = editor.style; value.rotation = $0 * .pi / 180; editor.style = value
            }), range: -90...90, display: "\(Int(editor.style.rotation * 180 / .pi))°")
            opacity
            hint("文字中可使用 {date} 和 {time} 插入日期与时间。")
        }
    }

    private var opacity: some View {
        slider("透明度", value: binding(\.opacity), range: 0.1...1, display: "\(Int(editor.style.opacity * 100))%")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([.text, .watermark].contains(tool) ? "文字内容" : "说明文字").foregroundStyle(.secondary)
            CaptureCaptionField(text: $editor.text,
                                placeholder: [.text, .watermark].contains(tool) ? "输入文字，回车后点击图片放置" : "可选",
                                focusRequest: captionFocus,
                                onSubmit: finishCaption, onCancel: finishCaption)
                .frame(height: 26)
        }
    }

    private func finishCaption() {
        captionFocus = nil
        dismiss()
        editor.focusCanvas()
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 24)
    }

    private func slider<Value: BinaryFloatingPoint>(_ label: String, value: Binding<Value>, range: ClosedRange<Value>, display: String) -> some View where Value.Stride: BinaryFloatingPoint {
        row(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, onEditingChanged: editor.styleEditing).accessibilityLabel(label)
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<CaptureMarkStyle, Value>) -> Binding<Value> {
        Binding(get: { editor.style[keyPath: key] }, set: {
            var value = editor.style; value[keyPath: key] = $0; editor.style = value
        })
    }

    private func option<Value: CaptureStyleOption & Hashable>(_ label: String, _ key: WritableKeyPath<CaptureMarkStyle, Value>) -> some View {
        row(label) { CaptureVisualStylePicker(title:label,value:binding(key),width:76) }
    }
}

/// Common properties stay in a compact second row. Text explanations and rare
/// parameters live behind the advanced control, not in the visual dropdown.
struct CaptureAnnotationStyleBar<Editor:CaptureAnnotationEditing>:View {
    @ObservedObject var editor:Editor
    @ObservedObject var document:CaptureDocument
    let advanced:()->Void
    @ViewState private var captionFocus:UUID?
    private var tool:CaptureTool { editor.inspectorTool }
    var body:some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:6) {
                parameters
                if CaptureStyleBarMetrics.showsColor(tool,style:editor.style) { colors }
                Button(action:advanced) { Image(systemName:"slider.horizontal.3").frame(width:28,height:28).contentShape(Rectangle()) }
                    .modifier(CaptureToolbarControl(hint:"更多样式"))
                    .accessibilityLabel("更多样式").panelRegion("capture.style.advanced")
            }.buttonStyle(.plain).font(.system(size:12)).fixedSize(horizontal:true,vertical:false)
                .padding(.horizontal,8).padding(.vertical,6)
        }.scrollBounceBehavior(.basedOnSize).frame(height:40)
            .modifier(CaptureToolbarSurface(cornerRadius:6)).disabled(!editor.allowsStyleEditing)
            .onAppear { if [.text,.watermark].contains(tool) { captionFocus=UUID() } }
            .onChange(of:editor.captionFocusRequest) { _,_ in if [.text,.watermark].contains(tool) { captionFocus=UUID() } }
            .accessibilityIdentifier("capture.annotation.stylebar")
    }
    @ViewBuilder private var parameters:some View {
        switch tool {
        case .rectangle,.ellipse:
            CaptureVisualStylePicker(title:"填充",value:binding(\.fill),width:34)
            CaptureVisualStylePicker(title:"线型",value:binding(\.line),width:64)
            width
            if tool == .rectangle { slider("圆角","rectangle.roundedtop",value:number(\.cornerRadius),range:0...120) }
            else { CaptureVisualStylePicker(title:"椭圆形状",value:binding(\.ellipseKind),width:34) }
        case .arrow:
            CaptureVisualStylePicker(title:"箭头样式",value:binding(\.arrow),width:60)
            CaptureVisualStylePicker(title:"线型",value:binding(\.line),width:64)
            width
        case .line:
            CaptureVisualStylePicker(title:"线型",value:binding(\.line),width:64)
            width
            toggle("折线","point.topleft.down.to.point.bottomright.curvepath",binding(\.polyline))
        case .pen,.highlight:
            width
            toggle("平滑笔迹","scribble.variable",binding(\.smooth))
            slider("透明度","circle.lefthalf.filled",value:binding(\.opacity),range:0.1...1,percent:true)
        case .text,.watermark:
            CaptureCaptionField(text:$editor.text,placeholder:"文字",focusRequest:captionFocus,
                onSubmit:finishCaption,onCancel:finishCaption).frame(width:148,height:26)
                .accessibilityLabel("文字内容")
            slider("字号","textformat.size",value:number(\.fontSize),range:12...80)
            if tool == .text {
                toggle("粗体","bold",binding(\.bold));toggle("斜体","italic",binding(\.italic))
            } else {
                toggle("平铺水印","square.grid.2x2",binding(\.watermarkTiled))
                slider("旋转角度","rotate.right",value:Binding(get:{ Double(editor.style.rotation)*180 / .pi },set:{ value in var s=editor.style;s.rotation=CGFloat(value * .pi/180);editor.style=s }),range:-90...90)
            }
        case .number:
            CaptureVisualStylePicker(title:"序号样式",value:binding(\.number),width:34)
            CaptureVisualStylePicker(title:"编号格式",value:binding(\.numberFormat),width:44)
            slider("编号","number",value:Binding(get:{ Double(document.selectedMark?.numberValue ?? editor.nextNumber) },set:{ editor.setNumber(Int($0.rounded())) }),range:0...9999)
            slider("字号","textformat.size",value:number(\.fontSize),range:12...80)
        case .mosaic:
            CaptureVisualStylePicker(title:"马赛克效果",value:binding(\.mosaic),width:34)
            CaptureVisualStylePicker(title:"作用范围",value:binding(\.coverage),width:34)
            if editor.style.mosaic != .solid { slider("强度","square.grid.3x3",value:number(\.strength),range:4...64) }
            if editor.style.coverage == .brush { slider("画笔大小","paintbrush",value:number(\.brushSize),range:8...120) }
        case .cover:
            slider("透明度","circle.lefthalf.filled",value:binding(\.opacity),range:0.1...1,percent:true)
        case .spotlight:
            toggle("椭圆聚光区域","circle",binding(\.ellipse))
            slider("周围暗度","circle.lefthalf.filled",value:binding(\.dimming),range:0.15...0.85,percent:true)
        case .magnify:
            toggle("圆形放大区域","circle",binding(\.ellipse))
            toggle("旁置放大","rectangle.on.rectangle",binding(\.detachedMagnifier))
            slider("放大倍率","plus.magnifyingglass",value:number(\.magnification),range:1.25...5)
        default:EmptyView()
        }
    }
    private var width:some View { slider("粗细","lineweight",value:$editor.width,range:1...30) }
    private var colors:some View {
        HStack(spacing:4) {
            ForEach(Array(CaptureStyleBarMetrics.palette.enumerated()),id:\.offset) { _,item in
                Button { editor.color=item.color } label: {
                    RoundedRectangle(cornerRadius:5).fill(item.color)
                        .overlay { RoundedRectangle(cornerRadius:5).strokeBorder(.primary.opacity(0.25),lineWidth:1) }
                        .padding(2).overlay { if sameColor(item.color) { RoundedRectangle(cornerRadius:6).strokeBorder(Color.accentColor,lineWidth:2) } }
                        .frame(width:20,height:26)
                }.modifier(CaptureToolbarControl(hint:item.name)).accessibilityLabel(item.name)
            }
            CaptureCompactColorWell(color:$editor.color,owner:tool.rawValue).frame(width:22,height:24).background(CaptureToolbarHelp("自定颜色"))
        }.frame(width:190,height:28)
    }
    private func sameColor(_ color:Color)->Bool {
        guard let a=NSColor(editor.color).usingColorSpace(.sRGB),let b=NSColor(color).usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)<0.02
    }
    private func toggle(_ title:String,_ symbol:String,_ value:Binding<Bool>)->some View {
        Button { value.wrappedValue.toggle() } label: { Image(systemName:symbol).frame(width:28,height:28).contentShape(Rectangle()) }
            .modifier(CaptureToolbarControl(hint:title,selected:value.wrappedValue)).accessibilityLabel(title)
    }
    private func slider(_ title:String,_ symbol:String,value:Binding<Double>,range:ClosedRange<Double>,percent:Bool=false)->some View {
        CaptureStyleSliderButton(title:title,symbol:symbol,value:value,range:range,percent:percent,editing:editor.styleEditing)
    }
    private func finishCaption() { captionFocus=nil;editor.focusCanvas() }
    private func binding<Value>(_ key:WritableKeyPath<CaptureMarkStyle,Value>)->Binding<Value> {
        Binding(get:{ editor.style[keyPath:key] },set:{ value in var s=editor.style;s[keyPath:key]=value;editor.style=s })
    }
    private func number(_ key:WritableKeyPath<CaptureMarkStyle,CGFloat>)->Binding<Double> {
        Binding(get:{ Double(editor.style[keyPath:key]) },set:{ value in guard value.isFinite else { return };var s=editor.style;s[keyPath:key]=CGFloat(value);editor.style=s })
    }
}

struct CaptureCompactColorWell:NSViewRepresentable {
    @Binding var color:Color
    let owner:String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->CaptureAnnotationColorWell {
        let view=CaptureAnnotationColorWell(frame:CGRect(x:0,y:0,width:22,height:24))
        view.target=context.coordinator;view.action=#selector(Coordinator.colorChanged(_:));return view
    }
    func updateNSView(_ view:CaptureAnnotationColorWell,context:Context) {
        context.coordinator.parent=self
        if view.owner != owner { view.closeOwnedPanel() }
        view.owner=owner;view.color=NSColor(color);view.isEnabled=enabled
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:CaptureAnnotationColorWell,context:Context)->CGSize? { CGSize(width:22,height:24) }
    static func dismantleNSView(_ view:CaptureAnnotationColorWell,coordinator:Coordinator) { view.closeOwnedPanel();view.target=nil;view.action=nil }
    @MainActor final class Coordinator:NSObject {
        var parent:CaptureCompactColorWell
        init(_ parent:CaptureCompactColorWell) { self.parent=parent }
        @objc func colorChanged(_ sender:NSColorWell) { parent.color=Color(nsColor:sender.color) }
    }
}

final class CaptureAnnotationColorWell:NSColorWell {
    var owner=""
    private var previousLevel:NSWindow.Level?
    override var intrinsicContentSize:NSSize { NSSize(width:22,height:24) }
    override var needsPanelToBecomeKey:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame);colorWellStyle = .minimal;supportsAlpha=true
        setAccessibilityLabel("自定颜色")
    }
    required init?(coder:NSCoder) { nil }
    override func activate(_ exclusive:Bool) {
        let panel=NSColorPanel.shared
        if previousLevel == nil { previousLevel=panel.level }
        panel.level=NSWindow.Level(rawValue:max(panel.level.rawValue,(window?.level.rawValue ?? 0)+1))
        super.activate(exclusive)
    }
    override func deactivate() {
        super.deactivate()
        if let previousLevel { NSColorPanel.shared.level=previousLevel;self.previousLevel=nil }
    }
    func closeOwnedPanel() { if isActive { NSColorPanel.shared.orderOut(nil) };deactivate() }
}

enum CaptureStyleBarMetrics {
    static let height:CGFloat=40
    static func frame(toolbar:CGRect,visible:CGRect,width requested:CGFloat,avoid:CGRect?=nil,flipped:Bool)->CGRect {
        let width=min(requested,max(80,visible.width-16))
        let x=min(max(toolbar.minX,visible.minX+8),max(visible.minX+8,visible.maxX-width-8))
        let below=flipped ? toolbar.maxY+6:toolbar.minY-height-6
        let above=flipped ? toolbar.minY-height-6:toolbar.maxY+6
        for y in [below,above] {
            let rect=CGRect(x:x,y:y,width:width,height:height)
            if visible.insetBy(dx:8,dy:8).contains(rect),avoid.map({ !$0.intersects(rect) }) ?? true { return rect }
        }
        return CGRect(x:x,y:min(max(below,visible.minY+8),max(visible.minY+8,visible.maxY-height-8)),width:width,height:height)
    }
    static let palette:[(name:String,color:Color)]=[("红色",.red),("橙色",.orange),("黄色",.yellow),("绿色",.green),("蓝色",.blue),("黑色",.black),("白色",.white)]
    static func showsColor(_ tool:CaptureTool,style:CaptureMarkStyle)->Bool {
        tool == .mosaic ? style.mosaic == .solid:[.arrow,.rectangle,.ellipse,.line,.pen,.highlight,.text,.watermark,.number,.cover].contains(tool)
    }
    static func width(tool:CaptureTool,style:CaptureMarkStyle)->CGFloat {
        var items:[CGFloat]
        switch tool {
        case .rectangle:items=[34,64,44,44]
        case .ellipse:items=[34,64,44,34]
        case .arrow:items=[60,64,44]
        case .line:items=[64,44,28]
        case .pen,.highlight:items=[44,28,44]
        case .text:items=[148,44,28,28]
        case .watermark:items=[148,44,28,44]
        case .number:items=[34,44,44,44]
        case .mosaic:items=[34,34];if style.mosaic != .solid { items.append(44) };if style.coverage == .brush { items.append(44) }
        case .cover:items=[44]
        case .spotlight:items=[28,44]
        case .magnify:items=[28,28,44]
        default:items=[]
        }
        if showsColor(tool,style:style) { items.append(190) }
        items.append(28)
        return items.reduce(0,+)+CGFloat(max(0,items.count-1))*6+16
    }
}

struct CaptureStyleSliderButton:View {
    let title:String
    let symbol:String
    @Binding var value:Double
    let range:ClosedRange<Double>
    var percent=false
    let editing:(Bool)->Void
    @ViewState private var showing=false
    private var label:String { percent ? "\(Int((value*100).rounded()))%":value<10 && value.rounded() != value ? String(format:"%.1f",value):String(Int(value.rounded())) }
    var body:some View {
        Button { showing.toggle() } label: {
            HStack(spacing:3) { Image(systemName:symbol).font(.system(size:11));Text(label).font(.system(size:11).monospacedDigit()) }
                .frame(width:44,height:28).contentShape(Rectangle())
        }.modifier(CaptureToolbarControl(hint:title,selected:showing)).accessibilityLabel(title)
            .popover(isPresented:$showing,arrowEdge:.bottom) {
                HStack(spacing:8) { Slider(value:$value,in:range,onEditingChanged:editing).frame(width:150);Text(label).monospacedDigit().frame(width:40) }.padding(12)
            }
    }
}

struct CaptureVisualStylePicker<Value:CaptureStyleOption & Hashable>:View {
    let title:String
    @Binding var value:Value
    var width:CGFloat=44
    @ViewState private var showing=false
    var body:some View {
        Button { showing.toggle() } label: {
            HStack(spacing:3) {
                CaptureStyleSample(option:value).frame(width:max(18,width-14),height:22)
                Image(systemName:"chevron.down").font(.system(size:8,weight:.semibold))
            }.frame(width:width,height:28).contentShape(Rectangle())
        }.modifier(CaptureToolbarControl(hint:title+" · "+value.title,selected:showing))
            .accessibilityLabel(title).accessibilityValue(value.title)
            .popover(isPresented:$showing,arrowEdge:.top) {
                CaptureVisualStyleOptions(value:$value,didChoose:{ showing=false })
            }
    }
}

enum CaptureStyleOptionMetrics {
    static let rowWidth:CGFloat=96,rowHeight:CGFloat=32,spacing:CGFloat=2,padding:CGFloat=6
    static func size(count:Int)->CGSize { CGSize(width:rowWidth+padding*2,height:CGFloat(count)*rowHeight+CGFloat(max(0,count-1))*spacing+padding*2) }
}

struct CaptureVisualStyleOptions<Value:CaptureStyleOption & Hashable>:View {
    @Binding var value:Value
    let didChoose:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:CaptureStyleOptionMetrics.spacing) {
            ForEach(Array(Value.allCases),id:\.self) { option in
                Button { value=option;didChoose() } label: {
                    HStack(spacing:8) {
                        CaptureStyleSample(option:option).frame(width:64,height:26)
                        Image(systemName:"checkmark").font(.system(size:10,weight:.semibold)).frame(width:12,height:16).opacity(option == value ? 1:0)
                    }.frame(width:CaptureStyleOptionMetrics.rowWidth,height:CaptureStyleOptionMetrics.rowHeight).contentShape(Rectangle())
                }.modifier(CaptureToolbarControl(hint:option.title,selected:option == value))
                    .accessibilityLabel(option.title).panelRegion("capture.style.option.\(option.rawValue)")
            }
        }.buttonStyle(.plain).padding(CaptureStyleOptionMetrics.padding).fixedSize()
            .accessibilityIdentifier("capture.style.options")
    }
}

/// Draw the result, not a prose description of it. Previews are tiny vector
/// paths; no source screenshot, model, image decoder or bitmap cache is used.
struct CaptureStyleSample:View {
    let option:any CaptureStyleOption
    var body:some View {
        Canvas { context,size in
            let r=CGRect(x:3,y:3,width:max(1,size.width-6),height:max(1,size.height-6))
            switch option {
            case let value as CaptureLinePattern:
                var path=Path();path.move(to:CGPoint(x:r.minX,y:r.midY));path.addLine(to:CGPoint(x:r.maxX,y:r.midY))
                context.stroke(path,with:.color(.primary),style:StrokeStyle(lineWidth:2,lineCap:.round,dash:value.lengths(2)))
            case let value as CaptureFill:
                let path=Path(roundedRect:r,cornerRadius:3)
                if value != .outline { context.fill(path,with:.color(.primary.opacity(value == .solid ? 1:0.25))) }
                context.stroke(path,with:.color(.primary),lineWidth:1.5)
            case let value as CaptureArrowStyle:drawArrow(value,in:r,context:&context)
            case let value as CaptureEllipseKind:
                if value == .ellipse || value == .ring { context.stroke(Path(ellipseIn:r),with:.color(.primary),lineWidth:value == .ring ? 5:1.5) }
                else {
                    var path=Path();let c=CGPoint(x:r.midX,y:r.midY),radius=min(r.width,r.height)/2
                    if value == .sector { path.move(to:c) }
                    path.addArc(center:c,radius:radius,startAngle:.degrees(-90),endAngle:.degrees(180),clockwise:false)
                    if value == .sector { path.closeSubpath();context.fill(path,with:.color(.primary)) }
                    else { context.stroke(path,with:.color(.primary),lineWidth:5) }
                }
            case let value as CaptureNumberStyle:
                let box=CGRect(x:r.midX-r.height/2,y:r.minY,width:r.height,height:r.height)
                let solid=value == .circle || value == .square
                let shape=value == .circle || value == .outlineCircle ? Path(ellipseIn:box):Path(roundedRect:box,cornerRadius:4)
                if value != .plain { if solid { context.fill(shape,with:.color(.primary)) } else { context.stroke(shape,with:.color(.primary),lineWidth:1.5) } }
                context.draw(Text("1").font(.system(size:14,weight:.semibold)).foregroundColor(solid ? Color(nsColor:.windowBackgroundColor):.primary),at:CGPoint(x:r.midX,y:r.midY))
            case let value as CaptureNumberFormat:
                context.draw(Text(value.label(1)).font(.system(size:16,weight:.medium)),at:CGPoint(x:r.midX,y:r.midY))
            case let value as CaptureMosaicMode:
                if value == .solid { context.fill(Path(roundedRect:r,cornerRadius:2),with:.color(.primary)) }
                else {
                    if value == .blur { context.addFilter(.blur(radius:2.5)) }
                    let side:CGFloat=5
                    for y in 0..<4 { for x in 0..<12 {
                        let cell=CGRect(x:r.minX+CGFloat(x)*side,y:r.minY+CGFloat(y)*side,width:side,height:side).intersection(r)
                        if !cell.isNull { context.fill(Path(cell),with:.color((x+y).isMultiple(of:2) ? .primary.opacity(0.7):.secondary.opacity(0.25))) }
                    } }
                }
            case let value as CaptureCoverage:
                if value == .rectangle { context.stroke(Path(roundedRect:r,cornerRadius:2),with:.color(.primary),lineWidth:1.5) }
                else { var p=Path();p.move(to:CGPoint(x:r.minX,y:r.midY));p.addCurve(to:CGPoint(x:r.maxX,y:r.midY),control1:CGPoint(x:r.midX,y:r.minY-5),control2:CGPoint(x:r.midX,y:r.maxY+5));context.stroke(p,with:.color(.primary),style:StrokeStyle(lineWidth:4,lineCap:.round)) }
            default:break
            }
        }.accessibilityHidden(true)
    }
    private func drawArrow(_ style:CaptureArrowStyle,in r:CGRect,context:inout GraphicsContext) {
        let a=CGPoint(x:r.minX,y:r.midY),b=CGPoint(x:r.maxX,y:r.midY),head=min(7,r.width*0.3)
        var shaft=Path();shaft.move(to:a);shaft.addLine(to:b)
        if style == .tapered || style == .taperedOutline {
            var p=Path();p.move(to:CGPoint(x:a.x,y:a.y-1));p.addLine(to:CGPoint(x:b.x-head,y:b.y-3));p.addLine(to:CGPoint(x:b.x-head,y:b.y-6));p.addLine(to:b);p.addLine(to:CGPoint(x:b.x-head,y:b.y+6));p.addLine(to:CGPoint(x:b.x-head,y:b.y+3));p.addLine(to:CGPoint(x:a.x,y:a.y+1));p.closeSubpath()
            if style == .tapered { context.fill(p,with:.color(.primary)) } else { context.stroke(p,with:.color(.primary),lineWidth:1.5) };return
        }
        context.stroke(shaft,with:.color(.primary),lineWidth:1.5)
        func headPath(_ at:CGPoint,_ direction:CGFloat)->Path {
            var p=Path();p.move(to:CGPoint(x:at.x-direction*head,y:at.y-5));p.addLine(to:at);p.addLine(to:CGPoint(x:at.x-direction*head,y:at.y+5));return p
        }
        if style == .dimension {
            var ticks=Path();for x in [a.x,b.x] { ticks.move(to:CGPoint(x:x,y:a.y-7));ticks.addLine(to:CGPoint(x:x,y:a.y+7)) };context.stroke(ticks,with:.color(.primary),lineWidth:1)
        }
        var end=headPath(b,1)
        if style == .open || style == .dimension { context.stroke(end,with:.color(.primary),lineWidth:1.5) }
        else { end.closeSubpath();context.fill(end,with:.color(.primary)) }
        if style == .double || style == .dimension { context.stroke(headPath(a,-1),with:.color(.primary),lineWidth:1.5) }
    }
}

private struct CaptureInspectorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 280
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A native field explicitly opts into keyboard focus in a nonactivating panel.
/// SwiftUI's hosting view does not opt in, and its initial FocusState update can
/// occur before a popover has an NSWindow to receive the field editor.
struct CaptureCaptionField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusRequest: UUID?
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CaptureCaptionTextField {
        let field = CaptureCaptionTextField(string: text)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.controlSize = .small
        field.usesSingleLineMode = true
        field.setAccessibilityIdentifier("capture.annotation.text")
        return field
    }
    func updateNSView(_ field: CaptureCaptionTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        // Never replace an input method's marked text during a SwiftUI refresh.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        field.requestFocus(focusRequest)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptureCaptionField
        init(_ parent: CaptureCaptionField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Return/Escape belong to the input method while composing Chinese.
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit(); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel(); return true
            }
            return false
        }
    }
}

final class CaptureCaptionTextField: NSTextField {
    private var pendingFocus: UUID?
    private var appliedFocus: UUID?
    private var focusScheduled = false
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFocus()
    }
    func requestFocus(_ request: UUID?) {
        pendingFocus = request
        scheduleFocus()
    }
    private func scheduleFocus() {
        guard let pendingFocus, pendingFocus != appliedFocus, window != nil, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard let request = self.pendingFocus, request != self.appliedFocus, let window = self.window else { return }
            window.makeKey()
            if window.makeFirstResponder(self) {
                self.appliedFocus = request
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}
