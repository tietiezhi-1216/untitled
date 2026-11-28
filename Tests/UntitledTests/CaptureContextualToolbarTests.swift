import AppKit
import SwiftUI
import Testing
@preconcurrency import ScreenCaptureKit
@testable import Untitled

@Suite(.serialized) @MainActor
struct CaptureContextualToolbarTests {
    @Test(arguments:[1,2]) func defaultInteractionMovesAMarkWithoutMovingOrResizingTheCapture(factor:Int) async throws {
        let fixture=try Fixture(factor:factor);defer { fixture.close() }
        try fixture.selectRange()
        let view=fixture.view,document=view.session.document
        let mark=CaptureMark(tool:.cover,points:[CGPoint(x:100*factor,y:100*factor),CGPoint(x:180*factor,y:150*factor)],color:.blue,width:2)
        document.add(mark);await settle()
        let range=view.selected,frame=fixture.panel.frame
        let canvas=try #require(fixture.canvas)
        #expect(view.session.tool == .move && !canvas.isHidden)
        let start=CGPoint(x:130,y:120),end=CGPoint(x:160,y:145)
        #expect(view.hitTest(view.convert(start,to:view.superview)) === canvas)
        try fixture.drag(from:start,to:end,target:canvas)
        #expect(view.selected == range && fixture.panel.frame == frame && view.session.tool == .move)
        let moved=try #require(document.marks.first)
        #expect(moved.id == mark.id)
        #expect(moved.points[0] == CGPoint(x:130*factor,y:125*factor))
        #expect(moved.points[1] == CGPoint(x:210*factor,y:175*factor))
    }

    @Test(arguments:[1,2]) func blankSpaceMovesTheRangeButKeepsMarksAnchoredToSourcePixels(factor:Int) async throws {
        let fixture=try Fixture(factor:factor);defer { fixture.close() }
        try fixture.selectRange()
        let view=fixture.view,document=view.session.document
        document.add(CaptureMark(tool:.cover,points:[CGPoint(x:100*factor,y:100*factor),CGPoint(x:180*factor,y:150*factor)],color:.blue,width:2))
        await settle()
        let marks=document.marks,old=try #require(view.selected)
        let canvas=try #require(fixture.canvas)
        try fixture.drag(from:CGPoint(x:400,y:300),to:CGPoint(x:430,y:320),target:canvas)
        #expect(view.selected == old.offsetBy(dx:30,dy:20) && document.marks == marks)
        #expect(document.selectedMarkID == nil && view.session.tool == .move)
        #expect(document.captureViewport?.origin == CGPoint(x:50*factor,y:40*factor))
    }

    @Test(arguments:[true,false],[true,false]) func rightClickOnBlankSpaceInsideOrOutsideReturnsToSelectionWithoutLosingMarks(inside:Bool,drawing:Bool) async throws {
        let fixture=try Fixture();defer { fixture.close() }
        try fixture.selectRange()
        let view=fixture.view,document=view.session.document,source=view.image
        document.add(CaptureMark(tool:.cover,points:[CGPoint(x:100,y:100),CGPoint(x:180,y:150)],color:.blue,width:2))
        view.session.selectTool(drawing ? .arrow:.move,toggleIfSelected:false);await settle()
        let marks=document.marks,undo=document.undoCount
        let point=inside ? CGPoint(x:400,y:300):CGPoint(x:700,y:550)
        let receiver=try #require(view.hitTest(view.convert(point,to:view.superview)))
        receiver.rightMouseDown(with:try fixture.event(.rightMouseDown,at:point))
        #expect(!view.session.hasSelection && view.selected == nil && view.session.tool == .move)
        #expect(document.marks == marks && document.undoCount == undo && view.image === source)
        #expect(fixture.canvas?.isHidden == true && document.selectedMarkID == nil)
        try fixture.selectRange()
        #expect(view.session.hasSelection && document.marks == marks)
    }

    @Test func rightClickDuringOutputDoesNotResetTheSelection() throws {
        let fixture=try Fixture();defer { fixture.close() }
        try fixture.selectRange()
        let view=fixture.view,range=view.selected
        view.session.exporting=true
        view.rightMouseDown(with:try fixture.event(.rightMouseDown,at:CGPoint(x:400,y:300)))
        #expect(view.selected == range && view.session.hasSelection)
        view.session.exporting=false
    }

