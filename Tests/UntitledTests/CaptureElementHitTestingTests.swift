import AppKit
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@MainActor struct CaptureElementHitTestingTests {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let leaf = CGRect(x: 20, y: 20, width: 100, height: 80)

    @Test func videoPaddingUsesAReacquiredLiveParentRatherThanTheBroadHitRoot() throws {
        let coarse=CGRect(x:113,y:92,width:958,height:958),parent=CGRect(x:189,y:239,width:807,height:291)
        let text=CGRect(x:204,y:446,width:776,height:51),point=CGPoint(x:322,y:510)
        let frames=[coarse,parent,text],parents=[Int?.none,0,1]
        var visited=1,depth=0
        let routed=CaptureElementHitTesting.freshAncestor(from:2,at:point,within:coarse,smallerThan:coarse,visited:&visited,depth:&depth,matching:parent,expired:{false},frame:{frames[$0]},parent:{parents[$0]},same:==)
        let fresh=try #require(routed)
        #expect(fresh.node == 1 && fresh.rect == parent && visited == 3 && depth == 1)
        let searched=CaptureElementHitTesting.smallestHit(root:fresh.node,at:point,within:coarse,frame:{frames[$0]},children:{ n,_ in n == 1 ? [2]:[] })
        #expect(searched?.rect == parent && searched?.limited == false)
    }
    @Test func freshRouteRejectsChangedAnchorsAndSharesTheOriginalBudget() {
        let parent=CGRect(x:10,y:10,width:400,height:300),point=CGPoint(x:180,y:60)
        var visited=1,depth=0
        let unrelated=CaptureElementHitTesting.freshAncestor(from:0,at:point,within:window,smallerThan:window,visited:&visited,depth:&depth,matching:parent,expired:{false},frame:{ _ in CGRect(x:100,y:20,width:300,height:250) },parent:{ _ in nil as Int? },same:==)
        #expect(unrelated == nil)
        visited=31;depth=0
        var parentCalls=0
        let limited=CaptureElementHitTesting.freshAncestor(from:0,at:point,within:window,smallerThan:window,visited:&visited,depth:&depth,matching:parent,expired:{false},frame:{ _ in leaf },parent:{ n in parentCalls+=1;return n+1 },same:==)
        #expect(limited == nil && visited == 32 && parentCalls == 0)
        visited=1;depth=0
        let gone=CaptureElementHitTesting.freshAncestor(from:0,at:point,within:window,smallerThan:window,visited:&visited,depth:&depth,matching:parent,expired:{false},frame:{ _ in window },parent:{ _ in nil as Int? },same:==)
        #expect(gone == nil)
    }
    @Test func routingRetainsTheRealSuccessfulAnchorAcrossNestedPaddingTransitions() throws {
        var state=CaptureElementHoverState()
        let p=CGRect(x:10,y:10,width:200,height:180),g=CGRect(x:5,y:5,width:500,height:400)
        let anchor=CGPoint(x:35,y:36),first=CGPoint(x:180,y:60),second=CGPoint(x:400,y:250)
        _=state.selectionUsingHit(at:anchor,window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[p,g,window]) }
        let hint=try #require(state.refinementHint(at:first,window:window))
        #expect(hint.anchor == anchor && hint.container == p)
        _=state.selectionUsingHit(at:first,window:window,enabled:true,now:1.1) { CaptureElementHit(rect:p,ancestors:[g,window],anchor:anchor) }
        let outer=try #require(state.refinementHint(at:second,window:window))
        #expect(outer.anchor == anchor && outer.container == g)
        state.reset()
        #expect(state.refinementHint(at:second,window:window) == nil)
    }

    @Test func throttledMouseMovesKeepTheSmallestHitInsteadOfFlashingTheWindow() {
        var state = CaptureElementHoverState(), probes = 0
        for index in 0..<70 {
            let point = CGPoint(x: 25 + index, y: 40)
            let selected = state.selection(at: point, window: window, enabled: true, now: 10 + Double(index) * 0.001) {
                probes += 1; return leaf
            }
            #expect(selected == leaf)
        }
        #expect(probes == 1)
    }
    @Test func missingAndCoarseProbesCannotStealAStillValidSmallerHit() {
        var state = CaptureElementHoverState()
        let point = CGPoint(x: 45, y: 45)
        #expect(state.selection(at: point, window: window, enabled: true, now: 1) { leaf } == leaf)
        #expect(state.selection(at: point, window: window, enabled: true, now: 1.1) { window } == leaf)
        #expect(state.selection(at: point, window: window, enabled: true, now: 1.2) { nil } == leaf)
        let smaller = CGRect(x: 40, y: 40, width: 16, height: 16)
        #expect(state.selection(at: point, window: window, enabled: true, now: 1.3) { smaller } == smaller)
    }
    @Test func crossingAnElementEdgeReprobesWithoutAnIntermediateWindowFrame() {
        var state = CaptureElementHoverState(), probes = 0
        let second = CGRect(x: 200, y: 20, width: 80, height: 80)
        _ = state.selection(at: CGPoint(x: 40, y: 40), window: window, enabled: true, now: 1) { probes += 1; return leaf }
        let selected = state.selection(at: CGPoint(x: 230, y: 40), window: window, enabled: true, now: 1.001) { probes += 1; return second }
        #expect(probes == 2 && selected == second)
    }
    @Test func aKnownAXParentAvoidsRepeatedCoarseOrMissingRepliesWithoutAnOuterWindowHop() {
        let parent=CGRect(x:10,y:10,width:400,height:300),point=CGPoint(x:180,y:60)
        for coarse in [CaptureElementHit?.none,CaptureElementHit(rect:window,limited:true)] {
            var state=CaptureElementHoverState()
            _=state.selectionUsingHit(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[parent,window]) }
            for index in 1...2 {
                #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1+Double(index)*0.1) { coarse } == leaf)
            }
            #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.3) { CaptureElementHit(rect:parent,ancestors:[window]) } == parent)
            #expect(state.retryDelay(now:1.3) == nil)
        }
    }
    @Test(arguments:[false,true]) func aLargerFreshSiblingCanReplaceAnInferredParentAndClicksIgnoreCachedGeometry(limited:Bool) {
        var state=CaptureElementHoverState()
        let parent=CGRect(x:10,y:10,width:200,height:180),sibling=CGRect(x:130,y:20,width:250,height:180),point=CGPoint(x:180,y:60)
        _=state.selectionUsingHit(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[parent,window]) }
        #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.1) { nil } == leaf)
        #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.2) { CaptureElementHit(rect:sibling,ancestors:[window],limited:limited) } == sibling)
        #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.201,force:true) { nil } == window)
    }
    @Test func pointerJitterAndRepeatedFailureCannotRestartTheFixedUncertaintyEpisode() {
        var state=CaptureElementHoverState(),probes=0
        let parent=CGRect(x:10,y:10,width:400,height:300)
        _=state.selectionUsingHit(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { probes+=1;return CaptureElementHit(rect:leaf,ancestors:[parent,window]) }
        _=state.selectionUsingHit(at:CGPoint(x:180,y:60),window:window,enabled:true,now:1.001) { probes+=1;return nil }
        for index in 1...239 {
            let point=CGPoint(x:180+index%2,y:60)
            #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.001+Double(index)*0.001) { probes+=1;return nil } == leaf)
        }
        #expect(state.selectionUsingHit(at:CGPoint(x:180,y:60),window:window,enabled:true,now:1.242) { probes+=1;return nil } == window)
        #expect(probes<=6 && state.retryDelay(now:1.242) == nil)
    }

    @Test func returningToTheValidLeafCancelsItsOldExpiryEvenIfLaterProbesFail() {
        var state=CaptureElementHoverState()
        let inside=CGPoint(x:40,y:40),outside=CGPoint(x:180,y:60)
        _=state.selectionUsingHit(at:inside,window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[window]) }
        #expect(state.selectionUsingHit(at:outside,window:window,enabled:true,now:1.1) { nil } == leaf)
        #expect(state.retryDelay(now:1.1) != nil)
        #expect(state.selectionUsingHit(at:inside,window:window,enabled:true,now:1.12) { nil } == leaf)
        #expect(state.retryDelay(now:1.12) == nil)
        #expect(state.selectionUsingHit(at:inside,window:window,enabled:true,now:1.6) { nil } == leaf)
    }

    @Test func aCompleteWindowHitInsideTheOldParentWinsAndSustainedFailureExpires() {
        let parent=CGRect(x:10,y:10,width:400,height:300),point=CGPoint(x:180,y:60)
        for recovered in [true,false] {
            var state=CaptureElementHoverState()
            _=state.selectionUsingHit(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[parent,window]) }
            #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.1) { nil } == leaf)
            if recovered {
                #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.2) { CaptureElementHit(rect:window) } == window)
            } else {
                #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.2) { nil } == leaf)
                #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.341) { nil } == window)
            }
            #expect(state.retryDelay(now:1.4) == nil)
        }
    }
    @Test func equalAreaRectanglesCannotStealAStableHitAndAnEmptyFreshLineageInvalidatesOldParents() {
        var state=CaptureElementHoverState()
        let point=CGPoint(x:40,y:40),other=leaf.offsetBy(dx:10,dy:-10)
        _=state.selectionUsingHit(at:point,window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[window]) }
        for index in 1...10 {
            #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1+Double(index)*0.1) { CaptureElementHit(rect:other) } == leaf)
        }
        _=state.selectionUsingHit(at:point,window:window,enabled:true,now:2.1) { CaptureElementHit(rect:leaf) }
        #expect(state.selectionUsingHit(at:CGPoint(x:180,y:60),window:window,enabled:true,now:2.2) { nil } == leaf)
    }
    @Test func knownHierarchyStillAllowsTheRealWindowAndIsDiscardedWithItsCaptureScope() {
        var state=CaptureElementHoverState()
        let parent=CGRect(x:10,y:10,width:200,height:180)
        _=state.selectionUsingHit(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[parent,window]) }
        #expect(state.selectionUsingHit(at:CGPoint(x:600,y:400),window:window,enabled:true,now:1.1) { CaptureElementHit(rect:window) } == window)
        state.reset()
        #expect(state.selectionUsingHit(at:CGPoint(x:180,y:60),window:window,enabled:true,now:1.2) { nil } == window)
        let other=CGRect(x:0,y:0,width:700,height:500)
        #expect(state.selectionUsingHit(at:CGPoint(x:180,y:60),window:other,enabled:true,now:1.3) { nil } == other)
    }
    @Test func boundedSearchRetainsOnlyTheWinningHierarchyAndMarksTruncatedReplies() throws {
        let parent=CGRect(x:10,y:10,width:400,height:300),point=CGPoint(x:40,y:40)
        let frames=[window,parent,leaf,CGRect(x:30,y:30,width:20,height:20)]
        let edges=[[1,3],[2],[],[]]
        let searched=CaptureElementHitTesting.smallestHit(root:0,at:point,within:window,frame:{frames[$0]},children:{ n,_ in edges[n] })
        let result=try #require(searched)
        #expect(result.rect == frames[3] && result.ancestors == [window] && !result.limited)
        let truncatedSearch=CaptureElementHitTesting.smallestHit(root:0,at:point,within:window,maxNodes:3,frame:{ (node:Int)->CGRect? in node == 0 ? window:CGRect(x:600,y:400,width:20,height:20) },children:{ n,limit in n == 0 ? Array([1,2,3,4].prefix(limit)):[] })
        let truncated=try #require(truncatedSearch)
        #expect(truncated.rect == window && truncated.limited && truncated.visitedNodes == 3)
        var visits=0
        let expired=CaptureElementHitTesting.smallestHit(root:0,at:point,within:window,expired:{ visits>=2 },frame:{ _ in visits+=1;return parent },children:{ n,_ in [n+1] })
        #expect(expired?.limited == true && visits == 2)
    }

    @Test func aMissingOrCoarseBoundaryProbeDoesNotFlashAnAncestorBeforeTheRealParent() {
        let parent=CGRect(x:10,y:10,width:400,height:300),point=CGPoint(x:180,y:60)
        let outer=CGRect(x:0,y:0,width:650,height:500)
        for transient in [CaptureElementHit?.none,CaptureElementHit(rect:window,limited:true),CaptureElementHit(rect:outer,limited:true)] {
            var state=CaptureElementHoverState()
            #expect(state.selectionUsingHit(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { CaptureElementHit(rect:leaf,ancestors:[parent,outer,window]) } == leaf)
            #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.001) { transient } == leaf)
            #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.1) { CaptureElementHit(rect:parent) } == parent)
        }
    }
    @Test func boundaryConfirmationIsBoundedAndDoesNotProbeEveryMouseMove() {
        var state=CaptureElementHoverState(),probes=0
        let parent=CGRect(x:10,y:10,width:400,height:300),point=CGPoint(x:180,y:60)
        _=state.selectionUsingHit(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { probes+=1;return CaptureElementHit(rect:leaf,ancestors:[parent,window]) }
        _=state.selectionUsingHit(at:point,window:window,enabled:true,now:1.001) { probes+=1;return CaptureElementHit(rect:window,limited:true) }
        for index in 1...100 {
            #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.001+Double(index)*0.0001) { probes+=1;return nil } == leaf)
        }
        #expect(probes == 2 && state.retryDelay(now:1.011) != nil)
        #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.09) { probes+=1;return nil } == leaf)
        #expect(probes == 3 && state.retryDelay(now:1.09) != nil)
        #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.12) { probes+=1;return nil } == leaf)
        #expect(probes == 3)
        #expect(state.selectionUsingHit(at:point,window:window,enabled:true,now:1.18) { probes+=1;return CaptureElementHit(rect:parent) } == parent)
        #expect(probes == 4 && state.retryDelay(now:1.18) == nil)
    }
    @Test func aRealWindowFallbackFollowsBoundedUncertaintyAndResetDiscardsThePendingAncestor() {
        var state=CaptureElementHoverState()
        let point=CGPoint(x:180,y:60)
        _=state.selection(at:CGPoint(x:40,y:40),window:window,enabled:true,now:1) { leaf }
        #expect(state.selection(at:point,window:window,enabled:true,now:1.001) { nil } == leaf)
        #expect(state.selection(at:point,window:window,enabled:true,now:1.03) { nil } == leaf)
        #expect(state.selection(at:point,window:window,enabled:true,now:1.25) { nil } == window)
        #expect(state.retryDelay(now:1.25) == nil)
        state.reset()
        #expect(state.retryDelay(now:1.04) == nil)
        #expect(state.selection(at:point,window:window,enabled:true,now:1.04) { nil } == window)
    }
    @Test func aForcedClickNeverUsesAHeldOrStaleSmallerElement() {
        var state=CaptureElementHoverState()
        let parent=CGRect(x:10,y:10,width:400,height:300),point=CGPoint(x:40,y:40)
        _=state.selection(at:point,window:window,enabled:true,now:1) { leaf }
        #expect(state.selection(at:point,window:window,enabled:true,now:1.001,force:true) { parent } == parent)
        #expect(state.selection(at:point,window:window,enabled:true,now:1.002,force:true) { nil } == window)
    }
    @Test func changedWindowDisabledDetectionAndResetInvalidateTheOldHit() {
        var state = CaptureElementHoverState()
        let point = CGPoint(x: 40, y: 40), other = CGRect(x: 10, y: 10, width: 500, height: 400)
        _ = state.selection(at: point, window: window, enabled: true, now: 1) { leaf }
        #expect(state.selection(at: point, window: other, enabled: true, now: 1.001) { nil } == other)
        #expect(state.selection(at: point, window: other, enabled: false, now: 1.002) { Issue.record("Disabled detection queried AX"); return leaf } == other)
        #expect(state.selection(at: point, window: other, enabled: true, now: 1.003) { leaf } == leaf)
        state.reset()
        #expect(state.selection(at: point, window: other, enabled: true, now: 1.004) { nil } == other)
    }
    @Test func clickingReprobesForASmallerNestedTargetWithoutWaitingForTheThrottle() {
        var state = CaptureElementHoverState()
        let point = CGPoint(x: 40, y: 40)
        _ = state.selection(at: point, window: window, enabled: true, now: 1) { window }
        #expect(state.selection(at: point, window: window, enabled: true, now: 1.001, force: true) { leaf } == leaf)
    }
    @Test func pointLocalTreeSearchPicksTheSmallestOverlappingDescendant() {
        let point = CGPoint(x: 45, y: 45), smallest = CGRect(x: 40, y: 40, width: 12, height: 12)
        let frames = [window, leaf, CGRect(x: 30, y: 30, width: 50, height: 50), smallest, CGRect(x: 300, y: 30, width: 10, height: 10)]
        let edges = [[1, 2, 4], [3], [], [], []]
        for order in [edges, [[2, 4, 1], [3], [], [], []]] {
            let result = CaptureElementHitTesting.smallest(root: 0, at: point, within: window,
                frame: { frames[$0] }, children: { Array(order[$0].prefix($1)) })
            #expect(result == smallest)
        }
    }
    @Test func malformedAndOffPointerRectanglesAreRejectedAndLargeOnesAreClipped() {
        let point = CGPoint(x: 45, y: 45)
        for rect in [CGRect.null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20),
                     CGRect(x: 44, y: 44, width: 4, height: 4), CGRect(x: 100, y: 100, width: 20, height: 20)] {
            #expect(CaptureElementHitTesting.valid(rect, at: point, within: window) == nil)
        }
        #expect(CaptureElementHitTesting.valid(window.insetBy(dx: -100, dy: -100), at: point, within: window) == window)
    }
    @Test func traversalStopsAtNodeDepthAndDeadlineBudgetsEvenForCycles() {
        var visits = 0
        _ = CaptureElementHitTesting.smallest(root: 0, at: CGPoint(x: 45, y: 45), within: window,
            maxNodes: 7, maxDepth: 100, frame: { _ in visits += 1; return window }, children: { _, _ in [0] })
        #expect(visits == 7)
        visits = 0
        _ = CaptureElementHitTesting.smallest(root: 0, at: CGPoint(x: 45, y: 45), within: window,
            maxDepth: 3, frame: { _ in visits += 1; return window }, children: { node, _ in [node + 1] })
        #expect(visits == 4)
        visits = 0
        _ = CaptureElementHitTesting.smallest(root: 0, at: CGPoint(x: 45, y: 45), within: window,
            expired: { visits >= 2 }, frame: { _ in visits += 1; return window }, children: { node, _ in [node + 1] })
        #expect(visits == 2)
    }
    @Test func optionalElementDetectionChecksTheBoundClientWithoutRequestingAnOSGrant() {
        var calls = 0
        let allowed = PluginPermissionClient(require: { ids in #expect(ids == [.accessibility]); calls += 1 })
        #expect(!CaptureElementHitTesting.isAllowed(using: allowed, trusted: false) && calls == 0)
        #expect(CaptureElementHitTesting.isAllowed(using: allowed, trusted: true) && calls == 1)
        let denied = PluginPermissionClient(require: { _ in throw PluginError.invalid("Undeclared permission") })
        #expect(!CaptureElementHitTesting.isAllowed(using: denied, trusted: true))
    }
    @Test func realSelectionViewKeepsSmallHoverAndClickUsesTheFreshSmallestFrame() throws {
        var probes = 0
        let (view, panel) = try selection { _ in probes += 1; return self.leaf }
        defer { panel.close(); panel.contentView = nil }
        panel.orderFrontRegardless()
        for index in 0..<20 {
            panel.displayIfNeeded()
            view.needsDisplay = false
            view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 30 + index, y: 40), in: view))
            #expect(view.selected == leaf)
            if index > 0 { #expect(!view.needsDisplay) }
        }
        #expect(probes >= 1)
        let beforeClick = probes
        var result: CGRect?
        view.completed = { rect, _ in result = rect }
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 40, y: 40), in: view))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 40, y: 40), in: view))
        #expect(probes == beforeClick + 1 && result == nil && view.selected == leaf && view.session.hasSelection)
    }
    @Test func unavailableElementsStillUseTheFrontmostWindowNotASmallerHiddenWindow() throws {
        let (view, panel) = try selection { _ in nil }
        defer { panel.close(); panel.contentView = nil }
        view.windows = [window, leaf]
        view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 45, y: 45), in: view))
        #expect(view.selected == window)
    }
    private func selection(resolver: @escaping (CGPoint) -> CGRect?) throws -> (CaptureSelectionView, NSPanel) {
        let context = try CaptureImage.context(width: 800, height: 600)
        context.setFillColor(NSColor.white.cgColor); context.fill(window)
        let view = CaptureSelectionView(image: try #require(context.makeImage()), allowsShapes: true, elementResolver: resolver)
        view.windows = [window]
        let panel = NSPanel(contentRect: window, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = view
        return (view, panel)
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
