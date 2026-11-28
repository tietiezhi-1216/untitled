import ApplicationServices
import UntitledPluginSDK
import Foundation

/// Value geometry only. Ancestors belong to the winning AX path, nearest first;
/// limited means this bounded search may have stopped before a smaller target.
struct CaptureElementHit {
    let rect:CGRect
    var ancestors:[CGRect]=[]
    var limited=false
    var visitedNodes=0
    var depth=0
    var anchor:CGPoint?
}

struct CaptureElementHint {
    let anchor:CGPoint
    let container:CGRect
}

/// One captured window and its latest known hierarchy, never AX objects or text.
struct CaptureElementHoverState {
    private var window: CGRect?
    private var element: CGRect?
    private var lastProbe = -Double.infinity
    private var lineage:[CGRect]=[]
    private var lineageAnchor:CGPoint?
    private var inferred=false
    private var inferredUntil:TimeInterval?
    private var inferredRetryAt:TimeInterval?
    static let inferredLifetime:TimeInterval=0.24
    mutating func reset() { window = nil; element = nil; lastProbe = -.infinity;lineage=[];inferred=false;inferredUntil=nil;inferredRetryAt=nil }
    func refinementHint(at point:CGPoint,window current:CGRect?)->CaptureElementHint? {
        guard window == current,let current,let element,!element.contains(point),lineage.first != nil,let anchor=lineageAnchor,
              let container=lineage.dropFirst().filter({ $0.contains(point) && $0 != current }).min(by:{ $0.width*$0.height < $1.width*$1.height }) else { return nil }
        return CaptureElementHint(anchor:anchor,container:container)
    }
    func retryDelay(now:TimeInterval)->TimeInterval? {
        [inferredRetryAt,inferredUntil].compactMap { $0 }.min().map { max(0,$0-now) }
    }
    mutating func selection(at point: CGPoint, window current: CGRect?, enabled: Bool,
                            now: TimeInterval, force: Bool = false, lookup: () -> CGRect?) -> CGRect? {
        selectionUsingHit(at:point,window:current,enabled:enabled,now:now,force:force) {
            lookup().map { CaptureElementHit(rect:$0) }
        }
    }
    mutating func selectionUsingHit(at point:CGPoint,window current:CGRect?,enabled:Bool,now:TimeInterval,
                                   force:Bool=false,lookup:()->CaptureElementHit?)->CGRect? {
        guard enabled, let current else { reset(); return current }
        if window != current { reset(); window = current }
        if inferred,element?.contains(point) == true {
            // Returning to the still-valid leaf ends this boundary episode.
            // Its old expiry must never erase that valid hit while stationary.
            inferred=false;inferredUntil=nil;inferredRetryAt=nil
        }
        if let inferredUntil,now>=inferredUntil {
            // An unavailable hit must not pin an off-pointer target indefinitely.
            element=nil;lineage=[];inferred=false;self.inferredUntil=nil;inferredRetryAt=nil;lastProbe = -.infinity
        }
        let leavingElement = element.map { !$0.contains(point) } ?? false
        let due=min(lastProbe+0.08,inferredRetryAt ?? .infinity)
        guard force || (leavingElement && !inferred) || now>=due else { return element ?? current }
        lastProbe=now
        if let inferredRetryAt,now>=inferredRetryAt { self.inferredRetryAt=nil }
        let hit=lookup(),found=hit.flatMap { CaptureElementHitTesting.valid($0.rect,at:point,within:current) }
        // A click never consumes inferred/cached geometry.
        if force {
            element=found;inferred=false;inferredUntil=nil;inferredRetryAt=nil;lineage=[]
            if let hit,let found { remember(hit,rect:found,at:point,within:current) }
            return found ?? current
        }
        let knownCoarse=hit?.limited == true && found.map { lineage.dropFirst().contains($0) || $0 == current } == true
        if let previous=element,leavingElement || inferred,found == nil || knownCoarse {
            // A cached parent can itself be larger than the eventual sibling.
            // Never send an unconfirmed ancestor/fallback to the renderer.
            // Retain the last displayed target only for this bounded episode.
            inferred=true
            if inferredUntil == nil { inferredUntil=now+Self.inferredLifetime;inferredRetryAt=now+0.08 }
            return previous
        }
        if inferred {
            element=found;inferred=false;inferredUntil=nil;inferredRetryAt=nil
            if let hit,let found { remember(hit,rect:found,at:point,within:current) } else { lineage=[] }
            return found ?? current
        }
        if leavingElement {
            element=found
            if let hit,let found { remember(hit,rect:found,at:point,within:current) }
        } else if let found,found.width*found.height < (element.map { $0.width*$0.height } ?? .infinity) {
            element=found
            if let hit { remember(hit,rect:found,at:point,within:current) }
        } else if let found,found == element,let hit { remember(hit,rect:found,at:point,within:current) }
        return element ?? current
    }
    private mutating func remember(_ hit:CaptureElementHit,rect:CGRect,at point:CGPoint,within bounds:CGRect) {
        var path=[rect]
        for raw in hit.ancestors.prefix(12) {
            guard let parent=CaptureElementHitTesting.valid(raw,at:point,within:bounds),let child=path.last,
                  parent != child,parent.contains(child) else { continue }
            path.append(parent)
        }
        lineage=path;lineageAnchor=hit.anchor ?? point
    }
}