    @Test func rangeHandlesStillOwnTheEventEvenWhenAMarkOccupiesTheSameCorner() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        try fixture.selectRange()
        let view=fixture.view
        view.session.document.add(CaptureMark(tool:.rectangle,points:[CGPoint(x:450,y:350),CGPoint(x:600,y:450)],color:.red,width:2))
        await settle()
        let corner=CGPoint(x:600,y:450)
        #expect(view.hitTest(view.convert(corner,to:view.superview)) === view)
        try fixture.drag(from:corner,to:CGPoint(x:650,y:480),target:view)
        #expect(view.selected == CGRect(x:20,y:20,width:630,height:460))
        #expect(view.session.document.marks[0].points == [CGPoint(x:450,y:350),CGPoint(x:600,y:450)])
    }

    @Test func clickingTheActiveToolOrEscapeReturnsToTheSameDefaultContext() throws {
        let fixture=try Fixture();defer { fixture.close() }
        try fixture.selectRange()
        let session=fixture.view.session
        session.selectTool(.arrow);session.selectTool(.arrow)
        #expect(session.tool == .move && CaptureToolGroup.group(session.tool) == nil)
        session.selectTool(.rectangle);session.selectTool(.rectangle,toggleIfSelected:false)
        #expect(session.tool == .rectangle)
        session.perform(.close)
        #expect(session.tool == .move && session.hasSelection)
        for legacy in [CaptureTool.select,.move,.crop] {
            session.selectTool(.pen);session.selectTool(legacy)
            #expect(session.tool == .move && session.hasSelection)
        }
    }

    @Test func eightGroupsExposeAllAnnotationCapabilitiesWithoutDefaultModeButtons() {
        #expect(CaptureToolGroup.allCases == [.shapes,.drawing,.lines,.text,.number,.obscure,.erasing,.effects])
        let expected:Set<CaptureTool>=[.rectangle,.ellipse,.pen,.highlight,.arrow,.line,.text,.watermark,.number,.mosaic,.cover,.deleteMarks,.erase,.inpaint,.spotlight,.magnify]
        let members=CaptureToolGroup.allCases.flatMap(\.members)
        #expect(Set(members) == expected && members.count == 16)
        #expect([CaptureTool.move,.select,.crop].allSatisfy { CaptureToolGroup.group($0) == nil })
        #expect(Set(CaptureToolbarPreferences.ordered("")) == Set(CaptureTool.allCases))
        #expect(CaptureSelectionToolbarMetrics.width(allowsAnnotations:true) == 806)
        #expect(CaptureFloatingLayout.toolbarSize == CGSize(width:828,height:40))
        #expect(CaptureToolbarPreferences.expandedTools("") == members)
    }

    @Test func groupingPreservesTheOldSerializedOrderAndMemberOrderWithoutWritingPreferences() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let old=CaptureToolbarPreferences.encoded([.watermark,.ellipse,.select,.line,.rectangle,.text,.move,.crop,.pen])
        fixture.defaults.set(old,forKey:"capture.toolbarOrder")
        #expect(Array(CaptureToolbarPreferences.groups(old).prefix(3)) == [.text,.shapes,.lines])
        #expect(CaptureToolbarPreferences.members(.shapes,order:old) == [.ellipse,.rectangle])
        #expect(CaptureToolbarPreferences.members(.text,order:old) == [.watermark,.text])
        let oldChoices=try JSONEncoder().encode(["shapes":CaptureTool.ellipse,"lines":.line])
        fixture.defaults.set(oldChoices,forKey:"capture.toolbar.groupChoices")
        #expect(Array(CaptureToolbarPreferences.expandedTools(old).prefix(6)) == [.watermark,.text,.ellipse,.rectangle,.line,.arrow])
        for tool in [CaptureTool.rectangle,.line,.pen,.move] { fixture.view.session.selectTool(tool) }
        #expect(fixture.defaults.string(forKey:"capture.toolbarOrder") == old)
        #expect(fixture.defaults.data(forKey:"capture.toolbar.groupChoices") == oldChoices)
        let reordered=CaptureToolbarPreferences.reordered(Array(CaptureToolGroup.allCases.reversed()),preserving:old)
        #expect(Set(reordered) == Set(CaptureTool.allCases))
        #expect(reordered.filter { CaptureToolGroup.shapes.members.contains($0) } == [.ellipse,.rectangle])
    }

    @Test func editingASelectedMarkInDefaultModeUsesItsOwnStyleAndShowsThePropertyStrip() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        try fixture.selectRange()
        let session=fixture.view.session
        session.document.add(CaptureMark(tool:.rectangle,points:[CGPoint(x:100,y:100),CGPoint(x:180,y:150)],color:.blue,width:2))
        await settle()
        #expect(session.tool == .move && session.inspectorTool == .rectangle)
        let strip=try #require(fixture.styleStrip)
        #expect(!strip.isHidden && strip.frame.height == 40)
        session.style.fill = .solid
        #expect(session.document.selectedMark?.style.fill == .solid)
        let styles=try #require(fixture.defaults.data(forKey:"capture.annotation.styles"))
        let decoded=try JSONDecoder().decode([String:CaptureMarkStyle].self,from:styles)
        #expect(decoded[CaptureTool.rectangle.rawValue]?.fill == .solid && decoded[CaptureTool.move.rawValue] == nil)
        let range=fixture.view.selected
        let point=CGPoint(x:strip.frame.midX,y:strip.frame.midY)
        let hit=try #require(fixture.view.hitTest(fixture.view.convert(point,to:fixture.view.superview)))
        #expect(hit === strip || hit.isDescendant(of:strip))
        fixture.view.mouseDown(with:try fixture.event(.leftMouseDown,at:point))
        fixture.view.mouseUp(with:try fixture.event(.leftMouseUp,at:point))
        #expect(fixture.view.selected == range && session.hasSelection)
    }

    @Test func propertyPlacementAvoidsInfoChromeAndDoesNotMoveTheMainToolbarOrImage() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        try fixture.selectRange()
        let view=fixture.view,frame=fixture.panel.frame
        let toolbar=try #require(view.subviews.first { $0 is CaptureFirstMouseHostingView<CaptureSelectionToolbar> })
        let main=toolbar.frame,range=view.selected
        for tool in [CaptureTool.arrow,.rectangle,.ellipse,.pen,.mosaic,.number,.cover,.spotlight,.magnify,.move] {
            view.session.selectTool(tool,toggleIfSelected:false);await settle()
            #expect(toolbar.frame == main && view.selected == range && fixture.panel.frame == frame)
            if tool.hasAnnotationStyle {
                let strip=try #require(fixture.styleStrip)
                #expect(!strip.isHidden && strip.frame.height == 40 && !strip.frame.intersects(main))
                #expect(strip.frame.width<=view.bounds.width-16 && strip.frame.minX>=8)
            } else { #expect(fixture.styleStrip?.isHidden == true) }
        }
    }

    @Test func nativeCustomColorControlUsesItsRealCompactBounds() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        try fixture.selectRange();fixture.view.session.selectTool(.rectangle)
        fixture.panel.orderFrontRegardless();fixture.panel.displayIfNeeded();await settle()
        let strip=try #require(fixture.styleStrip)
        strip.layoutSubtreeIfNeeded()
        let well=try #require(descendants(strip).compactMap { $0 as? CaptureAnnotationColorWell }.first)
        #expect(well.frame.width == 22 && well.frame.height == 24)
        #expect(well.colorWellStyle == .minimal && well.supportsAlpha)
        #expect(well.target is CaptureCompactColorWell.Coordinator && well.target !== well)
        well.color = .blue
        let action=try #require(well.action)
        #expect(well.sendAction(action,to:well.target))
        #expect(NSColor(fixture.view.session.color).usingColorSpace(.sRGB)?.blueComponent == NSColor.blue.usingColorSpace(.sRGB)?.blueComponent)
        #expect(fixture.view.session.allowsStyleEditing)
        fixture.view.cancelRefresh();#expect(!fixture.view.session.allowsStyleEditing)
    }

    @Test func everyVisualSelectorUsesASingleTopToBottomColumn() async throws {
        try await assertVerticalOptions(CaptureLinePattern.solid)
        try await assertVerticalOptions(CaptureFill.outline)
        try await assertVerticalOptions(CaptureArrowStyle.filled)
        try await assertVerticalOptions(CaptureEllipseKind.ellipse)
        try await assertVerticalOptions(CaptureNumberStyle.circle)
        try await assertVerticalOptions(CaptureNumberFormat.decimal)
        try await assertVerticalOptions(CaptureMosaicMode.pixels)
        try await assertVerticalOptions(CaptureCoverage.rectangle)
    }
    private func assertVerticalOptions<Value:CaptureStyleOption & Hashable>(_ value:Value) async throws {
        let observation=OptionBounds()
        let root=CaptureVisualStyleOptions(value:Binding.constant(value),didChoose:{})
            .coordinateSpace(name:PanelLayout.coordinateSpace)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { frames in MainActor.assumeIsolated { observation.frames=frames } }
        let host=NSHostingView(rootView:root);host.sizingOptions=[]
        let size=CaptureStyleOptionMetrics.size(count:Value.allCases.count)
        let panel=NSPanel(contentRect:CGRect(origin:CGPoint(x:20,y:20),size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.contentView=host;panel.orderFrontRegardless();host.layoutSubtreeIfNeeded();panel.displayIfNeeded()
        defer { panel.close();panel.contentView=nil }
        await settle()
        var previous:CGRect?
        for item in Value.allCases {
            let frame=try #require(observation.frames["capture.style.option."+item.rawValue])
            #expect(abs(frame.width-96)<0.1 && abs(frame.height-32)<0.1)
            if let previous { #expect(abs(frame.minX-previous.minX)<0.1 && abs(frame.minY-previous.maxY-2)<0.1) }
            previous=frame
        }
    }
    @MainActor private final class OptionBounds { var frames:[String:CGRect]=[:] }

    @Test func styleChoicesRenderResultsInsteadOfIdenticalTextRows() throws {
        let lines=try CaptureLinePattern.allCases.map(preview)
        let fills=try CaptureFill.allCases.map(preview)
        let arrows=try CaptureArrowStyle.allCases.map(preview)
        #expect(Set(lines).count == 4 && Set(fills).count == 3 && Set(arrows).count == 6)
    }

    @Test func styleStripIsContentSizedAndFitsAtNarrowWidths() {
        for tool in CaptureToolGroup.allCases.flatMap(\.members).filter(\.hasAnnotationStyle) {
            let width=CaptureStyleBarMetrics.width(tool:tool,style:CaptureMarkStyle())
            #expect(width>=100 && width<=620)
            for areaWidth in [384.0,640.0,1400.0] {
                let visible=CGRect(x:0,y:0,width:areaWidth,height:500)
                let toolbar=CGRect(x:8,y:440,width:min(806,areaWidth-16),height:40)
                let frame=CaptureStyleBarMetrics.frame(toolbar:toolbar,visible:visible,width:width,flipped:true)
                #expect(visible.insetBy(dx:8,dy:8).contains(frame) && !frame.intersects(toolbar))
            }
        }
    }

    @Test func floatingDefaultEditsMarksBeforeConsideringWindowDragAndClosesThePropertyWindow() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ContextFloating-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fixture=try Fixture();defer { fixture.close() }
        let controller=ScreenshotController(directory:directory)
        defer { controller.deactivate() }
        let document=CaptureDocument(image:fixture.image,copyDefaults:fixture.defaults)
        document.add(CaptureMark(tool:.cover,points:[CGPoint(x:100,y:100),CGPoint(x:180,y:150)],color:.blue,width:2))
        let editor=CaptureFloatingEditor(document:document,controller:controller,preferredFrame:CGRect(x:100,y:100,width:800,height:600),preservesPresentationFrame:true,annotationDefaults:fixture.defaults)
        editor.show();defer { editor.close() };await settle()
        let canvas=try #require(descendants(editor.canvasPanel.contentView!).compactMap { $0 as? CaptureDrawingView }.first)
        let frame=editor.imageFrame
        try drag(canvas,from:CGPoint(x:130,y:120),to:CGPoint(x:160,y:145))
        #expect(editor.tool == .move && editor.imageFrame == frame)
        #expect(document.marks[0].points[0] == CGPoint(x:130,y:125))
        await settle();#expect(editor.stylesPanel.isVisible)
        editor.selectTool(.arrow);editor.selectTool(.arrow)
        #expect(editor.tool == .move)
        try drag(canvas,from:CGPoint(x:600,y:400),to:CGPoint(x:620,y:415))
        #expect(editor.imageFrame == frame.offsetBy(dx:20,dy:-15))
        editor.close()
        #expect(!editor.stylesPanel.isVisible && editor.stylesPanel.contentView == nil)
        #expect(!editor.toolsPanel.isVisible && !editor.canvasPanel.isVisible)
    }

    @Test func ownedToolbarVisualProbe() async throws {
        guard let path=ProcessInfo.processInfo.environment["UNTITLED_CAPTURE_TOOLBAR_VISUAL_PATH"] else { return }
        guard CGPreflightScreenCaptureAccess() else { Issue.record("Existing Screen Recording grant unavailable; no permission was requested");return }
        let directory=URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let fixture=try Fixture();defer { fixture.close() }
        fixture.panel.setContentSize(CGSize(width:1100,height:700))
        try fixture.selectRange();fixture.panel.hasShadow=false;fixture.panel.orderFrontRegardless();fixture.panel.displayIfNeeded()
        for tool in [CaptureTool.rectangle,.arrow,.pen,.mosaic,.number,.text] {
            fixture.view.session.selectTool(tool,toggleIfSelected:false)
            fixture.view.layoutSubtreeIfNeeded();fixture.panel.displayIfNeeded();try await Task.sleep(for:.milliseconds(100))
            let toolbar=try #require(fixture.view.subviews.first { $0 is CaptureFirstMouseHostingView<CaptureSelectionToolbar> })
            let strip=try #require(fixture.styleStrip)
            let roi=toolbar.frame.union(strip.frame).insetBy(dx:-3,dy:-3).intersection(fixture.view.bounds)
            let image=try await captureOwned(fixture.panel)
            let scale=CGFloat(image.width)/fixture.view.bounds.width
            let rect=CGRect(x:roi.minX*scale,y:roi.minY*scale,width:roi.width*scale,height:roi.height*scale).integral
            let cropped=try #require(image.cropping(to:rect))
            try #require(NSBitmapImageRep(cgImage:cropped).representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(tool.rawValue+".png"),options:.atomic)
        }
        let options=CaptureFirstMouseHostingView(rootView:CaptureVisualStyleOptions(value:Binding.constant(CaptureLinePattern.solid),didChoose:{}).background(Color(nsColor:.windowBackgroundColor)))
        options.sizingOptions=[]
        let optionSize=CaptureStyleOptionMetrics.size(count:CaptureLinePattern.allCases.count)
        let panel=NSPanel(contentRect:CGRect(origin:CGPoint(x:300,y:300),size:optionSize),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.hasShadow=false;panel.contentView=options;panel.orderFrontRegardless();panel.displayIfNeeded()
        defer { panel.orderOut(nil);panel.close();panel.contentView=nil }
        try await Task.sleep(for:.milliseconds(100))
        let image=try await captureOwned(panel)
        try #require(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("line-options.png"),options:.atomic)
    }
    private func captureOwned(_ panel:NSPanel) async throws -> CGImage {
        let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        let window=try #require(content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier })
        let filter=SCContentFilter(desktopIndependentWindow:window)
        let configuration=SCStreamConfiguration();configuration.showsCursor=false
        configuration.width=Int((filter.contentRect.width*CGFloat(filter.pointPixelScale)).rounded())
        configuration.height=Int((filter.contentRect.height*CGFloat(filter.pointPixelScale)).rounded())
        return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration)
    }

    private func preview<Value:CaptureStyleOption>(_ value:Value) throws -> Data {
        let view=CaptureStyleSample(option:value).frame(width:80,height:32).foregroundStyle(Color.black).background(Color.white).environment(\.colorScheme,.light)
        let image=try #require(ImageRenderer(content:view).cgImage)
        return try #require(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
    }
    private func drag(_ canvas:CaptureDrawingView,from start:CGPoint,to end:CGPoint) throws {
        func event(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:canvas.window?.windowNumber ?? 0,context:nil,eventNumber:1,clickCount:1,pressure:1))
        }
        canvas.mouseDown(with:try event(.leftMouseDown,start));canvas.mouseDragged(with:try event(.leftMouseDragged,end));canvas.mouseUp(with:try event(.leftMouseUp,end))
    }
    private func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    private func settle() async { try? await Task.sleep(for:.milliseconds(30)) }

    @MainActor private final class Fixture {
        let domain="CaptureContext-"+UUID().uuidString
        let defaults:UserDefaults
        let image:CGImage
        let view:CaptureSelectionView
        let panel:NSPanel
        var canvas:CaptureDrawingView? { view.subviews.compactMap { $0 as? CaptureDrawingView }.first }
        var styleStrip:NSView? { view.subviews.first { $0 is CaptureFirstMouseHostingView<CaptureAnnotationStyleBar<CaptureSelectionSession>> } }
        init(factor:Int=1) throws {
            defaults=try #require(UserDefaults(suiteName:domain))
            let context=try CaptureImage.context(width:800*factor,height:600*factor)
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:800*factor,height:600*factor))
            image=try #require(context.makeImage())
            view=CaptureSelectionView(image:image,allowsShapes:true,sessionDefaults:defaults)
            panel=NSPanel(contentRect:CGRect(x:0,y:0,width:800,height:600),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false;panel.contentView=view
        }
        func event(_ type:NSEvent.EventType,at point:CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
        }
        func selectRange() throws { try drag(from:CGPoint(x:20,y:20),to:CGPoint(x:600,y:450),target:view) }
        func drag(from start:CGPoint,to end:CGPoint,target:NSView) throws {
            target.mouseDown(with:try event(.leftMouseDown,at:start));target.mouseDragged(with:try event(.leftMouseDragged,at:end));target.mouseUp(with:try event(.leftMouseUp,at:end))
        }
        func close() { view.cancelRefresh();panel.orderOut(nil);panel.close();panel.contentView=nil;defaults.removePersistentDomain(forName:domain) }
    }
}
