import AppKit
import QuartzCore
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor
struct CaptureHoverTransitionTests {
    @Test func changingFromASmallElementToItsWindowAnimatesOnlyTheVectorGeometry() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100))
        #expect(fixture.view.selected == Fixture.leaf)
        try await fixture.expandToWindow()
        #expect(fixture.view.selected == Fixture.area)
        let animation=fixture.backdrop.layer?.animation(forKey:"capture.hover.path") as? CABasicAnimation
        #expect(animation != nil)
        #expect(animation?.keyPath == "path")
        #expect(animation?.duration == 0.12)
        #expect(fixture.panel.alphaValue == 1)
        #expect(fixture.view.image === fixture.image)
    }

    @Test func theHoleAndOutlineUseTheSameEndpointsAndStablePathTopology() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));try await fixture.expandToWindow()
        let shade=try #require(fixture.backdrop.layer as? CAShapeLayer)
        let hole=try #require(shade.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) as? CABasicAnimation)
        let outline=try #require(fixture.outline.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) as? CABasicAnimation)
        #expect(shade.fillRule == .evenOdd)
        #expect(try rectangles(path(hole.fromValue)) == [Fixture.area,Fixture.leaf])
        #expect(try rectangles(path(hole.toValue)) == [Fixture.area,Fixture.area])
        #expect(try path(outline.fromValue).boundingBoxOfPath == Fixture.leaf)
        #expect(try path(outline.toValue).boundingBoxOfPath == Fixture.area)
        #expect(hole.beginTime == outline.beginTime && hole.duration == outline.duration)
        #expect(shade.contents == nil && fixture.outline.contents == nil && !shade.shouldRasterize)
        #expect(fixture.outline.lineWidth == 1.5)
    }

    @Test func stableHitsDoNotRestartOrQueueAnimations() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));try await fixture.expandToWindow()
        let first=try #require(fixture.backdrop.layer?.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey))
        for x in 600..<620 { fixture.move(to:CGPoint(x:x,y:450)) }
        let current=try #require(fixture.backdrop.layer?.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey))
        #expect(current.beginTime == first.beginTime)
        #expect(fixture.backdrop.layer?.animationKeys() == [CaptureSelectionBackdropView.hoverAnimationKey])
        #expect(fixture.outline.animationKeys() == [CaptureSelectionBackdropView.hoverAnimationKey])
        #expect(fixture.backdrop.layer?.sublayers?.count == 1)
    }

    @Test func retargetingBeforeTheFirstCommitDoesNotJumpToAnUnseenTarget() throws {
        let shade=CaptureSelectionBackdropView(frame:Fixture.area)
        shade.updateHoverGeometry(Fixture.area,rect:Fixture.leaf,duration:0)
        shade.updateHoverGeometry(Fixture.area,rect:Fixture.area,duration:0.12)
        let next=CGRect(x:400,y:300,width:80,height:60)
        shade.updateHoverGeometry(Fixture.area,rect:next,duration:0.12)
        let outline=try #require(shade.layer?.sublayers?.first)
        let animation=try #require(outline.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) as? CABasicAnimation)
        #expect(try path(animation.fromValue).boundingBoxOfPath == Fixture.leaf)
        #expect(try path(animation.toValue).boundingBoxOfPath == next)
        #expect(shade.presentedHoverRect == Fixture.leaf)
        shade.cancelAnimations()
    }

    @Test func nativePresentationHasAMiddlePoseAndRetargetsFromThatVisiblePose() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.panel.orderFrontRegardless()
        fixture.move(to:CGPoint(x:100,y:100));CATransaction.flush()
        try await Task.sleep(for:.milliseconds(35))
        try await fixture.expandToWindow();CATransaction.flush()
        try await Task.sleep(for:.milliseconds(35))
        let layer=try #require(fixture.backdrop.layer)
        let visible=try #require(fixture.outline.presentation()?.path?.boundingBoxOfPath)
        #expect(visible != Fixture.leaf && visible != Fixture.area && Fixture.area.contains(visible))
        // Freeze before reading both layers: two independent presentation()
        // calls can otherwise straddle a WindowServer display refresh. Both
        // paths must match and restart from this same visible native pose.
        let paused=layer.convertTime(CACurrentMediaTime(),from:nil)
        layer.speed=0;layer.timeOffset=paused;CATransaction.flush()
        try await Task.sleep(for:.milliseconds(25))
        let frozen=try #require(fixture.backdrop.presentedHoverRect)
        let shadePath=try #require((layer.presentation() as? CAShapeLayer)?.path)
        let frozenHole=try #require(rectangles(shadePath).last)
        #expect(distance(frozenHole,frozen)<0.01,"hole: \(frozenHole), outline: \(frozen)")
        let next=CGRect(x:450,y:350,width:90,height:80)
        fixture.backdrop.updateHoverGeometry(Fixture.area,rect:next,duration:0.12)
        let border=try #require(fixture.outline.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) as? CABasicAnimation)
        let hole=try #require(layer.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) as? CABasicAnimation)
        #expect(try distance(path(border.fromValue).boundingBoxOfPath,frozen)<0.01)
        #expect(try rectangles(path(hole.fromValue)).last.map { distance($0,frozen)<0.01 } == true)
    }

    @Test func aKnownHierarchyKeepsRepeatedFailedQueriesOutOfNativeAnimationTargets() async throws {
        let parent=CGRect(x:40,y:40,width:500,height:400)
        var probes=0
        let fixture=try Fixture(hitResolver:{ point in
            if Fixture.leaf.contains(point) { return CaptureElementHit(rect:Fixture.leaf,ancestors:[parent,Fixture.area]) }
            probes+=1
            return probes<=3 ? nil:CaptureElementHit(rect:parent,ancestors:[Fixture.area])
        });defer { fixture.close() }
        fixture.panel.orderFrontRegardless();fixture.move(to:CGPoint(x:100,y:100));CATransaction.flush()
        try await Task.sleep(for:.milliseconds(30))
        fixture.move(to:CGPoint(x:300,y:220))
        #expect(fixture.view.selected == Fixture.leaf)
        #expect(fixture.outline.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) == nil)
        for _ in 0..<4 {
            try await Task.sleep(for:.milliseconds(90))
            fixture.move(to:CGPoint(x:301,y:220));CATransaction.flush()
            #expect(fixture.view.selected == (probes<4 ? Fixture.leaf:parent))
            #expect(parent.insetBy(dx:-0.01,dy:-0.01).contains(try #require(fixture.backdrop.presentedHoverRect)))
        }
        #expect(fixture.view.selected == parent && probes == 5 && fixture.panel.alphaValue == 1 && fixture.view.image === fixture.image)
    }

    @Test func aSuccessfulRefreshDiscardsHierarchyRebuiltWhileTheNewImageWasAwaited() async throws {
        let parent=CGRect(x:40,y:40,width:500,height:400)
        var oldImage=true,continuation:CheckedContinuation<CGImage,Never>?
        let fixture=try Fixture(hitResolver:{ point in
            guard Fixture.leaf.contains(point) else { return CaptureElementHit(rect:parent,limited:true) }
            return CaptureElementHit(rect:Fixture.leaf,ancestors:oldImage ? [parent,Fixture.area]:[])
        });defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100))
        fixture.view.refresh={ await withCheckedContinuation { continuation=$0 } }
        fixture.view.refreshCaptureImage()
        for _ in 0..<40 { if continuation != nil { break };try await Task.sleep(for:.milliseconds(5)) }
        let pending=try #require(continuation)
        fixture.move(to:CGPoint(x:100,y:100))
        let context=try CaptureImage.context(width:800,height:600),replacement=try #require(context.makeImage())
        oldImage=false;pending.resume(returning:replacement)
        for _ in 0..<40 { if fixture.view.image === replacement { break };try await Task.sleep(for:.milliseconds(5)) }
        #expect(fixture.view.image === replacement)
        fixture.move(to:CGPoint(x:300,y:220))
        #expect(fixture.view.selected == parent)
    }

    @Test func returningInsideTheLeafCancelsPendingValidationWithoutAnExpiryFlash() async throws {
        var available=true,probes=0
        let fixture=try Fixture(hitResolver:{ _ in probes+=1;return available ? CaptureElementHit(rect:Fixture.leaf,ancestors:[Fixture.area]):nil });defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));available=false
        fixture.move(to:CGPoint(x:300,y:220));fixture.move(to:CGPoint(x:100,y:100))
        let settled=probes
        try await Task.sleep(for:.milliseconds(330))
        #expect(fixture.view.selected == Fixture.leaf && probes == settled)
    }

    @Test(arguments:[0,1,2,3]) func uncertainTargetsConvergeWithoutAnotherMouseMoveAndNeverPaintAnUnconfirmedAncestor(mode:Int) async throws {
        let parent=CGRect(x:40,y:40,width:500,height:400)
        let sibling=mode == 3 ? CGRect(x:250,y:180,width:200,height:150):CGRect(x:200,y:150,width:550,height:420)
        var probes=0
        let fixture=try Fixture(hitResolver:{ point in
            if Fixture.leaf.contains(point) { return CaptureElementHit(rect:Fixture.leaf,ancestors:[parent,Fixture.area]) }
            probes+=1
            if probes == 1 || mode == 2 { return nil }
            return CaptureElementHit(rect:mode == 0 || mode == 3 ? sibling:Fixture.area)
        });defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));fixture.move(to:CGPoint(x:300,y:220))
        #expect(fixture.view.selected == Fixture.leaf)
        let target=mode == 0 || mode == 3 ? sibling:Fixture.area
        for _ in 0..<80 { if fixture.view.selected == target { break };try await Task.sleep(for:.milliseconds(5)) }
        #expect(fixture.view.selected == target && probes<=3)
        let settled=probes
        try await Task.sleep(for:.milliseconds(100))
        #expect(probes == settled)
    }

    @Test(arguments:[true,false]) func anUncertainBoundarySettlesWithoutShowingTheOversizedAncestorEvenWhenTheMouseStops(missing:Bool) async throws {
        let parent=CGRect(x:40,y:40,width:500,height:400)
        var probes=0
        let fixture=try Fixture(hitResolver:{ point in
            if Fixture.leaf.contains(point) { return CaptureElementHit(rect:Fixture.leaf,ancestors:[parent,Fixture.area]) }
            probes+=1
            return probes == 1 ? (missing ? nil:CaptureElementHit(rect:Fixture.area,limited:true)):CaptureElementHit(rect:parent)
        });defer { fixture.close() }
        fixture.panel.orderFrontRegardless()
        fixture.move(to:CGPoint(x:100,y:100));CATransaction.flush()
        try await Task.sleep(for:.milliseconds(25))
        fixture.move(to:CGPoint(x:300,y:220))
        #expect(fixture.view.selected == Fixture.leaf && fixture.backdrop.presentedHoverRect == Fixture.leaf)
        for _ in 0..<40 { if fixture.view.selected == parent { break };try await Task.sleep(for:.milliseconds(5)) }
        #expect(fixture.view.selected == parent && probes == 2)
        CATransaction.flush()
        for _ in 0..<10 {
            try await Task.sleep(for:.milliseconds(16))
            let visible=try #require(fixture.backdrop.presentedHoverRect)
            #expect(parent.insetBy(dx:-0.01,dy:-0.01).contains(visible))
        }
        #expect(probes == 2 && fixture.view.image === fixture.image && fixture.panel.alphaValue == 1)
    }

    @Test func clickingDuringBoundaryConfirmationUsesTheFreshParentAndCancelsTheRetry() async throws {
        let parent=CGRect(x:40,y:40,width:500,height:400)
        var probes=0
        let fixture=try Fixture(hitResolver:{ point in
            if Fixture.leaf.contains(point) { return CaptureElementHit(rect:Fixture.leaf,ancestors:[parent,Fixture.area]) }
            probes+=1;return probes == 1 ? CaptureElementHit(rect:Fixture.area,limited:true):CaptureElementHit(rect:parent)
        });defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));fixture.move(to:CGPoint(x:300,y:220))
        #expect(fixture.view.selected == Fixture.leaf)
        fixture.view.mouseDown(with:fixture.event(.leftMouseDown,at:CGPoint(x:300,y:220)))
        fixture.view.mouseUp(with:fixture.event(.leftMouseUp,at:CGPoint(x:300,y:220)))
        #expect(fixture.view.selected == parent && fixture.view.session.document.captureViewport == parent)
        try await Task.sleep(for:.milliseconds(70))
        #expect(fixture.view.session.hasSelection && probes == 2)
    }

    @Test(arguments:Stop.allCases) func stoppingDuringBoundaryConfirmationCancelsTheSingleRetry(stop:Stop) async throws {
        var probes=0
        let fixture=try Fixture(hitResolver:{ point in probes+=1;return Fixture.leaf.contains(point) ? CaptureElementHit(rect:Fixture.leaf,ancestors:[Fixture.area]):CaptureElementHit(rect:Fixture.area,limited:true) });defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));fixture.move(to:CGPoint(x:600,y:450))
        #expect(probes == 2 && fixture.view.selected == Fixture.leaf)
        switch stop {
        case .reset:fixture.view.resetCaptureSelection()
        case .cancel:fixture.view.cancelRefresh()
        case .handoff:fixture.view.prepareForHandoff()
        case .detach:fixture.panel.contentView=nil
        case .polygon:fixture.view.setCaptureShape(.polygon)
        case .operation:fixture.view.setCaptureOperation(1)
        }
        try await Task.sleep(for:.milliseconds(70))
        #expect(probes == 2)
    }

    @Test func aCompletedTransitionHasNoAnimationLeftRunning() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.panel.orderFrontRegardless()
        fixture.move(to:CGPoint(x:100,y:100));CATransaction.flush()
        try await Task.sleep(for:.milliseconds(25))
        fixture.move(to:CGPoint(x:600,y:450));CATransaction.flush()
        try await Task.sleep(for:.milliseconds(190))
        #expect(fixture.backdrop.layer?.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) == nil)
        #expect(fixture.outline.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) == nil)
        #expect(fixture.backdrop.presentedHoverRect == Fixture.area)
    }

    @Test func reducedMotionSkipsBothPathAnimationsAndKeepsTheExactTarget() async throws {
        let fixture=try Fixture(reduceMotion:true);defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));try await fixture.expandToWindow()
        #expect(fixture.view.selected == Fixture.area && fixture.outline.path?.boundingBoxOfPath == Fixture.area)
        #expect(fixture.backdrop.layer?.animationKeys()?.isEmpty != false && fixture.outline.animationKeys()?.isEmpty != false)
    }

    @Test func aClickDuringTheTweenUsesAFreshHitNotTheDisplayedIntermediateFrame() async throws {
        var hit=Fixture.leaf
        let fixture=try Fixture(resolver:{ Fixture.leaf.contains($0) ? hit:Fixture.area });defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));try await fixture.expandToWindow()
        hit=CGRect(x:90,y:80,width:40,height:30)
        fixture.view.mouseDown(with:fixture.event(.leftMouseDown,at:CGPoint(x:100,y:100)))
        #expect(fixture.view.selected == hit && !fixture.backdrop.presentsHover)
        #expect(fixture.backdrop.layer?.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) == nil)
        #expect(fixture.outline.isHidden && fixture.outline.animationKeys()?.isEmpty != false)
        let shade=try #require(fixture.backdrop.layer as? CAShapeLayer)
        #expect(!shade.path!.contains(CGPoint(x:100,y:100)) && shade.path!.contains(CGPoint(x:600,y:450)))
        fixture.view.mouseUp(with:fixture.event(.leftMouseUp,at:CGPoint(x:100,y:100)))
        #expect(fixture.view.session.hasSelection && fixture.view.session.document.captureViewport == hit)
    }

    @Test func draggingSnapsTheChromeAndNeverEasesTheManualRange() async throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));try await fixture.expandToWindow()
        fixture.view.mouseDown(with:fixture.event(.leftMouseDown,at:CGPoint(x:400,y:300)))
        fixture.view.mouseDragged(with:fixture.event(.leftMouseDragged,at:CGPoint(x:650,y:500)))
        #expect(fixture.view.selected == CGRect(x:400,y:300,width:250,height:200))
        #expect(!fixture.backdrop.presentsHover && fixture.outline.isHidden)
        #expect(fixture.backdrop.layer?.animation(forKey:CaptureSelectionBackdropView.hoverAnimationKey) == nil)
        fixture.view.mouseUp(with:fixture.event(.leftMouseUp,at:CGPoint(x:650,y:500)))
        #expect(fixture.view.session.hasSelection)
    }

    enum Stop:CaseIterable,Sendable { case reset,cancel,handoff,detach,polygon,operation }
    @Test(arguments:Stop.allCases)
    func endingHoverStopsBothAnimationsImmediately(stop:Stop) async throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));try await fixture.expandToWindow()
        switch stop {
        case .reset: fixture.view.resetCaptureSelection()
        case .cancel: fixture.view.cancelRefresh()
        case .handoff: fixture.view.prepareForHandoff()
        case .detach: fixture.panel.contentView=nil
        case .polygon: fixture.view.setCaptureShape(.polygon)
        case .operation: fixture.view.setCaptureOperation(1)
        }
        #expect(fixture.backdrop.layer?.animationKeys()?.isEmpty != false)
        #expect(fixture.outline.animationKeys()?.isEmpty != false)
    }

    @Test func complexGeometryUsesTheOriginalBooleanMaskWithoutAnInterpolatedContour() throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100));fixture.move(to:CGPoint(x:600,y:450))
        let mask=CGPath(rect:Fixture.leaf,transform:nil).union(CGPath(rect:CGRect(x:400,y:300,width:100,height:80),transform:nil),using:.winding)
        fixture.backdrop.updateGeometry(Fixture.area,undimmed:mask)
        let shape=try #require(fixture.backdrop.layer as? CAShapeLayer)
        #expect(shape.fillRule == .nonZero && fixture.outline.isHidden)
        #expect(!shape.path!.contains(CGPoint(x:100,y:100)) && !shape.path!.contains(CGPoint(x:450,y:340)))
        #expect(shape.path!.contains(CGPoint(x:700,y:500)) && shape.animationKeys()?.isEmpty != false)
    }

    @Test(arguments:[1,2]) func hoveringKeepsFrozenSourcePixelsAndImageGeometryExact(factor:Int) async throws {
        let fixture=try Fixture(factor:factor,stripes:true);defer { fixture.close() }
        let frame=fixture.view.frame,bounds=fixture.view.bounds
        let before=try renderSource(fixture)
        fixture.move(to:CGPoint(x:100,y:100));try await fixture.expandToWindow()
        let after=try renderSource(fixture)
        #expect(fixture.view.image === fixture.image && fixture.view.frame == frame && fixture.view.bounds == bounds)
        #expect(fixture.view.alphaValue == 1 && fixture.panel.alphaValue == 1)
        for x in 40..<70 {
            let a=try #require(before.colorAt(x:x,y:100)?.usingColorSpace(.deviceRGB))
            let b=try #require(after.colorAt(x:x,y:100)?.usingColorSpace(.deviceRGB))
            #expect(a.redComponent == b.redComponent)
            #expect(x.isMultiple(of:2) ? b.redComponent>0.99:b.redComponent<0.01)
        }
    }

    @Test func vectorRenderingPlacesTheOutlineOnTheSameHoleRatherThanMirroringIt() throws {
        let fixture=try Fixture();defer { fixture.close() }
        fixture.move(to:CGPoint(x:100,y:100))
        let context=try CaptureImage.context(width:800,height:600)
        fixture.backdrop.layer!.render(in:context)
        let bytes=try #require(context.data?.assumingMemoryBound(to:UInt8.self))
        var hole=CGRect.null,border=CGRect.null
        for y in 0..<600 { for x in 0..<800 {
            let alpha=bytes[y*context.bytesPerRow+x*4+3]
            let pixel=CGRect(x:x,y:y,width:1,height:1)
            if alpha == 0 { hole=hole.union(pixel) }
            if alpha>150 { border=border.union(pixel) }
        } }
        #expect(!hole.isNull && !border.isNull)
        #expect(abs(hole.midX-border.midX)<1 && abs(hole.midY-border.midY)<1)
    }

    @Test func hoverLifecycleProbe() async throws {
        guard let path=ProcessInfo.processInfo.environment["UNTITLED_CAPTURE_HOVER_PROBE_PATH"] else { return }
        let domain="CaptureHoverProbe-"+UUID().uuidString,defaults=try #require(UserDefaults(suiteName:domain))
        defer { defaults.removePersistentDomain(forName:domain) }
        var samples:[[String:Any]]=[]
        func sample(_ phase:String,_ round:Int) {
            var entry:[String:Any]=["phase":phase,"round":round,"uptime":ProcessInfo.processInfo.systemUptime]
            if let value=footprint() { entry["footprintBytes"]=value } else { entry["footprintStatus"]="unavailable" }
            samples.append(entry)
        }
        sample("baseline",0)
        for round in 1...10 {
            let weak=WeakReferences()
            try autoreleasepool {
                let context=try CaptureImage.context(width:3840,height:2160)
                context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:3840,height:2160))
                let view=CaptureSelectionView(image:try #require(context.makeImage()),allowsShapes:true,
                    elementHitResolver:{ $0.x<300 ? CaptureElementHit(rect:CGRect(x:80,y:70,width:240,height:180),ancestors:[CGRect(x:30,y:20,width:1600,height:900),CGRect(x:0,y:0,width:1920,height:1080)]):nil },
                    sessionDefaults:defaults,hoverReduceMotion:{ false })
                let panel=NSPanel(contentRect:CGRect(x:0,y:0,width:1920,height:1080),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.isReleasedWhenClosed=false;panel.contentView=view;panel.orderFrontRegardless();panel.displayIfNeeded()
                let shade=try #require(view.subviews.compactMap { $0 as? CaptureSelectionBackdropView }.first)
                weak.view=view;weak.session=view.session;weak.shade=shade
                sample("source",round)
                let a=CGRect(x:80,y:70,width:240,height:180),b=CGRect(x:30,y:20,width:1600,height:900)
                shade.updateHoverGeometry(view.bounds,rect:a,duration:0)
                for index in 0..<200 {
                    shade.updateHoverGeometry(view.bounds,rect:index.isMultiple(of:2) ? b:a,duration:0.12)
                    let layers=[shade.layer!]+(shade.layer?.sublayers ?? [])
                    #expect(layers.reduce(0) { $0+($1.animationKeys()?.count ?? 0) }<=2)
                }
                CATransaction.flush();sample("retargeted",round)
                view.windows=[view.bounds]
                for point in [CGPoint(x:100,y:100),CGPoint(x:600,y:450)] {
                    view.mouseMoved(with:try #require(NSEvent.mouseEvent(with:.mouseMoved,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)))
                }
                view.cancelRefresh();panel.orderOut(nil);panel.close();panel.contentView=nil
                #expect(shade.layer?.animationKeys()?.isEmpty != false)
                #expect(shade.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true)
            }
            try await Task.sleep(for:.milliseconds(120))
            #expect(weak.view == nil && weak.session == nil && weak.shade == nil)
            sample("released",round)
        }
        let destination=URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let result:[String:Any]=["input":"synthetic 3840x2160; ten native windows, 200 vector retargets and one canceled uncertainty episode each; no screen capture, clipboard, PNG or AX query",
            "configuration":ProcessInfo.processInfo.environment["UNTITLED_CAPTURE_HOVER_PROBE_CONFIGURATION"] ?? "unspecified","samples":samples]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.atomic)
    }
    @MainActor private final class WeakReferences {
        weak var view:CaptureSelectionView?
        weak var session:CaptureSelectionSession?
        weak var shade:CaptureSelectionBackdropView?
    }
    private func footprint()->UInt64? {
        var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint:nil
    }

    private func renderSource(_ fixture:Fixture) throws -> NSBitmapImageRep {
        let context=try CaptureImage.context(width:fixture.image.width,height:fixture.image.height)
        let scale=CGFloat(fixture.image.width)/Fixture.area.width
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
        context.translateBy(x:0,y:CGFloat(fixture.image.height));context.scaleBy(x:scale,y:-scale)
        fixture.view.draw(fixture.view.bounds)
        return NSBitmapImageRep(cgImage:try #require(context.makeImage()))
    }
    private func path(_ value:Any?) throws -> CGPath {
        let value=try #require(value)
        try #require(CFGetTypeID(value as CFTypeRef) == CGPath.typeID)
        return value as! CGPath
    }
    private func rectangles(_ path:CGPath)->[CGRect] {
        var result:[CGRect]=[],points:[CGPoint]=[]
        path.applyWithBlock { pointer in
            let element=pointer.pointee
            switch element.type {
            case .moveToPoint: points=[element.points[0]]
            case .addLineToPoint: points.append(element.points[0])
            // Core Animation normalizes presentation paths to cubic segments,
            // even though our model rectangles contain only straight lines.
            case .addQuadCurveToPoint: points.append(contentsOf:[element.points[0],element.points[1]])
            case .addCurveToPoint: points.append(contentsOf:[element.points[0],element.points[1],element.points[2]])
            case .closeSubpath: if let rect=CaptureSelectionGeometry.bounds(of:points) { result.append(rect) };points=[]
            default: break
            }
        }
        return result
    }
    private func distance(_ a:CGRect,_ b:CGRect)->CGFloat {
        max(abs(a.minX-b.minX),abs(a.minY-b.minY),abs(a.width-b.width),abs(a.height-b.height))
    }

    @MainActor private final class Fixture {
        static let area=CGRect(x:0,y:0,width:800,height:600)
        static let leaf=CGRect(x:80,y:70,width:160,height:100)
        let domain="CaptureHover-"+UUID().uuidString
        let image:CGImage
        let view:CaptureSelectionView
        let panel:NSPanel
        var backdrop:CaptureSelectionBackdropView { view.subviews.compactMap { $0 as? CaptureSelectionBackdropView }.first! }
        var outline:CAShapeLayer { backdrop.layer!.sublayers!.first { $0.name == CaptureSelectionBackdropView.hoverOutlineName } as! CAShapeLayer }
        init(reduceMotion:Bool=false,resolver:((CGPoint)->CGRect?)?=nil,hitResolver:((CGPoint)->CaptureElementHit?)?=nil,factor:Int=1,stripes:Bool=false) throws {
            let context=try CaptureImage.context(width:800*factor,height:600*factor)
            context.setFillColor(NSColor.black.cgColor);context.fill(CGRect(x:0,y:0,width:800*factor,height:600*factor))
            context.setFillColor(NSColor.white.cgColor)
            if stripes { for x in stride(from:0,to:800*factor,by:2) { context.fill(CGRect(x:x,y:0,width:1,height:600*factor)) } }
            else { context.fill(CGRect(x:0,y:0,width:800*factor,height:600*factor)) }
            image=try #require(context.makeImage())
            let defaults=try #require(UserDefaults(suiteName:domain))
            view=CaptureSelectionView(image:image,allowsShapes:true,
                elementResolver:resolver ?? { Self.leaf.contains($0) ? Self.leaf:Self.area },elementHitResolver:hitResolver,sessionDefaults:defaults,hoverReduceMotion:{ reduceMotion })
            panel=NSPanel(contentRect:Self.area,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false;panel.contentView=view;view.windows=[Self.area]
            view.layoutSubtreeIfNeeded()
        }
        func move(to point:CGPoint) {
            view.mouseMoved(with:event(.mouseMoved,at:point))
        }
        func expandToWindow() async throws {
            move(to:CGPoint(x:600,y:450))
            for _ in 0..<40 { if view.selected == Self.area { return };try await Task.sleep(for:.milliseconds(5)) }
            Issue.record("Ancestor boundary re-probe did not settle")
        }
        func event(_ type:NSEvent.EventType,at point:CGPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        func close() {
            view.cancelRefresh();panel.orderOut(nil);panel.close();panel.contentView=nil
            UserDefaults.standard.removePersistentDomain(forName:domain)
        }
    }
}