enum CaptureElementHitTesting {
    @MainActor static func isAllowed(using permissions: PluginPermissionClient, trusted: Bool? = nil) -> Bool {
        guard trusted ?? AXIsProcessTrusted() else { return false }
        do { try permissions.require([.accessibility]); return true } catch { return false }
    }
    static func valid(_ rect: CGRect, at point: CGPoint, within bounds: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width >= 8, rect.height >= 8 else { return nil }
        let clipped = rect.intersection(bounds)
        return !clipped.isNull && clipped.width >= 8 && clipped.height >= 8 && clipped.contains(point) ? clipped : nil
    }
    /// Bounded, point-local descent: AX hit-testing can return a container whose
    /// smaller children overlap the pointer. Sibling order must not pick a parent.
    static func smallest<Node>(root: Node, at point: CGPoint, within bounds: CGRect,
                               maxNodes: Int = 32, maxDepth: Int = 12,
                               expired: () -> Bool = { false },
                               frame: (Node) -> CGRect?, children: (Node, Int) -> [Node]) -> CGRect? {
        smallestHit(root:root,at:point,within:bounds,maxNodes:maxNodes,maxDepth:maxDepth,expired:expired,frame:frame,children:children)?.rect
    }
    static func smallestHit<Node>(root:Node,at point:CGPoint,within bounds:CGRect,maxNodes:Int=32,maxDepth:Int=12,
                                  expired:()->Bool={false},frame:(Node)->CGRect?,children:(Node,Int)->[Node])->CaptureElementHit? {
        var stack:[(Node,Int,[CGRect])]=[(root,0,[])],visited=0,limited=false
        var best:CaptureElementHit?
        while !stack.isEmpty,visited<maxNodes,!expired() {
            let (node,depth,parents)=stack.removeLast();visited+=1
            let raw=frame(node),rect=raw.flatMap { valid($0,at:point,within:bounds) }
            if raw != nil,rect == nil { continue }
            if let rect,rect.width*rect.height < (best.map { $0.rect.width*$0.rect.height } ?? .infinity) {
                best=CaptureElementHit(rect:rect,ancestors:Array(parents.reversed()),depth:depth)
            }
            guard depth<maxDepth,!expired() else { limited=true;continue }
            let remaining=max(0,maxNodes-visited)
            guard remaining>0 else { limited=true;continue }
            let values=Array(children(node,remaining).prefix(remaining))
            // A saturated bounded children read may omit a later sibling.
            if values.count == remaining { limited=true }
            let path=rect.map { parents+[$0] } ?? parents
            stack.append(contentsOf:values.reversed().map { ($0,depth+1,path) })
            if stack.count>maxNodes { stack.removeFirst(stack.count-maxNodes);limited=true }
        }
        best?.limited=limited || !stack.isEmpty || expired();best?.visitedNodes=visited
        return best
    }

