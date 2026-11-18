import AppKit
import SwiftUI
import QuartzCore
@preconcurrency import ScreenCaptureKit
import Darwin
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor struct CaptureRequestAdmissionTests {
    private let startActions:[ActionKind]=[.captureRegion,.captureWindow,.captureScreen,.captureScrolling,.captureRecording,.captureDelayed,.captureAndCopy,.captureLastRegion]
    @Test func repeatedStartsAreSilentWithoutExtraPermissionsOrSourceWork() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("CaptureAdmission-"+UUID().uuidString)
        let barrier=ContentBarrier(),service=CaptureService(loadContent:{ try await barrier.load() })
        let controller=ScreenshotController(directory:folder,service:service)
        defer { barrier.failAll();controller.deactivate();try? FileManager.default.removeItem(at:folder) }
        var permissionCalls=0,reports=0,histories=0
        controller.reportError={ _ in reports += 1 };controller.showHistory={ histories += 1 }
        let permission=PluginPermissionClient { _ in permissionCalls += 1 }
        let first=Task { try await controller.perform(.captureRegion,permissions:permission) }
        try await wait { barrier.calls == 1 }
        #expect(controller.busy && permissionCalls == 1)
        for action in startActions {
            #expect(controller.shouldIgnoreCaptureRequest(action))
            try await controller.perform(action,permissions:PluginPermissionClient { _ in Issue.record("Duplicate request checked permissions") })
        }
        try await controller.perform(.captureHistory,permissions:permission)
        #expect(barrier.calls == 1 && permissionCalls == 1 && histories == 1 && reports == 0)
        barrier.fail(1)
        if case .failure(let error)=await first.result { #expect(error is CancellationError) } else { Issue.record("Expected fake cancellation") }
        #expect(!controller.busy && !controller.shouldIgnoreCaptureRequest(.captureRegion))
        let retry=Task { try await controller.perform(.captureRegion,permissions:permission) }
        try await wait { barrier.calls == 2 };barrier.fail(2)
        _=await retry.result
        #expect(!controller.busy && permissionCalls == 2 && reports == 0)
    }
    @Test func serviceLeaseRejectsOverlapAndAnOldExitCannotReleaseANewerRequest() async throws {
        let barrier=ContentBarrier(),service=CaptureService(loadContent:{ try await barrier.load() })
        defer { service.cancel();barrier.failAll() }
        let permissions=PluginPermissionClient { _ in }
        let first=Task { try await service.choose(.region,permissions:permissions) }
        try await wait { barrier.calls == 1 }
        #expect(try await service.choose(.window,permissions:permissions) == nil)
        #expect(try await service.repeatRegion(.init(displayID:1,rect:CGRect(x:0,y:0,width:20,height:20)),permissions:permissions) == nil)
        #expect(barrier.calls == 1)
        service.cancel()
        let second=Task { try await service.choose(.region,permissions:permissions) }
        try await wait { barrier.calls == 2 }
        barrier.fail(1);_=await first.result
        #expect(try await service.choose(.screen,permissions:permissions) == nil)
        #expect(barrier.calls == 2)
        barrier.fail(2);_=await second.result
        let third=Task { try await service.choose(.region,permissions:permissions) }
        try await wait { barrier.calls == 3 };barrier.fail(3);_=await third.result
    }
    @Test func mouseCaptureStartupBlocksKeyboardAndOldCancellationCannotReleaseNewMouseWork() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMouseAdmission-"+UUID().uuidString)
        let domain="CaptureMouseAdmission-"+UUID().uuidString,defaults=try #require(UserDefaults(suiteName:domain))
        let barrier=ContentBarrier(),service=CaptureService(loadContent:{ try await barrier.load() })
        let mouse=CaptureGlobalMouse(service:service,preferences:{ CaptureGlobalMousePreferences(defaults:defaults) })
        let controller=ScreenshotController(directory:folder,globalMouse:mouse)
        defer { mouse.stop();barrier.failAll();controller.deactivate();defaults.removePersistentDomain(forName:domain);try? FileManager.default.removeItem(at:folder) }
        var allowed=false,completed=0
        let permissions=PluginPermissionClient { _ in }
        mouse.start(isAllowed:{ allowed },permissions:permissions) { _,_ in completed += 1 }
        allowed=true
        mouse.capture(CGRect(x:0,y:0,width:100,height:100),action:.edit)
        try await wait { barrier.calls == 1 }
        #expect(mouse.hasActiveCapture && !controller.busy)
        for action in startActions { try await controller.perform(action,permissions:PluginPermissionClient { _ in Issue.record("Mouse startup leaked a keyboard capture") }) }
        #expect(completed == 0 && barrier.calls == 1)
        mouse.stop()
        allowed=false;mouse.start(isAllowed:{ allowed },permissions:permissions) { _,_ in completed += 1 };allowed=true
        mouse.capture(CGRect(x:0,y:0,width:100,height:100),action:.edit)
        try await wait { barrier.calls == 2 }
        barrier.fail(1);try await Task.sleep(for:.milliseconds(20))
        #expect(mouse.hasActiveCapture && controller.shouldIgnoreCaptureRequest(.captureRegion))
        barrier.fail(2);try await wait { !mouse.hasActiveCapture }
        #expect(completed == 0 && !controller.shouldIgnoreCaptureRequest(.captureRegion))
    }
    private func wait(_ condition:() -> Bool) async throws {
        for _ in 0..<100 { if condition() { return };try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("Fake capture did not reach its expected barrier");throw CancellationError()
    }
    @MainActor private final class ContentBarrier {
        var calls=0
        private var pending:[Int:CheckedContinuation<SCShareableContent,any Error>]=[:]
        func load() async throws -> SCShareableContent {
            calls += 1;let id=calls
            return try await withCheckedThrowingContinuation { pending[id]=$0 }
        }
        func fail(_ id:Int) { pending.removeValue(forKey:id)?.resume(throwing:CancellationError()) }
        func failAll() { let values=Array(pending.values);pending.removeAll();values.forEach { $0.resume(throwing:CancellationError()) } }
    }
}

