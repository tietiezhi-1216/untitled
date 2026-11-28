import SwiftUI
import UntitledHost

enum CaptureToolbarPreferences {
    static let defaults: [CaptureTool] = [.move,.select,.arrow,.rectangle,.ellipse,.line,.pen,.highlight,.text,.number,.mosaic,.cover,.deleteMarks,.erase,.inpaint,.spotlight,.magnify,.watermark,.crop]
    static func ordered(_ value: String) -> [CaptureTool] {
        guard let data = value.data(using: .utf8), let items = try? JSONDecoder().decode([CaptureTool].self, from: data) else { return defaults }
        var seen = Set<CaptureTool>()
        // Earlier versions allowed hidden tools. Keep their order, but show every tool now.
        return (items + defaults).filter { seen.insert($0).inserted }
    }
    static func encoded(_ items: [CaptureTool]) -> String { String(data: (try? JSONEncoder().encode(items)) ?? Data(), encoding: .utf8) ?? "" }
    static func groups(_ value:String)->[CaptureToolGroup] {
        guard let data=value.data(using:.utf8),let decoded=try? JSONDecoder().decode([CaptureTool].self,from:data),!decoded.isEmpty else { return CaptureToolGroup.allCases }
        var seen=Set<CaptureToolGroup>()
        return ordered(value).compactMap(CaptureToolGroup.group).filter { seen.insert($0).inserted }
    }
    static func members(_ group:CaptureToolGroup,order:String)->[CaptureTool] { ordered(order).filter { group.members.contains($0) } }
    static let groupSpacing:CGFloat=8
    static func expandedTools(_ order:String)->[CaptureTool] { groups(order).flatMap { members($0,order:order) } }
    static func toolsWidth(_ groups:[CaptureToolGroup])->CGFloat { groups.reduce(0) { $0+$1.width }+CGFloat(max(0,groups.count-1))*groupSpacing }
    static func reordered(_ groups:[CaptureToolGroup],preserving value:String)->[CaptureTool] {
        let previous=ordered(value)
        return groups.flatMap { group in previous.filter { group.members.contains($0) } } + previous.filter { CaptureToolGroup.group($0) == nil }
    }
}

enum CaptureToolGroup:String,CaseIterable,Identifiable {
    case shapes,drawing,lines,text,number,obscure,erasing,effects
    var id:String { rawValue }
    var members:[CaptureTool] {
        switch self {
        case .shapes:[.rectangle,.ellipse]
        case .drawing:[.pen,.highlight]
        case .lines:[.arrow,.line]
        case .text:[.text,.watermark]
        case .number:[.number]
        case .obscure:[.mosaic,.cover]
        case .erasing:[.deleteMarks,.erase,.inpaint]
        case .effects:[.spotlight,.magnify]
        }
    }
    var title:String {
        switch self { case .shapes:"形状";case .drawing:"画笔";case .lines:"箭头与线条";case .text:"文字";case .number:"序号";case .obscure:"马赛克与遮挡";case .erasing:"擦除与修补";case .effects:"聚光与放大" }
    }
    var width:CGFloat { CGFloat(members.count)*28+CGFloat(max(0,members.count-1))*2 }
    static func group(_ tool:CaptureTool)->Self? { allCases.first { $0.members.contains(tool) } }
}

/// All tools are direct buttons. Grouping controls adjacency only, never which
/// tools are visible; earlier groupChoices preferences are deliberately untouched.
struct CaptureExpandedToolGroup:View {
    let group:CaptureToolGroup
    let active:CaptureTool
    let order:String
    let prefix:String
    let select:(CaptureTool,Bool)->Void
    @ObservedObject private var shortcuts=CaptureShortcutSettings.shared
    var body:some View {
        HStack(spacing:2) {
            ForEach(CaptureToolbarPreferences.members(group,order:order)) { tool in
                Button { select(tool,true) } label: {
                    CaptureToolGlyph(tool:tool).frame(width:28,height:28).contentShape(Rectangle())
                }
                .modifier(CaptureToolbarControl(hint:hint(tool),selected:active == tool))
                .accessibilityLabel(tool.title).panelRegion("\(prefix).tool.\(tool.rawValue)").id(tool)
            }
        }.frame(width:group.width,height:28).panelRegion("\(prefix).group.\(group.rawValue)")
    }
    private func hint(_ tool:CaptureTool)->String {
        let shortcut=CaptureShortcutAction.allCases.first { $0.tool == tool }.flatMap { shortcuts.binding($0) }
        return tool.title+(shortcut.map { "（\($0.display)）" } ?? "")
    }
}

struct CaptureExpandedToolStrip:View {
    let groups:[CaptureToolGroup]
    let active:CaptureTool
    let order:String
    let prefix:String
    let select:(CaptureTool,Bool)->Void
    var body:some View {
        GeometryReader { geometry in
            let overflow=geometry.size.width+0.5<CaptureToolbarPreferences.toolsWidth(groups)
            ScrollViewReader { proxy in
                HStack(spacing:0) {
                    if overflow { scrollButton("chevron.left",hint:"滚动至工具栏开头") { if let first=groups.first { proxy.scrollTo(CaptureToolbarPreferences.members(first,order:order)[0],anchor:.leading) } } }
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:CaptureToolbarPreferences.groupSpacing) {
                            ForEach(groups) { group in
                                CaptureExpandedToolGroup(group:group,active:active,order:order,prefix:prefix,select:select)
                            }
                        }.fixedSize()
                    }
                    .scrollBounceBehavior(.basedOnSize).scrollContentBackground(.hidden)
                    .onChange(of:active) { _,tool in if CaptureToolGroup.group(tool) != nil { proxy.scrollTo(tool,anchor:.center) } }
                    if overflow { scrollButton("chevron.right",hint:"滚动至工具栏末尾") { if let last=groups.last,let tool=CaptureToolbarPreferences.members(last,order:order).last { proxy.scrollTo(tool,anchor:.trailing) } } }
                }
            }
        }.frame(height:28).panelRegion("\(prefix).tools")
    }
    private func scrollButton(_ symbol:String,hint:String,perform:@escaping ()->Void)->some View {
        Button(action:perform) { Image(systemName:symbol).font(.system(size:9,weight:.semibold)).frame(width:14,height:28).contentShape(Rectangle()) }
            .modifier(CaptureToolbarControl(hint:hint)).accessibilityLabel(hint)
    }
}

struct CaptureToolGlyph:View {
    let tool:CaptureTool
    var body:some View {
        if tool == .text { Text("T").font(.system(size:16,weight:.medium,design:.serif)) }
        else { Image(systemName:tool == .pen ? "pencil":tool.symbol) }
    }
}

struct CaptureToolbarSettingsView: View {
    @AppStorage("capture.toolbarOrder") private var order = ""
    @Environment(\.dismiss) private var dismiss
    var groups: [CaptureToolGroup] { CaptureToolbarPreferences.groups(order) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("工具顺序").font(.headline); Spacer(); Button("完成") { dismiss() } }
            Text("拖动调整分组顺序；同类工具全部展开，组内保留原工具顺序。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(groups) { group in
                    Label(group.title, systemImage: group.members[0].symbol)
                }.onMove { from, to in
                    var value=groups;value.move(fromOffsets:from,toOffset:to)
                    save(CaptureToolbarPreferences.reordered(value,preserving:order))
                }
            }
            HStack {
                Spacer(); Button("恢复默认") { order = "" }
            }
        }.padding(18).frame(width: 360, height: 480)
    }
    private func save(_ value: [CaptureTool]) { order = CaptureToolbarPreferences.encoded(value) }
}