    /// Reacquire a live path, rather than displaying cached ancestor geometry.
    /// Counters are shared with the caller's same lookup budget.
    static func freshAncestor<Node>(from anchor:Node,at point:CGPoint,within bounds:CGRect,smallerThan coarse:CGRect,
                                    visited:inout Int,depth:inout Int,matching expected:CGRect?=nil,maxNodes:Int=32,maxDepth:Int=12,
                                    expired:()->Bool,frame:(Node)->CGRect?,parent:(Node)->Node?,same:(Node,Node)->Bool)->(node:Node,rect:CGRect)? {
        var node=anchor,seen:[Node]=[]
        while visited<maxNodes,depth<=maxDepth,!expired() {
            guard !seen.contains(where:{ same($0,node) }) else { break }
            seen.append(node);visited+=1
            if let rect=frame(node).flatMap({ valid($0,at:point,within:bounds) }),rect.width*rect.height<coarse.width*coarse.height {
                let matches=expected.map { max(abs(rect.minX-$0.minX),abs(rect.minY-$0.minY),abs(rect.width-$0.width),abs(rect.height-$0.height))<=1 } ?? true
                if matches { return (node,rect) }
            }
            guard depth<maxDepth,!expired(),visited<maxNodes,let next=parent(node) else { break }
            node=next;depth+=1
        }
        return nil
    }