@Suite(.serialized) @MainActor struct CaptureSelectionSessionTests {
    @Test func selectionCanExpandBackIntoTheFrozenSourceInsteadOfMovingAnImageWindow() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:120,y:100))
        #expect(view.session.hasSelection && view.preparedExport == nil)
        let frame=fixture.panel.frame
        try drag(view,from:CGPoint(x:120,y:100),to:CGPoint(x:320,y:200))
        #expect(view.selected == CGRect(x:20,y:20,width:300,height:180))
        #expect(fixture.panel.frame == frame)
        let output=try view.prepareSelectionExport()
        #expect(output.image.width == 300 && output.image.height == 180)
        let pixel=try #require(NSBitmapImageRep(cgImage:output.image).colorAt(x:260,y:30))
        #expect(pixel.blueComponent > 0.9 && pixel.redComponent < 0.1)
    }
    @Test func clickingOutsideExpandsWhileDraggingOutsideCanReplaceTheRegion() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:120,y:100))
        // The former (180,160) is now inside the visible toolbar: use real
        // uncovered canvas so this tests expansion, not a chrome click.
        view.mouseDown(with:try event(.leftMouseDown,point:CGPoint(x:180,y:90),in:view))
        view.mouseUp(with:try event(.leftMouseUp,point:CGPoint(x:180,y:90),in:view))
        #expect(view.selected?.contains(CGPoint(x:180,y:90)) == true)
        #expect(view.selected?.contains(CGPoint(x:20,y:20)) == true)
        try drag(view,from:CGPoint(x:240,y:20),to:CGPoint(x:340,y:100))
        #expect(view.selected == CGRect(x:240,y:20,width:100,height:80))
    }
    @Test func viewportChangesNeverScaleEraseOrUndoTheExistingMarks() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let document=fixture.view.session.document
        try document.setCaptureViewport(CGRect(x:20,y:20,width:100,height:80))
        document.add(CaptureMark(tool:.cover,points:[CGPoint(x:40,y:40),CGPoint(x:70,y:70)],color:.black,width:2))
        let marks=document.marks
        try document.setCaptureViewport(CGRect(x:210,y:20,width:100,height:80))
        #expect(document.marks == marks && document.undoCount == 1)
        #expect((NSBitmapImageRep(cgImage:document.image).colorAt(x:20,y:20)?.blueComponent ?? 0)>0.9)
        try document.setCaptureViewport(CGRect(x:10,y:10,width:300,height:200))
        #expect(document.marks == marks && document.archiveMarks[0].points[0] == CGPoint(x:30,y:30))
        #expect((NSBitmapImageRep(cgImage:document.image).colorAt(x:40,y:40)?.redComponent ?? 1)<0.1)
        document.undo()
        #expect(document.marks.isEmpty && document.captureViewport == CGRect(x:10,y:10,width:300,height:200))
    }
    @Test func regionHandlesStillWorkWhileAnAnnotationToolIsActive() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        view.session.selectTool(.arrow)
        let corner=CGPoint(x:160,y:120)
        let hit=view.hitTest(view.convert(corner,to:view.superview))
        #expect(hit === view)
        try drag(view,from:corner,to:CGPoint(x:200,y:150))
        #expect(view.selected == CGRect(x:20,y:20,width:180,height:130))
        #expect(view.session.tool == .arrow && view.session.hasSelection)
    }
    @Test func inlineDrawingUsesSourcePixelsAndExportsEditableLocalMarks() throws {
        let fixture=try Fixture(scale:2);defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        view.session.selectTool(.cover);view.session.stylesPresented=false
        let canvas=try #require(view.subviews.compactMap { $0 as? CaptureDrawingView }.first)
        #expect(canvas.coordinateOrigin == CGPoint(x:40,y:40))
        canvas.mouseDown(with:try event(.leftMouseDown,point:CGPoint(x:30,y:30),in:canvas))
        canvas.mouseDragged(with:try event(.leftMouseDragged,point:CGPoint(x:60,y:60),in:canvas))
        canvas.mouseUp(with:try event(.leftMouseUp,point:CGPoint(x:60,y:60),in:canvas))
        #expect(view.session.document.marks.count == 1)
        #expect(view.session.document.marks[0].points[0] == CGPoint(x:100,y:100))
        let output=try view.prepareSelectionExport()
        #expect(output.image.width == 280 && output.marks[0].points[0] == CGPoint(x:60,y:60))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("CaptureSessionArchive-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url=folder.appendingPathComponent("capture.png")
        try CaptureEditableArchive.save(base:output.base,marks:output.marks,for:url)
        let restored=CaptureDocument(image:output.image)
        try CaptureEditableArchive.restore(restored,for:url)
        #expect(restored.unmarkedImage.width == 280 && restored.marks.count == 1)
        #expect(restored.marks[0].id == output.marks[0].id && restored.marks[0].points == output.marks[0].points)
        #expect(restored.marks[0].style == output.marks[0].style && restored.marks[0].width == output.marks[0].width)
    }
    @Test func paletteIsTemporaryAndAllFourPixPinModesAreAvailable() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        #expect(CaptureSelectionView.Shape.allCases.count == 4 && view.shape == .rectangle)
        view.keyDown(with:try key(48,flags:.control,in:fixture.panel))
        #expect(view.session.choosingMode && view.session.pendingMode == .freehand && view.shape == .rectangle)
        view.flagsChanged(with:try key(59,flags:[],in:fixture.panel,type:.flagsChanged))
        #expect(view.shape == .freehand && !view.session.choosingMode)
        for mode in CaptureSelectionView.Shape.allCases { view.setCaptureShape(mode);#expect(view.shape == mode) }
    }
    @Test func toolbarPaddingClickMustNotRestartSelectionOrHideItsControls() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        let toolbar=try #require(view.subviews.first { $0 is CaptureFirstMouseHostingView<CaptureSelectionToolbar> })
        let original=view.selected
        let info=try #require(view.subviews.first { $0 is CaptureFirstMouseHostingView<CaptureSelectionInfoBar> })
        for tool in [CaptureTool.move,.arrow] {
            view.session.selectTool(tool)
            for control in [toolbar,info] {
                let point=CGPoint(x:control.frame.minX+2,y:control.frame.midY)
                let hit=try #require(view.hitTest(view.convert(point,to:view.superview)))
                #expect(hit === control || hit.isDescendant(of:control))
                view.mouseDown(with:try event(.leftMouseDown,point:point,in:view))
                #expect(view.session.hasSelection && !toolbar.isHidden && view.selected == original)
                view.mouseUp(with:try event(.leftMouseUp,point:point,in:view))
                view.rightMouseDown(with:try event(.rightMouseDown,point:point,in:view))
                #expect(view.selected == original && !toolbar.isHidden)
            }
        }
    }
    @Test func toolbarFitsItsContentAndKeepsOutputsVisibleAtNarrowWidths() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        let observation=ToolbarBounds()
        let root=CaptureSelectionToolbar(session:fixture.view.session,document:fixture.view.session.document)
            .coordinateSpace(name:PanelLayout.coordinateSpace)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { value in MainActor.assumeIsolated { observation.frames=value } }
        let ideal=CaptureSelectionToolbarMetrics.width(allowsAnnotations:true)
        let host=NSHostingView(rootView:root);host.sizingOptions=[]
        let panel=NSPanel(contentRect:CGRect(x:0,y:0,width:ideal,height:40),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.contentView=host;panel.orderFrontRegardless()
        defer { CaptureToolbarHelpView.dismiss(in:host);panel.close();panel.contentView=nil }
        host.layoutSubtreeIfNeeded();panel.displayIfNeeded()
        try await Task.sleep(for:.milliseconds(80))
        let ids=["capture.selection.tool.arrow","capture.selection.tool.rectangle","capture.selection.action.more","capture.selection.action.redo","capture.selection.action.undo","capture.selection.action.ocr","capture.selection.action.pin","capture.selection.action.save","capture.selection.action.copy","capture.selection.action.close"]
        for id in ids {
            let frame=try #require(observation.frames[id])
            #expect(abs(frame.width-28)<0.1 && abs(frame.height-28)<0.1)
        }
        let toolStrip=try #require(observation.frames["capture.selection.tools"])
        for tool in CaptureToolbarPreferences.expandedTools(UserDefaults.standard.string(forKey:"capture.toolbarOrder") ?? "") {
            let frame=try #require(observation.frames["capture.selection.tool."+tool.rawValue])
            #expect(abs(frame.width-28)<0.1 && frame.minX>=toolStrip.minX && frame.maxX<=toolStrip.maxX+0.1)
        }
        let before=try #require(observation.frames["capture.selection.action.save"])
        let close=try #require(observation.frames["capture.selection.action.close"])
        #expect(abs(close.maxX-(ideal-8))<0.1)
        for pair in [("ocr","pin"),("pin","save"),("save","copy"),("copy","close"),("redo","undo"),("undo","more")] {
            let left=try #require(observation.frames["capture.selection.action."+pair.0])
            let right=try #require(observation.frames["capture.selection.action."+pair.1])
            #expect(abs(right.minX-left.maxX-2)<0.1)
        }
        fixture.view.session.selectTool(.arrow);try await Task.sleep(for:.milliseconds(40))
        #expect(observation.frames["capture.selection.action.save"] == before)
        let hints=descendants(host).compactMap { $0 as? CaptureToolbarHelpView }
        #expect(hints.count >= 24 && hints.allSatisfy { !$0.hint.isEmpty })
        let arrowHint=CaptureTool.arrow.title+(CaptureShortcutSettings.shared.binding(.arrow).map { "（\($0.display)）" } ?? "")
        #expect(hints.contains { $0.hint == arrowHint })
        for width in [640.0,384.0] {
            panel.setContentSize(CGSize(width:width,height:40));host.layoutSubtreeIfNeeded();panel.displayIfNeeded()
            try await Task.sleep(for:.milliseconds(40))
            for name in ["ocr","pin","save","copy","close"] {
                let frame=try #require(observation.frames["capture.selection.action."+name])
                #expect(frame.minX>=8 && frame.maxX<=width-8.1+0.2)
            }
            let strip=try #require(observation.frames["capture.selection.tools"])
            #expect(strip.width>60)
            let target:CaptureTool=width<400 ? .arrow:.mosaic
            fixture.view.session.selectTool(target);try await Task.sleep(for:.milliseconds(80))
            let active=try #require(observation.frames["capture.selection.tool."+target.rawValue])
            let overflow=width<ideal
            #expect(active.minX>=strip.minX+(overflow ? 13:0) && active.maxX<=strip.maxX-(overflow ? 13:0))
            let visibleHints=descendants(host).compactMap { $0 as? CaptureToolbarHelpView }
            #expect(visibleHints.contains { $0.hint == "滚动至工具栏开头" } == overflow)
            #expect(visibleHints.contains { $0.hint == "滚动至工具栏末尾" } == overflow)
        }
    }
    @Test func cursorMatchesAnnotationHandlesToolbarAndActiveRangeDrag() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        let center=CGPoint(x:80,y:70)
        #expect(view.interactionCursor(at:center) == .openHand)
        for (tool,cursor) in [(CaptureTool.arrow,CaptureInteractionCursor.crosshair),(.text,.text),(.select,.openHand)] {
            view.session.selectTool(tool)
            #expect(view.interactionCursor(at:center) == cursor)
            let canvas=try #require(descendants(view).compactMap { $0 as? CaptureDrawingView }.first)
            #expect(canvas.interactionCursor(at:canvas.convert(center,from:view)) == cursor)
            for handle in CaptureSelectionHandle.allCases {
                let point=handle.point(in:try #require(view.selected))
                #expect(view.interactionCursor(at:point) == .resize(handle))
                #expect(canvas.interactionCursor(at:canvas.convert(point,from:view)) == .resize(handle))
            }
        }
        let toolbar=try #require(view.subviews.first { $0 is CaptureFirstMouseHostingView<CaptureSelectionToolbar> })
        #expect(view.interactionCursor(at:CGPoint(x:toolbar.frame.midX,y:toolbar.frame.midY)) == .arrow)
        #expect(view.interactionCursor(at:CGPoint(x:300,y:20)) == .crosshair)
        view.session.selectTool(.move)
        view.mouseDown(with:try event(.leftMouseDown,point:center,in:view))
        #expect(view.interactionCursor(at:center) == .closedHand)
        view.mouseDragged(with:try event(.leftMouseDragged,point:CGPoint(x:90,y:80),in:view))
        #expect(view.interactionCursor(at:CGPoint(x:90,y:80)) == .closedHand)
        view.mouseUp(with:try event(.leftMouseUp,point:CGPoint(x:90,y:80),in:view))
        #expect(view.interactionCursor(at:CGPoint(x:90,y:80)) == .openHand)
    }
    @Test func hostedToolbarOwnsItsFullBoundsAndKeepsAStableFrameWhenToolsChange() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        fixture.panel.setContentSize(CGSize(width:1400,height:900))
        try drag(view,from:CGPoint(x:100,y:100),to:CGPoint(x:500,y:400))
        let host=try #require(view.subviews.compactMap { $0 as? CaptureFirstMouseHostingView<CaptureSelectionToolbar> }.first)
        #expect(host.sizingOptions.isEmpty)
        fixture.panel.orderFrontRegardless();fixture.panel.displayIfNeeded()
        try await Task.sleep(for:.milliseconds(40))
        let frame=host.frame,region=view.selected
        #expect(frame.width == CaptureSelectionToolbarMetrics.width(allowsAnnotations:true) && frame.height == 40)
        for tool in [CaptureTool.arrow,.rectangle,.move] {
            view.session.selectTool(tool);try await Task.sleep(for:.milliseconds(20))
            for x in [1.0,14.0,86.0,600.0,Double(host.bounds.width-1)] {
                let point=host.convert(CGPoint(x:x,y:24),to:view)
                let hit=try #require(view.hitTest(view.convert(point,to:view.superview)))
                #expect(hit === host || hit.isDescendant(of:host))
                view.mouseDown(with:try event(.leftMouseDown,point:point,in:view))
                view.mouseUp(with:try event(.leftMouseUp,point:point,in:view))
            }
            #expect(view.session.tool == tool && view.session.hasSelection && view.selected == region && !host.isHidden)
            #expect(host.frame == frame)
        }
    }
    @Test func selectionToolbarGroupsEveryCapabilityAndPreservesTheLegacyOrderPreference() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let toolbar=CaptureSelectionToolbar(session:fixture.view.session,document:fixture.view.session.document)
        let saved=UserDefaults.standard.string(forKey:"capture.toolbarOrder") ?? ""
        #expect(toolbar.tools == CaptureToolbarPreferences.ordered(saved))
        #expect(Set(toolbar.tools) == Set(CaptureToolbarPreferences.defaults))
        #expect(toolbar.tools.count == CaptureToolbarPreferences.defaults.count)
        #expect(toolbar.groups == CaptureToolbarPreferences.groups(saved))
        #expect(toolbar.groups.count == 8)
        #expect(Set(toolbar.groups.flatMap(\.members)) == Set(CaptureToolbarPreferences.defaults).subtracting([.move,.select,.crop]))
    }
    @Test func selectingDoesNotDisplayTheOldConfigurationFormOrOpenAnotherWindow() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        let count=NSApp.windows.count
        let textFields=descendants(view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(textFields.isEmpty)
        #expect(view.subviews.filter { $0 is CaptureFirstMouseHostingView<CaptureSelectionInfoBar> }.first?.isHidden == true)
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        #expect(NSApp.windows.count == count)
        #expect(view.subviews.filter { $0 is CaptureFirstMouseHostingView<CaptureSelectionInfoBar> }.first?.isHidden == false)
        #expect(view.preparedExport == nil && !view.session.stopped)
    }
    @Test func failedOutputKeepsTheSelectionAndAnnotationsAndAllowsRetry() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        view.session.addMark(CaptureMark(tool:.cover,points:[CGPoint(x:30,y:30),CGPoint(x:70,y:70)],color:.black,width:2))
        var attempts=0,completions=0
        view.completed={ rect,_ in if rect != nil { completions += 1 } }
        view.outputHandler={ output,action,_,_ in
            attempts += 1
            #expect(action == .copy && output.marks.count == 1)
            if attempts == 1 { throw PluginError.invalid("Fake clipboard busy") }
            return true
        }
        view.session.submit(.copy);try await finish(view.session)
        #expect(attempts == 1 && completions == 0 && view.session.hasSelection && view.session.document.marks.count == 1)
        #expect(view.session.error?.contains("Fake clipboard busy") == true)
        view.session.submit(.copy);try await finish(view.session)
        #expect(attempts == 2 && completions == 1 && view.outputWasHandled)
    }
    @Test func cancellingSaveDoesNotCallTheOutputHandlerOrCloseTheSession() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        var outputs=0
        view.outputHandler={ _,_,_,_ in outputs += 1;return true }
        view.session.chooseSaveDestination={ _ in nil }
        view.session.submit(.save);try await finish(view.session)
        #expect(outputs == 0 && view.session.hasSelection && !view.session.stopped && view.preparedExport == nil)
    }
    @Test func cancellationStopsAnInFlightOutputAndCannotFinishLater() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        var completions=0
        view.completed={ _,_ in completions += 1 }
        view.outputHandler={ _,_,_,_ in try await Task.sleep(for:.seconds(30));return true }
        view.session.submit(.copy);await Task.yield()
        view.cancelRefresh();try await Task.sleep(for:.milliseconds(20))
        #expect(view.session.stopped && completions == 0 && view.preparedExport == nil)
    }
    @Test func masksClipAnnotationsAndComplexOutputDoesNotStoreOutsidePixels() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view;view.setCaptureShape(.polygon)
        for point in [CGPoint(x:20,y:20),CGPoint(x:160,y:20),CGPoint(x:20,y:120)] {
            view.mouseDown(with:try event(.leftMouseDown,point:point,in:view))
            view.mouseUp(with:try event(.leftMouseUp,point:point,in:view))
        }
        view.keyDown(with:try key(36,flags:[],in:fixture.panel))
        view.session.addMark(CaptureMark(tool:.cover,points:[CGPoint(x:20,y:20),CGPoint(x:160,y:120)],color:.black,width:2))
        let output=try view.prepareSelectionExport(),bitmap=NSBitmapImageRep(cgImage:output.image)
        #expect((bitmap.colorAt(x:5,y:5)?.alphaComponent ?? 0)>0.9)
        #expect((bitmap.colorAt(x:130,y:90)?.alphaComponent ?? 1)<0.1)
        let shade=try #require(view.subviews.compactMap { $0 as? CaptureSelectionBackdropView }.first)
        let shadePath=try #require((shade.layer as? CAShapeLayer)?.path)
        #expect(!shadePath.contains(CGPoint(x:25,y:25)) && shadePath.contains(CGPoint(x:150,y:110)))
        #expect(output.marks.isEmpty && output.base === output.image)
    }
    @Test func explicitCopyActionStillFinishesOnSelectionButOrdinaryScreenshotDoesNot() throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view;view.automaticallyCopiesSelection=true
        var outputs=0;view.completed={ rect,_ in if rect != nil { outputs += 1 } }
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        #expect(outputs == 1 && view.postAction == .copy)
    }
    @Test func screenshotPixelsStayOpaqueWhileOnlyTheVectorBackdropAnimates() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        let view=fixture.view,panel=fixture.panel
        CaptureBackdropTransition.show(panel,duration:0.12)
        let shade=try #require(view.subviews.compactMap { $0 as? CaptureSelectionBackdropView }.first)
        let layer=try #require(shade.layer as? CAShapeLayer)
        let entrance=try #require(layer.animation(forKey:CaptureSelectionBackdropView.animationKey) as? CABasicAnimation)
        #expect(panel.alphaValue == 1 && view.alphaValue == 1 && layer.opacity == 1)
        #expect((entrance.fromValue as? NSNumber)?.floatValue == 0 && (entrance.toValue as? NSNumber)?.floatValue == 1)
        #expect(view.layer?.animation(forKey:CaptureSelectionBackdropView.animationKey) == nil)
        try await Task.sleep(for:.milliseconds(40))
        #expect(panel.alphaValue == 1 && view.alphaValue == 1 && view.frame.size == CGSize(width:400,height:300))
        try drag(view,from:CGPoint(x:20,y:20),to:CGPoint(x:160,y:120))
        panel.displayIfNeeded()
        let path=try #require(layer.path)
        #expect(!path.contains(CGPoint(x:80,y:70)) && path.contains(CGPoint(x:300,y:220)))
        view.prepareForHandoff()
        let presentation=CaptureSelectionPresentation(panels:[panel])
        presentation.beginHandoff(above:[],duration:0.04)
        #expect(panel.alphaValue == 1 && layer.opacity == 0 && panel.isVisible && presentation.isActive)
        try await Task.sleep(for:.milliseconds(15))
        #expect(panel.isVisible && presentation.isActive)
        try await Task.sleep(for:.milliseconds(130))
        #expect(!panel.isVisible && panel.contentView == nil && !presentation.isActive)
    }
    @Test func zeroMotionBackdropHasNoAnimationOrImageFade() throws {
        let fixture=try Fixture();defer { fixture.close() }
        CaptureBackdropTransition.show(fixture.panel,duration:0)
        let shade=try #require(fixture.view.subviews.compactMap { $0 as? CaptureSelectionBackdropView }.first)
        #expect(fixture.panel.alphaValue == 1 && shade.layer?.opacity == 1)
        #expect(shade.layer?.animation(forKey:CaptureSelectionBackdropView.animationKey) == nil)
        fixture.view.cancelRefresh()
        #expect(shade.layer?.animationKeys()?.isEmpty != false)
    }
    @Test(arguments:[1,2]) func nativeSnapshotDrawingPreservesSinglePixelLinesAtMatchingScale(factor:Int) throws {
        let domain="CaptureSharpPixels-"+UUID().uuidString,defaults=try #require(UserDefaults(suiteName:domain))
        defer { defaults.removePersistentDomain(forName:domain) }
        let source=try CaptureImage.context(width:400*factor,height:300*factor)
        source.setFillColor(NSColor.black.cgColor);source.fill(CGRect(x:0,y:0,width:400*factor,height:300*factor))
        source.setFillColor(NSColor.white.cgColor)
        for x in stride(from:0,to:400*factor,by:2) { source.fill(CGRect(x:x,y:0,width:1,height:300*factor)) }
        let view=CaptureSelectionView(image:try #require(source.makeImage()),allowsShapes:true,sessionDefaults:defaults)
        let panel=NSPanel(contentRect:CGRect(x:0,y:0,width:400,height:300),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.contentView=view
        defer { view.cancelRefresh();panel.close();panel.contentView=nil }
        let output=try CaptureImage.context(width:400*factor,height:300*factor)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=NSGraphicsContext(cgContext:output,flipped:true)
        output.translateBy(x:0,y:CGFloat(300*factor));output.scaleBy(x:CGFloat(factor),y:-CGFloat(factor))
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let bitmap=NSBitmapImageRep(cgImage:try #require(output.makeImage()))
        for x in 40..<52 {
            let color=try #require(bitmap.colorAt(x:x,y:100)?.usingColorSpace(.deviceRGB))
            #expect(x.isMultiple(of:2) ? color.redComponent>0.99 : color.redComponent<0.01)
        }
    }
    @Test(arguments:[1,2]) func fractionalSelectionKeepsPixelSharpnessAndAnnotationCoordinates(factor:Int) throws {
        let domain="CaptureFractionalPixels-"+UUID().uuidString,defaults=try #require(UserDefaults(suiteName:domain))
        defer { defaults.removePersistentDomain(forName:domain) }
        let source=try CaptureImage.context(width:400*factor,height:300*factor)
        source.setFillColor(NSColor.black.cgColor);source.fill(CGRect(x:0,y:0,width:400*factor,height:300*factor))
        source.setFillColor(NSColor.white.cgColor)
        for x in stride(from:0,to:400*factor,by:2) { source.fill(CGRect(x:x,y:0,width:1,height:300*factor)) }
        let view=CaptureSelectionView(image:try #require(source.makeImage()),allowsShapes:true,sessionDefaults:defaults)
        let panel=NSPanel(contentRect:CGRect(x:0,y:0,width:400,height:300),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.contentView=view
        defer { view.cancelRefresh();panel.close();panel.contentView=nil }
        try drag(view,from:CGPoint(x:20.35,y:30.4),to:CGPoint(x:280.6,y:210.55))
        let selected=try #require(view.selected),pixels=try #require(view.session.document.captureViewport)
        #expect(abs(selected.minX-20.35)<0.00001 && abs(selected.width-260.25)<0.00001)
        #expect(view.session.sizeLabel == "\(Int(pixels.width)) × \(Int(pixels.height))")
        let canvas=try #require(descendants(view).compactMap { $0 as? CaptureDrawingView }.first)
        func render(_ includeCanvas:Bool) throws -> NSBitmapImageRep {
            let context=try CaptureImage.context(width:400*factor,height:300*factor)
            NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
            context.translateBy(x:0,y:CGFloat(300*factor));context.scaleBy(x:CGFloat(factor),y:-CGFloat(factor))
            view.draw(view.bounds)
            if includeCanvas {
                context.saveGState();context.translateBy(x:canvas.frame.minX,y:canvas.frame.minY)
                canvas.draw(canvas.bounds);context.restoreGState()
            }
            return NSBitmapImageRep(cgImage:try #require(context.makeImage()))
        }
        for activeTool in [CaptureTool.move,.rectangle] {
            if activeTool != view.session.tool { view.session.selectTool(activeTool) }
            let expected=CGRect(x:pixels.minX/CGFloat(factor),y:pixels.minY/CGFloat(factor),width:pixels.width/CGFloat(factor),height:pixels.height/CGFloat(factor))
            #expect(canvas.frame == expected && canvas.coordinateOrigin == pixels.origin)
            let bitmap=try render(activeTool != .move)
            for x in (40*factor)..<(70*factor) {
                let color=try #require(bitmap.colorAt(x:x,y:80*factor)?.usingColorSpace(.deviceRGB))
                #expect(x.isMultiple(of:2) ? color.redComponent>0.99 : color.redComponent<0.01)
            }
        }
        let a=CGPoint(x:80.75,y:100.25),b=CGPoint(x:120.6,y:130.55)
        canvas.mouseDown(with:try event(.leftMouseDown,point:a,in:view))
        canvas.mouseDragged(with:try event(.leftMouseDragged,point:b,in:view))
        canvas.mouseUp(with:try event(.leftMouseUp,point:b,in:view))
        let mark=try #require(view.session.document.marks.last)
        #expect(abs(mark.points[0].x-a.x*CGFloat(factor))<0.00001 && abs(mark.points[0].y-a.y*CGFloat(factor))<0.00001)
        #expect(abs(mark.points[1].x-b.x*CGFloat(factor))<0.00001 && abs(mark.points[1].y-b.y*CGFloat(factor))<0.00001)
    }
    @Test func releaseLifecycleProbe() async throws {
        guard let path=ProcessInfo.processInfo.environment["UNTITLED_CAPTURE_SESSION_PROBE_PATH"] else { return }
        let domain="CaptureSessionProbe-"+UUID().uuidString,defaults=try #require(UserDefaults(suiteName:domain))
        defer { defaults.removePersistentDomain(forName:domain) }
        var samples:[[String:Any]]=[],ownership:[[String:Any]]=[]
        func sample(_ phase:String,_ round:Int) {
            var entry:[String:Any]=["phase":phase,"round":round,"uptime":ProcessInfo.processInfo.systemUptime]
            if let bytes=footprint() { entry["footprintBytes"]=bytes } else { entry["footprintStatus"]="unavailable" }
            samples.append(entry)
        }
        sample("baseline",0)
        for round in 1...10 {
            weak var released:CaptureSelectionSession?
            weak var sourcePanel:NSPanel?,sourceView:CaptureSelectionView?,lease:CaptureSelectionPresentation?
            try autoreleasepool {
                let context=try CaptureImage.context(width:3840,height:2160)
                context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:3840,height:2160))
                let image=try #require(context.makeImage())
                let view=CaptureSelectionView(image:image,allowsShapes:true,sessionDefaults:defaults)
                released=view.session
                let panel=NSPanel(contentRect:CGRect(x:0,y:0,width:1920,height:1080),styleMask:[.borderless],backing:.buffered,defer:false)
                sourcePanel=panel;sourceView=view
                panel.isReleasedWhenClosed=false;panel.contentView=view;CaptureBackdropTransition.show(panel,duration:0.06);panel.displayIfNeeded()
                sample("source",round)
                try drag(view,from:CGPoint(x:80,y:80),to:CGPoint(x:1000,y:700))
                view.session.addMark(CaptureMark(tool:.rectangle,points:[CGPoint(x:200,y:200),CGPoint(x:1200,y:900)],color:.red,width:6))
                panel.displayIfNeeded();sample("annotated",round)
                let output=try view.prepareSelectionExport()
                #expect(output.image.width == 1840)
                sample("export",round)
                view.prepareForHandoff()
                let presentation=CaptureSelectionPresentation(panels:[panel]);lease=presentation
                presentation.beginHandoff(above:[],duration:0.04)
            }
            try await Task.sleep(for:.milliseconds(180))
            ownership.append(["round":round,"sessionReleased":released == nil,"viewReleased":sourceView == nil,"panelReleased":sourcePanel == nil,"panelVisible":sourcePanel?.isVisible ?? false,"panelDetached":sourcePanel?.contentView == nil,"leaseActive":lease?.isActive ?? false,"leaseReleased":lease == nil])
            let sessionReleasedOnDeadline=released == nil
            #expect(sessionReleasedOnDeadline)
            sample("released",round)
        }
        let output=URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data:[String:Any]=["input":"synthetic 3840x2160; opaque native window, vector shade entrance/exit, crop, annotation, export; no capture/clipboard/PNG","configuration":ProcessInfo.processInfo.environment["UNTITLED_CAPTURE_SESSION_PROBE_CONFIGURATION"] ?? "unspecified","samples":samples,"ownershipAt180ms":ownership]
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    }
    private func footprint()->UInt64? {
        var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint:nil
    }
    private func finish(_ session:CaptureSelectionSession) async throws {
        for _ in 0..<100 { if !session.exporting { return };try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("Output did not settle")
    }
    private func drag(_ view:CaptureSelectionView,from start:CGPoint,to end:CGPoint) throws {
        view.mouseDown(with:try event(.leftMouseDown,point:start,in:view))
        view.mouseDragged(with:try event(.leftMouseDragged,point:end,in:view))
        view.mouseUp(with:try event(.leftMouseUp,point:end,in:view))
    }
    private func event(_ type:NSEvent.EventType,point:CGPoint,in view:NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:view.window?.windowNumber ?? 0,context:nil,eventNumber:1,clickCount:1,pressure:1))
    }
    private func key(_ code:UInt16,flags:NSEvent.ModifierFlags,in window:NSWindow,type:NSEvent.EventType = .keyDown) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code))
    }
    private func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor private final class ToolbarBounds { var frames:[String:CGRect]=[:] }
    @MainActor private final class Fixture {
        let view:CaptureSelectionView
        let panel:NSPanel
        let domain="CaptureSession-"+UUID().uuidString
        let defaults:UserDefaults
        init(scale:Int=1) throws {
            defaults=try #require(UserDefaults(suiteName:domain))
            let context=try CaptureImage.context(width:400*scale,height:300*scale)
            context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:400*scale,height:300*scale))
            context.setFillColor(NSColor.blue.cgColor);context.fill(CGRect(x:200*scale,y:0,width:200*scale,height:300*scale))
            view=CaptureSelectionView(image:try #require(context.makeImage()),allowsShapes:true,sessionDefaults:defaults)
            panel=NSPanel(contentRect:CGRect(x:0,y:0,width:400,height:300),styleMask:[.borderless],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false;panel.contentView=view
        }
        func close() { view.cancelRefresh();panel.close();panel.contentView=nil;defaults.removePersistentDomain(forName:domain) }
    }
}