    /// No global AX timeout changes; every temporary reference has its own limit.
    /// A 20ms soft deadline plus at most one 8ms message, with no queued work.
    static func accessibilityRect(pid:pid_t,at point:CGPoint,within bounds:CGRect)->CGRect? {
        accessibilityHit(pid:pid,at:point,within:bounds)?.rect
    }
    static func accessibilityHit(pid:pid_t,at point:CGPoint,within bounds:CGRect,hint:CaptureElementHint?=nil)->CaptureElementHit? {
        let deadline=ProcessInfo.processInfo.systemUptime+0.02
        func expired()->Bool { ProcessInfo.processInfo.systemUptime>=deadline }
        func readFrame(_ element:AXUIElement)->CGRect? {
            AXUIElementSetMessagingTimeout(element,0.008)
            var position:CFTypeRef?,size:CFTypeRef?
            guard !expired(),AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&position) == .success,
                  !expired(),AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&size) == .success,
                  let position,let size,CFGetTypeID(position) == AXValueGetTypeID(),CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin=CGPoint.zero,dimensions=CGSize.zero
            guard AXValueGetValue(unsafeDowncast(position,to:AXValue.self),.cgPoint,&origin),
                  AXValueGetValue(unsafeDowncast(size,to:AXValue.self),.cgSize,&dimensions) else { return nil }
            return CGRect(origin:origin,size:dimensions)
        }
        let application=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application,0.008)
        var root:AXUIElement?
        guard AXUIElementCopyElementAtPosition(application,Float(point.x),Float(point.y),&root) == .success,
              let root,!expired() else { return nil }
        var searchRoot=root,cachedRootFrame:CGRect?,previsited=0,refinementDepth=0
        var refinedAnchor:CGPoint?
        if let hint,bounds.contains(hint.anchor),hint.container.contains(point),!expired() {
            cachedRootFrame=readFrame(root);previsited=1
            if let coarse=cachedRootFrame.flatMap({ valid($0,at:point,within:bounds) }),
               coarse.contains(hint.container),coarse.width*coarse.height>hint.container.width*hint.container.height,!expired() {
                // Electron text padding can hit a different broad AX subtree
                // whose 'complete' children omit the message parent. Re-hit the
                // last leaf and walk *fresh* parents, within this same deadline.
                var anchor:AXUIElement?
                if AXUIElementCopyElementAtPosition(application,Float(hint.anchor.x),Float(hint.anchor.y),&anchor) == .success,
                   let anchor,!expired(),let refined=freshAncestor(from:anchor,at:point,within:bounds,smallerThan:coarse,
                    visited:&previsited,depth:&refinementDepth,matching:hint.container,expired:expired,frame:readFrame,parent:{ node in
                        guard !expired() else { return nil };AXUIElementSetMessagingTimeout(node,0.008)
                        var value:CFTypeRef?
                        guard AXUIElementCopyAttributeValue(node,kAXParentAttribute as CFString,&value) == .success,
                              let value,CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                        return unsafeDowncast(value,to:AXUIElement.self)
                    },same:{ CFEqual($0,$1) }) {
                    searchRoot=refined.node;cachedRootFrame=refined.rect;refinedAnchor=hint.anchor
                }
            }
        }
        let available=max(1,32-max(0,previsited-1))
        var winner:AXUIElement?,bestArea=CGFloat.infinity,failed=false
        guard var hit=smallestHit(root:searchRoot,at:point,within:bounds,maxNodes:available,maxDepth:max(0,12-refinementDepth),expired:expired,frame:{ element in
            let raw=CFEqual(element,searchRoot) ? (cachedRootFrame ?? readFrame(element)):readFrame(element)
            if raw == nil { failed=true }
            if let rect=raw.flatMap({ valid($0,at:point,within:bounds) }),rect.width*rect.height<bestArea {
                winner=element;bestArea=rect.width*rect.height
            }
            return raw
        },children:{ element,limit in
            guard !expired() else { failed=true;return [] }
            var count:CFIndex=0
            let countStatus=AXUIElementGetAttributeValueCount(element,kAXChildrenAttribute as CFString,&count)
            guard countStatus == .success else { if countStatus != .attributeUnsupported && countStatus != .noValue { failed=true };return [] }
            guard count>0 else { return [] }
            guard !expired() else { failed=true;return [] }
            var values:CFArray?
            let status=AXUIElementCopyAttributeValues(element,kAXChildrenAttribute as CFString,0,min(count,limit),&values)
            guard status == .success else { failed=true;return [] }
            return values as? [AXUIElement] ?? []
        }) else {
            if let rect=cachedRootFrame.flatMap({ valid($0,at:point,within:bounds) }) { return CaptureElementHit(rect:rect,limited:true,visitedNodes:previsited,depth:refinementDepth,anchor:refinedAnchor) }
            return nil
        }
        hit.visitedNodes+=max(0,previsited-1);hit.depth+=refinementDepth;hit.anchor=refinedAnchor
        hit.limited = hit.limited || failed
        // A direct AX hit is often already a leaf. Its parents were never in
        // the downward search; collect only spare-budget geometry, not objects.
        if hit.rect != bounds,(hit.ancestors.isEmpty || hit.ancestors.first == bounds),let winner {
            var current=winner,seen=[winner],parents:[CGRect]=[],steps=0
            while hit.visitedNodes<32,steps+hit.depth<12,!expired() {
                AXUIElementSetMessagingTimeout(current,0.008)
                var value:CFTypeRef?
                guard AXUIElementCopyAttributeValue(current,kAXParentAttribute as CFString,&value) == .success,
                      let value,CFGetTypeID(value) == AXUIElementGetTypeID(),!expired() else { break }
                let parent=unsafeDowncast(value,to:AXUIElement.self)
                guard !seen.contains(where:{ CFEqual($0,parent) }) else { break }
                seen.append(parent);steps+=1;hit.visitedNodes+=1
                if let rect=readFrame(parent).flatMap({ valid($0,at:point,within:bounds) }),rect != hit.rect,
                   rect.contains(parents.last ?? hit.rect) {
                    if parents.last != rect { parents.append(rect) }
                    if rect == bounds { break }
                }
                current=parent
            }
            if !parents.isEmpty { hit.ancestors=parents }
        }
        return hit
    }
}
