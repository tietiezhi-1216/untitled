import AppKit
import UntitledPluginSDK
import SwiftUI
import ApplicationServices
import QuartzCore
@preconcurrency import ScreenCaptureKit

/// Only the backdrop fades. The editor never changes alpha, geometry or scale.
@MainActor enum CaptureBackdropTransition {
    static func effectiveDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.12 }
    static func duration(_ requested: TimeInterval? = nil) -> TimeInterval {
        guard let requested else {
            return effectiveDuration(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        return requested.isFinite ? min(0.2, max(0, requested)) : 0
    }
    static func show(_ panel: NSPanel, duration requested: TimeInterval? = nil) {
        let time = duration(requested)
        panel.animationBehavior = .none
        let selection=panel.contentView as? CaptureSelectionView
        // The frozen pixels are opaque from their first frame. Only the solid
        // dim surface animates, never a blend of screenshot and live desktop.
        panel.alphaValue = selection == nil && time > 0 ? 0 : 1
        selection?.transitionBackdrop(entering:true,duration:time)
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        guard time > 0,selection == nil else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = time
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

/// Shares the current selection buffers; at most one short backdrop transition.
@MainActor final class CaptureSelectionPresentation {
    private let surfaces: Surfaces
    private var handoffStarted = false
    private var cleanupTask: Task<Void, Never>?
    var isActive:Bool { surfaces.isActive }
    init(panels: [NSPanel]) { surfaces = Surfaces(panels: panels) }
    func beginHandoff(above windows: [NSWindow], duration requested: TimeInterval? = nil) {
        guard !handoffStarted else { return }
        handoffStarted = true
        let time = CaptureBackdropTransition.duration(requested)
        guard time > 0 else { dismiss(); return }
        // A bounded lease keeps this presentation alive through the fade. AppKit
        // only holds a weak reference; delayed completion cannot retain its images.
        let delay=time+(surfaces.animatesVectorShade ? 0:0.08)
        let deadline=ContinuousClock.now.advanced(by:.seconds(delay))
        cleanupTask = Task { @MainActor [self] in
            // Start the lease at the handoff call, not when a busy main actor
            // eventually starts this task after window/chrome layout.
            guard !Task.isCancelled else { return }
            // An overdue sleep can still suspend and let another actor turn
            // run first. Close an expired lease inline once this task starts.
            if ContinuousClock.now < deadline {
                do { try await Task.sleep(until:deadline,clock:.continuous) } catch { return }
            }
            dismiss()
        }
        surfaces.fadeOut(above: windows, duration: time) { [weak self] in
            Task { @MainActor in self?.dismiss() }
        }
    }
    func complete() { if !handoffStarted { dismiss() } }

    func toolbarFrame(at point: CGPoint) -> CGRect? { surfaces.toolbarFrame(at: point) }

    func takePanelForLiveCapture(at point: CGPoint) -> (panel: NSPanel, toolbar: CGRect?)? {
        guard !handoffStarted else { return nil }
        return surfaces.takePanelForLiveCapture(at: point)
    }

    func dismiss() {
        cleanupTask?.cancel(); cleanupTask = nil
        surfaces.close()
    }
    deinit {
        cleanupTask?.cancel()
        let surfaces = surfaces
        Task { @MainActor in surfaces.close() }
    }
    @MainActor private final class Surfaces {
        private struct ElevatedWindow {
            weak var window: NSWindow?
            let original: NSWindow.Level
            let raised: NSWindow.Level
        }
        private var panels: [NSPanel]
        private var elevated: [ElevatedWindow] = []
        var isActive:Bool { !panels.isEmpty }
        var animatesVectorShade:Bool { panels.contains { $0.contentView is CaptureSelectionView } }
        init(panels: [NSPanel]) { self.panels = panels }
        func fadeOut(above windows: [NSWindow], duration: TimeInterval, completion: @escaping @Sendable () -> Void) {
            guard !panels.isEmpty else { completion(); return }
            let level = NSWindow.Level(rawValue: (panels.map { $0.level.rawValue }.max() ?? 0) + 1)
            for window in windows where window.isVisible && window.level.rawValue < level.rawValue {
                elevated.append(ElevatedWindow(window: window, original: window.level, raised: level))
                window.level = level
                window.orderFront(nil)
                window.displayIfNeeded()
            }
            for panel in panels {
                panel.ignoresMouseEvents = true
                if windows.isEmpty,panel.isKeyWindow { panel.resignKey() }
            }
            let vectorShade=animatesVectorShade
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for panel in panels {
                    if let selection=panel.contentView as? CaptureSelectionView { selection.transitionBackdrop(entering:false,duration:duration) }
                    else { panel.animator().alphaValue = 0 }
                }
            } completionHandler: {
                // Explicit CA shade animations are not owned by this AppKit
                // group; its empty completion must not close them immediately.
                if !vectorShade { completion() }
            }
        }
        func toolbarFrame(at point: CGPoint) -> CGRect? {
            (panels.first { $0.frame.contains(point) }?.contentView as? CaptureSelectionView)?.toolbarFrameInScreen
        }

        func takePanelForLiveCapture(at point: CGPoint) -> (panel: NSPanel, toolbar: CGRect?)? {
            guard let index = panels.firstIndex(where: { $0.frame.contains(point) }) else { return nil }
            let panel = panels.remove(at: index)
            let view = panel.contentView as? CaptureSelectionView
            let toolbar = view?.toolbarFrameInScreen
            view?.cancelRefresh()
            close()
            return (panel, toolbar)
        }

        func close() {
            let panels = panels
            self.panels.removeAll()
            for panel in panels {
                (panel.contentView as? CaptureSelectionView)?.cancelRefresh()
                panel.animationBehavior = .none
                panel.orderOut(nil); panel.close(); panel.contentView = nil
            }
            let elevated = elevated
            self.elevated.removeAll()
            for item in elevated {
                if let window = item.window, window.level == item.raised { window.level = item.original }
            }
        }
    }
}

@MainActor final class CaptureSelector {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureSelection?) -> Void)?
    private let pinShortcutMatches: (UInt32, UInt32) -> Bool

    init(pinShortcutMatches: @escaping (UInt32, UInt32) -> Bool = { _, _ in false }) {
        self.pinShortcutMatches = pinShortcutMatches
    }

    func show(_ screens: [(NSScreen, SCDisplay, SCContentFilter, CGImage)], windows: [SCWindow], allowsShapes: Bool, elementDetectionAllowed: Bool = false,
              automaticallyCopiesSelection: Bool = false, liveActions: Set<CaptureSelectionLiveAction> = [],
              outputHandler: CaptureSelectionOutputHandler? = nil, completion: @escaping (CaptureSelection?) -> Void) {
        self.completion=completion
        if allowsShapes,screens.count>1 {
            do { try showAcrossScreens(screens,windows:windows,elementDetectionAllowed:elementDetectionAllowed,
                                      automaticallyCopiesSelection:automaticallyCopiesSelection,liveActions:liveActions,outputHandler:outputHandler) }
            catch { finish(nil) }
            return
        }
        for (screen,display,filter,image) in screens {
            let panel=CaptureSelectionPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            CaptureWindowPolicy.markControl(panel,name:"selector")
            panel.isReleasedWhenClosed=false;panel.level = .screenSaver
            panel.collectionBehavior=CaptureWindowPolicy.floatingBehavior;panel.hasShadow=false;panel.acceptsMouseMovedEvents=true
            let view=CaptureSelectionView(image:image,allowsShapes:allowsShapes,elementDetectionAllowed:elementDetectionAllowed)
            view.pinShortcutMatches = pinShortcutMatches
            view.session.liveActions = allowsShapes ? liveActions : []
            view.automaticallyCopiesSelection=automaticallyCopiesSelection;view.outputHandler=outputHandler
            view.screenOrigin=display.frame.origin
            view.historyRegions=Self.regionHistory.filter { $0.displayID==display.displayID }.map(\.rect)
            view.elementTargets=windows.filter { $0.windowLayer==0 }.compactMap { window in window.owningApplication.map { (window.frame,$0.processID) } }
            view.windows=windows.filter { $0.windowLayer==0 }.map {
                $0.frame.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY).intersection(CGRect(origin:.zero,size:screen.frame.size))
            }.filter { !$0.isEmpty }
            let width=image.width,height=image.height
            view.refresh = {
                let config=SCStreamConfiguration();config.width=width;config.height=height;config.showsCursor=false
                return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            }
            view.completed = { [weak self,weak view] rect,contours in
                guard let rect,let view else { self?.finish(nil);return }
                let image=view.image,scale=CGFloat(image.width)/screen.frame.width
                let pixels=CGRect(x:rect.minX*scale,y:rect.minY*scale,width:rect.width*scale,height:rect.height*scale).integral
                guard let cropped=image.cropping(to:pixels) else {
                    if view.requestedLiveAction != nil { view.rejectLiveCapture() }
                    return
                }
                let aligned=CGRect(x:pixels.minX/scale,y:pixels.minY/scale,width:pixels.width/scale,height:pixels.height/scale)
                if let action = view.requestedLiveAction {
                    self?.finish(CaptureSelection(display: display, filter: filter, rect: aligned, scale: scale, image: cropped,
                        presentationFrameOverride: CaptureFloatingLayout.screenRect(aligned,on:screen.frame), liveAction: action))
                    return
                }
                do {
                    let result:CGImage
                    if let prepared=view.preparedExport { result=prepared.image }
                    else { result=try view.decorate(CaptureSelectionGeometry.masked(cropped,contours:contours,rect:aligned,scale:scale),scale:scale) }
                    let window=contours.count<=1 && contours.first?.points == CaptureSelectionGeometry.rectangle(rect) && contours.first?.subtract != true && view.rounded.state == .off && view.shadowButton.state == .off && view.border.state == .off ? windows.first { $0.frame.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY).intersection(CGRect(origin:.zero,size:screen.frame.size))==rect } : nil
                    let padding=CGFloat(view.decorationPadding)/scale
                    let presentation=CaptureFloatingLayout.screenRect(aligned,on:screen.frame).insetBy(dx:-padding,dy:-padding)
                    self?.finish(CaptureSelection(display:display,filter:filter,rect:aligned,scale:scale,image:result,windowID:window?.windowID,presentationFrameOverride:presentation,initialTool:view.initialTool,postAction:view.postAction,outputHandled:view.outputWasHandled,editableExport:view.preparedExport,initialAction:view.initialAction))
                } catch { view.showError(error.localizedDescription) }
            }
            panel.contentView=view;panels.append(panel);CaptureBackdropTransition.show(panel);panel.makeFirstResponder(view)
        }
    }
    private static var regionHistory:[CaptureRegionMemory] {
        guard let data=UserDefaults.standard.data(forKey:"capture.regionHistory") else { return [] }
        return (try? JSONDecoder().decode([CaptureRegionMemory].self,from:data)) ?? []
    }
    private func composite(_ screens:[(NSScreen,SCDisplay,SCContentFilter,CGImage)], union:CGRect, scale:CGFloat) throws -> CGImage {
        let context=try CaptureImage.context(width:Int((union.width*scale).rounded()),height:Int((union.height*scale).rounded()))
        for (_,display,_,image) in screens {
            let rect=CGRect(x:(display.frame.minX-union.minX)*scale,y:(union.maxY-display.frame.maxY)*scale,width:display.frame.width*scale,height:display.frame.height*scale)
            context.draw(image,in:rect)
        }
        guard let result=context.makeImage() else { throw PluginError.invalid("无法合成多屏截图。") };return result
    }
    private func showAcrossScreens(_ screens:[(NSScreen,SCDisplay,SCContentFilter,CGImage)],windows:[SCWindow],elementDetectionAllowed:Bool,
                                   automaticallyCopiesSelection:Bool,liveActions:Set<CaptureSelectionLiveAction>,outputHandler:CaptureSelectionOutputHandler?) throws {
        let frame=screens.dropFirst().reduce(screens[0].0.frame) { $0.union($1.0.frame) }
        let world=screens.dropFirst().reduce(screens[0].1.frame) { $0.union($1.1.frame) }
        let scale=screens.map { CGFloat($0.3.width)/$0.0.frame.width }.max() ?? 1
        let image=try composite(screens,union:world,scale:scale)
        let sources=screens.map { ($0.0,$0.1,$0.2,$0.3.width,$0.3.height) }
        let panel=CaptureSelectionPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        CaptureWindowPolicy.markControl(panel,name:"selector")
        panel.isReleasedWhenClosed=false;panel.level = .screenSaver;panel.collectionBehavior=CaptureWindowPolicy.floatingBehavior
        panel.hasShadow=false;panel.acceptsMouseMovedEvents=true
        let view=CaptureSelectionView(image:image,allowsShapes:true,elementDetectionAllowed:elementDetectionAllowed)
        view.pinShortcutMatches = pinShortcutMatches
        view.session.liveActions = liveActions
        view.automaticallyCopiesSelection=automaticallyCopiesSelection;view.outputHandler=outputHandler
        view.screenOrigin=world.origin
        view.historyRegions=Self.regionHistory.compactMap { memory in
            guard let display=screens.first(where:{ $0.1.displayID==memory.displayID })?.1 else { return nil }
            return memory.rect.offsetBy(dx:display.frame.minX-world.minX,dy:display.frame.minY-world.minY)
        }
        view.displayRects=screens.map { $0.1.frame.offsetBy(dx:-world.minX,dy:-world.minY) }
        view.windows=windows.filter { $0.windowLayer==0 }.map { $0.frame.offsetBy(dx:-world.minX,dy:-world.minY).intersection(CGRect(origin:.zero,size:world.size)) }.filter { !$0.isEmpty }
        view.elementTargets=windows.filter { $0.windowLayer==0 }.compactMap { window in window.owningApplication.map { (window.frame,$0.processID) } }
        view.refresh = { [weak self] in
            guard let self else { throw CancellationError() }
            var fresh:[(NSScreen,SCDisplay,SCContentFilter,CGImage)]=[]
            for (screen,display,filter,width,height) in sources {
                let config=SCStreamConfiguration();config.width=width;config.height=height;config.showsCursor=false
                let next=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                fresh.append((screen,display,filter,next))
            }
            return try self.composite(fresh,union:world,scale:scale)
        }
        view.completed = { [weak self,weak view] rect,contours in
            guard let rect,let view else { self?.finish(nil);return }
            let pixels=CGRect(x:rect.minX*scale,y:rect.minY*scale,width:rect.width*scale,height:rect.height*scale).integral
            guard let cropped=view.image.cropping(to:pixels) else {
                if view.requestedLiveAction != nil { view.rejectLiveCapture() }
                return
            }
            let aligned=CGRect(x:pixels.minX/scale,y:pixels.minY/scale,width:pixels.width/scale,height:pixels.height/scale)
            let global=aligned.offsetBy(dx:world.minX,dy:world.minY)
            let contained=sources.first { $0.1.frame.contains(global) },source=contained ?? sources[0]
            if let action = view.requestedLiveAction {
                guard let contained else { view.rejectLiveCapture(); return }
                let display = contained.1
                let range = global.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                let presentation = CaptureFloatingLayout.screenRect(range,on:contained.0.frame)
                self?.finish(CaptureSelection(display: display, filter: contained.2, rect: range, scale: scale, image: cropped,
                    presentationFrameOverride: presentation, liveAction: action))
                return
            }
            do {
                let result:CGImage
                if let prepared=view.preparedExport { result=prepared.image }
                else { result=try view.decorate(CaptureSelectionGeometry.masked(cropped,contours:contours,rect:aligned,scale:scale),scale:scale) }
                let padding=CGFloat(view.decorationPadding)/scale
                let presentation=CGRect(x:frame.minX+aligned.minX,y:frame.maxY-aligned.maxY,width:aligned.width,height:aligned.height).insetBy(dx:-padding,dy:-padding)
                self?.finish(CaptureSelection(display:source.1,filter:source.2,rect:global.offsetBy(dx:-source.1.frame.minX,dy:-source.1.frame.minY),scale:scale,image:result,presentationFrameOverride:presentation,isComposite:contained==nil,initialTool:view.initialTool,postAction:view.postAction,outputHandled:view.outputWasHandled,editableExport:view.preparedExport,initialAction:view.initialAction))
            } catch { view.showError(error.localizedDescription) }
        }
        panel.contentView=view;panels.append(panel);CaptureBackdropTransition.show(panel);panel.makeFirstResponder(view)
    }
    func pinCurrentSelection() {
        guard completion != nil else { return }
        for panel in panels where panel.isVisible {
            guard let view = panel.contentView as? CaptureSelectionView, view.session.hasSelection else { continue }
            view.pinCurrentSelection()
            return
        }
    }

    func finish(_ selection: CaptureSelection?) {
        guard let completion else { return };self.completion=nil
        for panel in panels {
            let view = panel.contentView as? CaptureSelectionView
            if selection != nil { view?.prepareForHandoff() } else { view?.cancelRefresh() }
        }
        let presentation = CaptureSelectionPresentation(panels: panels)
        panels.removeAll()
        if var selection {
            selection.presentation = presentation
            if selection.outputHandled { presentation.beginHandoff(above:[]) }
            completion(selection)
        } else {
            presentation.dismiss()
            completion(nil)
        }
    }
}

private final class CaptureSelectionPanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor private final class CaptureSelectionColorWell:NSColorWell {
    private var previousLevel:NSWindow.Level?
    override func activate(_ exclusive:Bool) {
        let panel=NSColorPanel.shared
        if previousLevel==nil { previousLevel=panel.level }
        panel.level=NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue+1)
        super.activate(exclusive)
    }
    override func deactivate() {
        super.deactivate()
        if let previousLevel { NSColorPanel.shared.level=previousLevel;self.previousLevel=nil }
    }
}

@MainActor final class CaptureSelectionView: NSView, NSTextFieldDelegate {
    enum Shape: Int, CaseIterable {
        case rectangle, freehand, polygon, windows
        var title: String { switch self { case .rectangle: "矩形截图"; case .freehand: "自由截图"; case .polygon: "折线截图"; case .windows: "多窗口截图" } }
        var symbol: String { switch self { case .rectangle: "rectangle.dashed"; case .freehand: "lasso"; case .polygon: "point.topleft.down.to.point.bottomright.curvepath"; case .windows: "macwindow.on.rectangle" } }
    }
    enum Drag { case create, move, resize(CaptureSelectionHandle) }
    var image: CGImage
    let session: CaptureSelectionSession
    var outputHandler: CaptureSelectionOutputHandler?
    var pinShortcutMatches: (UInt32, UInt32) -> Bool = { _, _ in false }
    var automaticallyCopiesSelection = false
    private(set) var outputWasHandled = false
    private(set) var preparedExport: CaptureSelectionExport?
    private(set) var requestedLiveAction: CaptureSelectionLiveAction?
    private let backdrop = CaptureSelectionBackdropView(frame:.zero)
    private let annotationCanvas = CaptureDrawingView()
    private let selectionOutline = CaptureSelectionOverlayView()
    private var infoHost: NSView?
    private var toolbarHost: NSView?
    private var stylesHost:NSView?
    private var modeHost: NSView?
    private var detailsPopover: NSPopover?
    var windows:[CGRect]=[]
    var displayRects:[CGRect]=[]
    var historyRegions:[CGRect]=[]
    var elementTargets:[(CGRect,pid_t)]=[]
    var screenOrigin=CGPoint.zero
    var completed:((CGRect?,[CaptureSelectionContour])->Void)?
    var initialTool:CaptureTool?
    var initialAction:CaptureShortcutAction?
    var postAction:CaptureSelectionPostAction?
    private var actionButtons:[NSButton]=[]
    var refresh:(() async throws -> CGImage)?
    private var refreshTask:Task<Void,Never>?
    private let allowsShapes:Bool
    private let elementDetectionAllowed:Bool
    private let elementResolver:((CGPoint)->CGRect?)?
    private let elementHitResolver:((CGPoint)->CaptureElementHit?)?
    private let hoverReduceMotion:()->Bool
    private let hoverNow:()->TimeInterval
    private var hover=CaptureElementHoverState()
    private var hoverRetryTask:Task<Void,Never>?
    private var hoverRetryGeneration=0
    private(set) var selected:CGRect?
    private var confirmed=false
    private var handingOff=false
    private var points:[CGPoint]=[]
    private var contours:[CaptureSelectionContour]=[]
    private var originalContours:[CaptureSelectionContour]=[]
    private var anchor:CGPoint?
    private var original:CGRect?
    private var originalPoints:[CGPoint]=[]
    private var drag:Drag = .create
    private var mouse=CGPoint.zero
    private var modifiers:NSEvent.ModifierFlags=[]
    private var ratio:CGFloat?
    private var detectElements=true
    private var canDetectElements:Bool { elementResolver != nil || elementHitResolver != nil || (elementDetectionAllowed && AXIsProcessTrusted()) }
    private(set) var shape:Shape = .rectangle
    private let controls=NSVisualEffectView()
    private let modes=NSSegmentedControl(labels:["矩形","自由","折线","多窗口"],trackingMode:.selectOne,target:nil,action:nil)
    private let operations=NSSegmentedControl(labels:["替换","增加","扣除"],trackingMode:.selectOne,target:nil,action:nil)
    private let history=NSPopUpButton(frame:.zero,pullsDown:true)
    let rounded=NSButton(checkboxWithTitle:"圆角",target:nil,action:nil)
    let shadowButton=NSButton(checkboxWithTitle:"阴影",target:nil,action:nil)
    let border=NSButton(checkboxWithTitle:"边框",target:nil,action:nil)
    private var appearancePopover:NSPopover?
    private var appearanceSliders:[String:NSSlider]=[:]
    private var appearanceValues:[String:NSTextField]=[:]
    private let borderColorWell=CaptureSelectionColorWell()
    private let rememberAppearance=NSButton(checkboxWithTitle:"以后截图沿用这些效果",target:nil,action:nil)
    private let lock=NSButton(checkboxWithTitle:"固定比例",target:nil,action:nil)
    private let refreshButton=NSButton(title:"刷新",target:nil,action:nil)
    private let finishButton=NSButton(title:"编辑",target:nil,action:nil)
    private var fields:[NSTextField]=[]
    private let message=NSTextField(labelWithString:"")
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    init(image:CGImage,allowsShapes:Bool,elementDetectionAllowed:Bool=false,elementResolver:((CGPoint)->CGRect?)?=nil,elementHitResolver:((CGPoint)->CaptureElementHit?)?=nil,sessionDefaults:UserDefaults = .standard,
         hoverReduceMotion:@escaping ()->Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         hoverNow:@escaping ()->TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.image=image;self.allowsShapes=allowsShapes;self.hoverReduceMotion=hoverReduceMotion;self.hoverNow=hoverNow
        session=CaptureSelectionSession(image:image,allowsAnnotations:allowsShapes,defaults:sessionDefaults)
        self.elementDetectionAllowed=elementDetectionAllowed;self.elementResolver=elementResolver;self.elementHitResolver=elementHitResolver
        super.init(frame:.zero)
        session.view=self
        finishButton.title = allowsShapes ? "复制" : "确认范围"
        controls.material = .hudWindow;controls.blendingMode = .withinWindow;controls.state = .active
        controls.wantsLayer=true;controls.layer?.cornerRadius=12;controls.layer?.masksToBounds=true
        let rows=NSStackView();rows.orientation = .vertical;rows.spacing=8;rows.alignment = .leading
        let top=NSStackView();top.spacing=9
        if allowsShapes { modes.selectedSegment=0;modes.target=self;modes.action=#selector(modeChanged);top.addArrangedSubview(modes) }
        for (i,title) in ["X","Y","宽","高"].enumerated() {
            top.addArrangedSubview(NSTextField(labelWithString:title))
            let field=NSTextField(string:"");field.tag=i;field.alignment = .right;field.delegate=self;field.target=self;field.action=#selector(applyFields)
            let formatter=NumberFormatter();formatter.minimum=0;formatter.maximumFractionDigits=0;field.formatter=formatter
            field.widthAnchor.constraint(equalToConstant:52).isActive=true;fields.append(field);top.addArrangedSubview(field)
        }
        let bottom=NSStackView();bottom.spacing=10
        if allowsShapes { operations.selectedSegment=0;operations.target=self;operations.action=#selector(operationChanged);bottom.addArrangedSubview(operations) }
        history.addItem(withTitle:"历史选区");history.target=self;history.action=#selector(restoreHistory);bottom.addArrangedSubview(history)
        lock.target=self;lock.action=#selector(lockChanged);bottom.addArrangedSubview(lock)
        refreshButton.target=self;refreshButton.action=#selector(refreshImage);bottom.addArrangedSubview(refreshButton)
        let reset=NSButton(title:"重新框选",target:self,action:#selector(resetSelection));bottom.addArrangedSubview(reset)
        let cancel=NSButton(title:"取消",target:self,action:#selector(cancelSelection));bottom.addArrangedSubview(cancel)
        finishButton.target=self;finishButton.action=#selector(finishSelection);finishButton.bezelStyle = .rounded;finishButton.keyEquivalent="\r";bottom.addArrangedSubview(finishButton)
        message.font = .systemFont(ofSize:11);message.textColor = .secondaryLabelColor
        rows.addArrangedSubview(top);rows.addArrangedSubview(bottom)
        if allowsShapes {
            let appearance=NSStackView();appearance.spacing=12
            for button in [rounded,shadowButton,border] { button.target=self;button.action=#selector(appearanceChanged);appearance.addArrangedSubview(button) }
            if UserDefaults.standard.bool(forKey:"capture.selection.remember") {
                rounded.state=UserDefaults.standard.bool(forKey:"capture.selection.rounded") ? .on:.off
                shadowButton.state=UserDefaults.standard.bool(forKey:"capture.selection.shadow") ? .on:.off
                border.state=UserDefaults.standard.bool(forKey:"capture.selection.border") ? .on:.off
            }
            let parameters=NSButton(title:"样式",target:self,action:#selector(showAppearance(_:)));appearance.addArrangedSubview(parameters)
            let tools:[CaptureTool]=[.arrow,.rectangle,.mosaic,.text]
            for (index,tool) in tools.enumerated() {
                let button=NSButton(image:NSImage(systemSymbolName:tool.symbol,accessibilityDescription:tool.title)!,target:self,action:#selector(chooseTool(_:)))
                button.tag=index;button.toolTip=tool.title;button.bezelStyle = .texturedRounded;appearance.addArrangedSubview(button);actionButtons.append(button)
            }
            for (index,title) in ["复制","贴图","保存"].enumerated() {
                let button=NSButton(title:title,target:self,action:#selector(chooseAction(_:)));button.tag=index;appearance.addArrangedSubview(button);actionButtons.append(button)
            }
            rows.addArrangedSubview(appearance)
        }
        rows.addArrangedSubview(message)
        rows.translatesAutoresizingMaskIntoConstraints=false;controls.addSubview(rows)
        NSLayoutConstraint.activate([rows.leadingAnchor.constraint(equalTo:controls.leadingAnchor,constant:12),rows.trailingAnchor.constraint(equalTo:controls.trailingAnchor,constant:-12),rows.topAnchor.constraint(equalTo:controls.topAnchor,constant:10),rows.bottomAnchor.constraint(equalTo:controls.bottomAnchor,constant:-10)])
        addSubview(backdrop)
        annotationCanvas.captureCursorOverride={ [weak self] point in self?.annotationCursorOverride(at:point) }
        annotationCanvas.isHidden=true;addSubview(annotationCanvas)
        selectionOutline.paint={ [weak self] rect in self?.drawSelectionOverlay(rect) };addSubview(selectionOutline)
        let info=CaptureFirstMouseHostingView(rootView:CaptureSelectionInfoBar(session:session))
        let toolbar=CaptureFirstMouseHostingView(rootView:CaptureSelectionToolbar(session:session,document:session.document))
        let palette=CaptureFirstMouseHostingView(rootView:CaptureSelectionModePalette(session:session))
        let styles=CaptureFirstMouseHostingView(rootView:CaptureAnnotationStyleBar(editor:session,document:session.document,advanced:{ [weak session] in session?.stylesPresented=true }))
        info.sizingOptions=[];toolbar.sizingOptions=[];palette.sizingOptions=[];styles.sizingOptions=[]
        for host in [info as NSView,toolbar as NSView,palette as NSView,styles as NSView] { host.isHidden=true;addSubview(host) }
        infoHost=info;toolbarHost=toolbar;modeHost=palette;stylesHost=styles
        updateControls()
    }
    required init?(coder:NSCoder) { nil }
    deinit { hoverRetryTask?.cancel() }
    override func layout() { super.layout();positionControls();backdrop.frame=bounds;selectionOutline.frame=bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { mouse=convert(window.mouseLocationOutsideOfEventStream,from:nil) }
        rebuildHistory();updateControls()
        if window == nil { resetHover();backdrop.cancelAnimations() }
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.cursorUpdate,.activeAlways,.inVisibleRect],owner:self));super.updateTrackingAreas()
    }
    override func resetCursorRects() {
        addCursorRect(bounds,cursor:.crosshair)
        if confirmed,let selected {
            addCursorRect(selected,cursor:CaptureInteractionCursor.tool(session.tool).native)
            for handle in CaptureSelectionHandle.allCases {
                let p=handle.point(in:selected)
                addCursorRect(CGRect(x:p.x-9,y:p.y-9,width:18,height:18),cursor:CaptureInteractionCursor.resize(handle).native)
            }
        }
        for host in [infoHost,toolbarHost,modeHost,stylesHost].compactMap({ $0 }) where !host.isHidden { addCursorRect(host.frame,cursor:.arrow) }
    }
    override func cursorUpdate(with event:NSEvent) { interactionCursor(at:convert(event.locationInWindow,from:nil)).native.set() }
    private var scale:CGFloat { bounds.width>0 ? CGFloat(image.width)/bounds.width : 1 }
    /// The crop is rounded outwards in source pixels. Render that exact viewport
    /// back at its source location, not squeezed into the fractional drag rect.
    private var captureViewportFrame:CGRect? {
        guard let pixels=session.document.captureViewport else { return nil }
        return CGRect(x:pixels.minX/scale,y:pixels.minY/scale,width:pixels.width/scale,height:pixels.height/scale)
    }
    private func selectionPath() -> NSBezierPath? {
        if points.count>=3 {
            let path=NSBezierPath();path.move(to:points[0]);points.dropFirst().forEach(path.line);path.close();return path
        }
        return selected.map(NSBezierPath.init(rect:))
    }
    override func draw(_ dirtyRect:NSRect) {
        let snapshot=NSImage(cgImage:image,size:bounds.size)
        snapshot.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        if confirmed,let viewport=captureViewportFrame {
            NSGraphicsContext.saveGraphicsState()
            captureClipPath().addClip()
            NSImage(cgImage:session.document.image,size:.zero).draw(in:viewport,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func displaySelectionPath() -> CGPath? {
        if confirmed { return captureClipPath().cgPath }
        let committed=contours.isEmpty ? nil:captureClipPath().cgPath
        guard let draft=selectionPath()?.cgPath else { return committed }
        guard let committed else { return draft }
        return operations.selectedSegment == 2 ? committed.subtracting(draft,using:.winding):committed.union(draft,using:.winding)
    }
    private func updateSelectionGeometry() {
        if !confirmed,anchor == nil,points.isEmpty,contours.isEmpty,
           shape == .rectangle || shape == .windows,let selected {
            backdrop.updateHoverGeometry(bounds,rect:selected,duration:CaptureBackdropTransition.effectiveDuration(reduceMotion:hoverReduceMotion()))
        } else { backdrop.updateGeometry(bounds,undimmed:displaySelectionPath()) }
    }
    func transitionBackdrop(entering:Bool,duration:TimeInterval) {
        updateSelectionGeometry()
        backdrop.transition(to:entering ? 1:0,from:entering ? 0:nil,duration:duration)
    }
    private func drawSelectionOverlay(_ dirtyRect:NSRect) {
        if !backdrop.presentsHover,let path=selectionPath() { NSColor.controlAccentColor.setStroke();path.lineWidth=1.5;path.stroke() }
        for contour in contours {
            guard let first=contour.points.first else { continue }
            let path=NSBezierPath();path.move(to:first);contour.points.dropFirst().forEach(path.line);path.close()
            (contour.subtract ? NSColor.systemRed:NSColor.controlAccentColor).setStroke();path.lineWidth=1.5;path.stroke()
        }
        if shape == .polygon,!confirmed,!points.isEmpty {
            let path=NSBezierPath();path.move(to:points[0]);points.dropFirst().forEach(path.line);path.line(to:mouse)
            NSColor.controlAccentColor.setStroke();path.lineWidth=2;path.stroke()
        }
        if let selected,confirmed {
            for handle in CaptureSelectionHandle.allCases {
                let point=handle.point(in:selected),box=CGRect(x:point.x-3,y:point.y-3,width:6,height:6)
                NSColor.white.setFill();box.fill();NSColor.controlAccentColor.setStroke();NSBezierPath(rect:box).stroke()
            }
            if modifiers.contains(.option) {
                let path=NSBezierPath()
                for f in [CGFloat(1)/3,CGFloat(2)/3] {
                    path.move(to:CGPoint(x:selected.minX+selected.width*f,y:selected.minY));path.line(to:CGPoint(x:selected.minX+selected.width*f,y:selected.maxY))
                    path.move(to:CGPoint(x:selected.minX,y:selected.minY+selected.height*f));path.line(to:CGPoint(x:selected.maxX,y:selected.minY+selected.height*f))
                }
                NSColor.white.withAlphaComponent(0.5).setStroke();path.setLineDash([3,3],count:2,phase:0);path.stroke()
            }
        }
        if modifiers.contains(.option),!(infoHost?.frame.contains(mouse) ?? false),!(toolbarHost?.frame.contains(mouse) ?? false) { drawLoupe() }
    }
    private func drawLoupe() {
        let area=displayRects.first { $0.contains(mouse) } ?? bounds
        let side:CGFloat=120, origin=CGPoint(x:min(max(area.minX+8,mouse.x+24),area.maxX-side-8),y:min(max(area.minY+8,mouse.y+24),area.maxY-side-48))
        let frame=CGRect(origin:origin,size:CGSize(width:side,height:side+34))
        NSColor.windowBackgroundColor.setFill();NSBezierPath(roundedRect:frame,xRadius:8,yRadius:8).fill()
        let x=Int(mouse.x*scale),y=Int(mouse.y*scale)
        let sample=CGRect(x:x-6,y:y-6,width:13,height:13).intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        if let crop=image.cropping(to:sample) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage:crop,size:.zero).draw(in:CGRect(x:origin.x+4,y:origin.y+4,width:side-8,height:side-8),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        let cross=NSBezierPath();cross.move(to:CGPoint(x:origin.x+side/2,y:origin.y+4));cross.line(to:CGPoint(x:origin.x+side/2,y:origin.y+side-4));cross.move(to:CGPoint(x:origin.x+4,y:origin.y+side/2));cross.line(to:CGPoint(x:origin.x+side-4,y:origin.y+side/2));NSColor.systemRed.setStroke();cross.stroke()
        let text="\(x), \(y)  \(pixelColor())\nC 复制颜色 · ⌥C 复制坐标"
        (text as NSString).draw(in:CGRect(x:origin.x+5,y:origin.y+side,width:side-10,height:32),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:9,weight:.regular),.foregroundColor:NSColor.labelColor])
    }
    private func pixelColor() -> String {
        let x=min(image.width-1,max(0,Int(mouse.x*scale))),y=min(image.height-1,max(0,Int(mouse.y*scale)))
        guard let crop=image.cropping(to:CGRect(x:x,y:y,width:1,height:1)),let context=try? CaptureImage.context(width:1,height:1) else { return "" }
        context.draw(crop,in:CGRect(x:0,y:0,width:1,height:1))
        guard let data=context.data?.assumingMemoryBound(to:UInt8.self) else { return "" }
        return String(format:"#%02X%02X%02X",data[0],data[1],data[2])
    }
    override func flagsChanged(with event:NSEvent) {
        guard !handingOff else { return };modifiers=event.modifierFlags
        if session.choosingMode,!event.modifierFlags.contains(.control) { setCaptureShape(session.pendingMode);session.choosingMode=false;positionSessionControls() }
        needsDisplay=true;selectionOutline.needsDisplay=true
    }
    override func mouseMoved(with event:NSEvent) {
        guard !handingOff else { return }
        let point=convert(event.locationInWindow,from:nil)
        let previous=selected,wasMagnifying=modifiers.contains(.option)
        mouse=point;modifiers=event.modifierFlags
        if captureControl(at:point) != nil { resetHover();NSCursor.arrow.set();return }
        if !confirmed,anchor==nil,(shape == .rectangle || shape == .windows) {
            selected=hoverSelection(at:mouse)
        }
        interactionCursor(at:mouse).native.set()
        if selected != previous { updateSelectionGeometry() }
        // Only vector chrome changes while hovering. Never redraw/resample the
        // frozen screenshot for animation frames or move its source geometry.
        if selected != previous || wasMagnifying || modifiers.contains(.option) || (shape == .polygon && !points.isEmpty) { selectionOutline.needsDisplay=true }
    }
    override func mouseDown(with event:NSEvent) {
        guard !handingOff,!session.exporting else { return }
        let point=convert(event.locationInWindow,from:nil)
        // Plain button padding and NSHostingView/ScrollView can forward an
        // unhandled event. Chrome is never a new screenshot-selection gesture.
        guard captureControl(at:point) == nil else { return }
        window?.makeFirstResponder(self);mouse=point;modifiers=event.modifierFlags
        if confirmed, event.clickCount==2, selected?.contains(mouse)==true, !session.preparingRecording { finishSelection();return }
        if confirmed,session.tool.isDefaultInteraction { session.document.finishMarkEdit();session.document.selectedMarkID=nil }
        if shape == .polygon,!confirmed {
            if event.clickCount==2,points.count>=3 { finalizeShape();return }
            if points.count>=3,let first=points.first,hypot(first.x-mouse.x,first.y-mouse.y)<8 { finalizeShape();return }
            if points.count < 8192 { points.append(mouse) };selected=CaptureSelectionGeometry.bounds(of:points);updateControls();needsDisplay=true;return
        }
        if !confirmed,(shape == .rectangle || shape == .windows) { selected=hoverSelection(at:mouse,force:true) }
        anchor=mouse;original=selected;originalPoints=points;originalContours=contours
        if shape == .windows {
            original=windows.first { $0.contains(mouse) };selected=original;confirmed=false;drag = .create;points=[];updateControls();return
        }
        if confirmed,let selected {
            if let handle=CaptureSelectionHandle.allCases.first(where:{ hypot($0.point(in:selected).x-mouse.x,$0.point(in:selected).y-mouse.y)<9 }) { drag = .resize(handle) }
            else if selected.contains(mouse) { drag = .move }
            else { drag = .create;confirmed=false;points=[];if operations.selectedSegment==0 && shape != .windows { contours=[] } }
        } else { drag = .create;points=shape == .freehand ? [mouse] : [];if operations.selectedSegment==0 && shape != .windows { contours=[] } }
        updateControls();interactionCursor(at:mouse).native.set()
    }
    override func mouseDragged(with event:NSEvent) {
        guard !handingOff,!session.exporting else { return }
        guard let anchor else { return };mouse=convert(event.locationInWindow,from:nil);modifiers=event.modifierFlags
        let point=CGPoint(x:min(bounds.maxX,max(0,mouse.x)),y:min(bounds.maxY,max(0,mouse.y)))
        let delta=CGSize(width:point.x-anchor.x,height:point.y-anchor.y)
        switch drag {
        case .create:
            if shape == .freehand { if points.count < 8192 { points.append(point) };selected=CaptureSelectionGeometry.bounds(of:points) }
            else {
                var dx=delta.width,dy=delta.height
                if let r=modifiers.contains(.shift) ? 1 : ratio { dy=(dy<0 ? -1:1)*abs(dx)/r }
                if modifiers.contains(.option) { dx=abs(dx);dy=abs(dy);selected=CGRect(x:anchor.x-dx,y:anchor.y-dy,width:dx*2,height:dy*2).intersection(bounds) }
                else { selected=CGRect(x:min(anchor.x,anchor.x+dx),y:min(anchor.y,anchor.y+dy),width:abs(dx),height:abs(dy)).intersection(bounds) }
            }
        case .move:
            guard let original else { return }
            var move=delta
            if modifiers.contains(.shift) { if abs(move.width)>abs(move.height) { move.height=0 } else { move.width=0 } }
            selected=CaptureSelectionGeometry.constrain(original.offsetBy(dx:move.width,dy:move.height),in:bounds)
        case .resize(let handle):
            guard let original else { return }
            selected=CaptureSelectionGeometry.resize(original,handle:handle,delta:delta,bounds:bounds,ratio:modifiers.contains(.shift) ? 1 : ratio,centered:modifiers.contains(.option))
        }
        if confirmed,let original,let selected { points=CaptureSelectionGeometry.transform(originalPoints,from:original,to:selected);contours=originalContours.map { CaptureSelectionContour(points:CaptureSelectionGeometry.transform($0.points,from:original,to:selected),subtract:$0.subtract) } }
        updateControls();needsDisplay=true;interactionCursor(at:mouse).native.set()
    }
    override func mouseUp(with event:NSEvent) {
        guard !handingOff else { return }
        guard let anchor else { return };let point=convert(event.locationInWindow,from:nil)
        if case .create=drag,(shape == .rectangle || shape == .windows),hypot(point.x-anchor.x,point.y-anchor.y)<4 {
            if shape == .rectangle,let original,!original.contains(anchor) {
                selected=original.union(CGRect(x:point.x,y:point.y,width:1/scale,height:1/scale)).intersection(bounds)
            } else { selected=original ?? windows.first { $0.contains(point) } }
        }
        self.anchor=nil
        if let selected,selected.width>=8,selected.height>=8,shape != .freehand || points.count>=3 { if case .create=drag { commitContour() };confirmed=true }
        else { if !contours.isEmpty { self.selected=CaptureSelectionGeometry.bounds(of:contours.flatMap(\.points));confirmed=true } else { self.selected=nil };points=[] }
        updateControls();needsDisplay=true;window?.invalidateCursorRects(for:self);interactionCursor(at:point).native.set()
        if case .create=drag { finishAutomaticSelection() }
    }
    override func rightMouseDown(with event:NSEvent) {
        guard !handingOff,!session.exporting,captureControl(at:convert(event.locationInWindow,from:nil)) == nil else { return }
        if shape == .polygon,!confirmed,points.count>=3 { finalizeShape() }
        else if confirmed || !points.isEmpty { resetSelection() } else { cancelSelection() }
    }
    private var canPinCurrentSelection: Bool {
        confirmed && anchor == nil && allowsShapes && !handingOff && !automaticallyCopiesSelection &&
            !session.exporting && !session.preparingRecording && outputHandler != nil
    }

    func pinCurrentSelection() {
        guard canPinCurrentSelection else { return }
        session.submit(.pin)
    }

    func handlePinShortcut(_ event: NSEvent) -> Bool {
        guard canPinCurrentSelection,
              pinShortcutMatches(UInt32(event.keyCode), CaptureShortcutSettings.modifiers(event.modifierFlags)),
              let window, window.isKeyWindow, window.attachedSheet == nil,
              !CaptureKeyboardRouting.isEditingText(in: window) else { return false }
        if !event.isARepeat { pinCurrentSelection() }
        return true
    }

    override func keyDown(with event:NSEvent) {
        guard !handingOff,!session.exporting else { return }
        if handlePinShortcut(event) { return }
        modifiers=event.modifierFlags
        if session.preparingRecording {
            switch event.keyCode {
            case 53: session.leaveRecordingSetup(); return
            case 36,76: session.startRecording(); return
            case 123...126: break
            default: return
            }
        }
        if event.keyCode==48,event.modifierFlags.contains(.control),allowsShapes {
            let current=session.choosingMode ? session.pendingMode:shape
            session.pendingMode=Shape(rawValue:(current.rawValue+(event.modifierFlags.contains(.shift) ? 3:1))%4) ?? .rectangle
            session.choosingMode=true;positionSessionControls();return
        }
        if allowsShapes,confirmed,let action=CaptureShortcutSettings.shared.action(keyCode:UInt32(event.keyCode),modifiers:CaptureShortcutSettings.modifiers(modifiers),scope:.selection),action != .copyColor {
            session.perform(action);return
        }
        switch event.keyCode {
        case 53: if confirmed || !points.isEmpty { resetSelection() } else { cancelSelection() }
        case 36,76: if shape == .polygon,!confirmed { finalizeShape() } else { finishSelection() }
        case 96: refreshImage()
        case 48:
            detectElements.toggle();resetHover()
            if !confirmed,anchor==nil,(shape == .rectangle || shape == .windows) { selected=hoverSelection(at:mouse) }
            updateControls()
        case 8 where !modifiers.contains(.command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(modifiers.contains(.option) ? "\(Int(mouse.x*scale)), \(Int(mouse.y*scale))" : pixelColor(),forType:.string)
        case 0 where modifiers.contains(.command):
            let current=displayRects.first { $0.contains(mouse) } ?? bounds
            selected=confirmed && selected==current ? bounds : current;points=[];contours=[];commitContour();confirmed=true;updateControls()
        case 123...126:
            guard let old=selected,confirmed else { return }
            let pixel:CGFloat=1/scale
            let dx:CGFloat=event.keyCode==123 ? -pixel : event.keyCode==124 ? pixel : 0
            let dy:CGFloat=event.keyCode==126 ? -pixel : event.keyCode==125 ? pixel : 0
            if modifiers.contains(.shift) || modifiers.contains(.command) {
                let handle:CaptureSelectionHandle=event.keyCode==123 ? .left : event.keyCode==124 ? .right : event.keyCode==126 ? .top : .bottom
                let multiplier:CGFloat=modifiers.contains(.command) ? 1 : -1
                setRect(CaptureSelectionGeometry.resize(old,handle:handle,delta:CGSize(width:dx*multiplier,height:dy*multiplier),bounds:bounds,ratio:ratio))
            } else { setRect(CaptureSelectionGeometry.constrain(old.offsetBy(dx:dx,dy:dy),in:bounds)) }
        default: super.keyDown(with:event)
        }
        needsDisplay=true
    }
    private func setRect(_ rect:CGRect) { if let old=selected { points=CaptureSelectionGeometry.transform(points,from:old,to:rect);contours=contours.map { CaptureSelectionContour(points:CaptureSelectionGeometry.transform($0.points,from:old,to:rect),subtract:$0.subtract) } };selected=rect;updateControls();needsDisplay=true }
    private var automaticallyEditsSelection: Bool { allowsShapes && operations.selectedSegment == 0 && shape != .windows }
    private func finishAutomaticSelection() {
        guard confirmed else { return }
        if automaticallyCopiesSelection { session.submit(.copy) }
    }
    private func finalizeShape() { guard points.count>=3,let rect=CaptureSelectionGeometry.bounds(of:points),rect.width>=8,rect.height>=8 else { return };selected=rect;commitContour();confirmed=true;updateControls();needsDisplay=true;finishAutomaticSelection() }
    private func positionControls() {
        let size=controls.fittingSize, width=max(allowsShapes ? 620 : 430,size.width),height=max(100,size.height)
        let rect=selected ?? CGRect(x:bounds.midX-width/2,y:bounds.midY,width:width,height:0)
        let area=displayRects.max { first,second in
            let a=first.intersection(rect),b=second.intersection(rect)
            return (a.isNull ? 0:a.width*a.height)<(b.isNull ? 0:b.width*b.height)
        } ?? bounds
        let y=confirmed ? (rect.maxY+height+12<area.maxY ? rect.maxY+12 : max(area.minY+8,rect.minY-height-12)) : max(area.minY+8,area.maxY-height-30)
        controls.frame=CGRect(x:0,y:0,width:width,height:height)
        _ = y
        positionSessionControls()
    }
    private func updateControls() {
        fields.forEach { $0.isEnabled=confirmed };actionButtons.forEach { $0.isEnabled=confirmed };finishButton.isEnabled=confirmed;lock.isEnabled=confirmed
        if let selected {
            let values=[selected.minX,selected.minY,selected.width,selected.height]
            for (field,value) in zip(fields,values) where window?.firstResponder !== field.currentEditor() { field.integerValue=Int((value*scale).rounded()) }
        }
        message.stringValue=confirmed ? "拖动边角调整范围 · \(allowsShapes ? "Return 复制" : "Return 确认") · ⌥ 放大镜 · F5 刷新" : "拖动框选 · ⌃Tab 切换模式 · Tab 切换元素/窗口 · Esc 取消"
        if session.mode != shape { session.mode=shape }
        let liveRegion = !session.liveActions.isEmpty && liveCaptureRect != nil
        if liveRegion != session.canUseLiveRegion { session.canUseLiveRegion = liveRegion }
        if !confirmed, session.preparingRecording { session.leaveRecordingSetup() }
        session.updateSelection(selected,scale:scale,confirmed:confirmed)
        selectionOutline.needsDisplay=true
        positionControls()
    }
    private func commitContour() {
        guard let selected else { return }
        if operations.selectedSegment==0 && shape != .windows { contours=[] }
        guard contours.count<64 else { showError("选区已达64个，请先完成截图。");return }
        let path=points.count>=3 ? points:CaptureSelectionGeometry.rectangle(selected)
        if operations.selectedSegment != 2 || !contours.isEmpty { contours.append(CaptureSelectionContour(points:path,subtract:operations.selectedSegment==2)) }
        points=[]
        self.selected=CaptureSelectionGeometry.bounds(of:contours.filter { !$0.subtract }.flatMap(\.points))
    }
    @objc private func modeChanged() { shape=Shape(rawValue:modes.selectedSegment) ?? .rectangle;resetSelection();if shape == .windows { operations.selectedSegment=1 } }
    @objc private func operationChanged() { resetHover();if operations.selectedSegment != 0 { confirmed=false;points=[];selected=nil;updateControls();needsDisplay=true } }
    private func rebuildHistory() {
        history.removeAllItems();history.addItem(withTitle:"历史选区")
        for rect in historyRegions { history.addItem(withTitle:"\(Int(rect.width*scale)) × \(Int(rect.height*scale))  (\(Int(rect.minX*scale)), \(Int(rect.minY*scale)))") }
        history.isEnabled = !historyRegions.isEmpty
    }
    @objc private func restoreHistory() {
        let index=history.indexOfSelectedItem-1;guard historyRegions.indices.contains(index) else { return }
        selected=CaptureSelectionGeometry.constrain(historyRegions[index],in:bounds);points=[];contours=[];operations.selectedSegment=0;shape = .rectangle;modes.selectedSegment=0;commitContour();confirmed=true;updateControls();needsDisplay=true
    }
    @objc private func chooseTool(_ sender:NSButton) { session.selectTool([CaptureTool.arrow,.rectangle,.mosaic,.text][sender.tag]) }
    @objc private func chooseAction(_ sender:NSButton) { session.submit([CaptureSelectionPostAction.copy,.pin,.save][sender.tag]) }
    private func parameter(_ name:String,_ fallback:Double) -> CGFloat {
        let value=UserDefaults.standard.object(forKey:"capture.selection."+name) as? Double ?? fallback
        return CGFloat(value.isFinite ? value:fallback)
    }
    var decorationPadding:Int { CaptureSelectionGeometry.decorationPadding(shadow:shadowButton.state == .on,blur:parameter("shadowBlur",10),offset:parameter("shadowOffset",2)) }
    private var decorationColor:NSColor {
        guard let values=UserDefaults.standard.array(forKey:"capture.selection.borderColor") as? [Double],values.count==4,values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return NSColor.white.withAlphaComponent(0.8) }
        return NSColor(srgbRed:values[0],green:values[1],blue:values[2],alpha:values[3])
    }
    func decorate(_ image:CGImage,scale:CGFloat) throws -> CGImage {
        try CaptureSelectionGeometry.decorate(image,cornerRadius:rounded.state == .on ? parameter("radius",12)*scale:0,shadow:shadowButton.state == .on,border:border.state == .on,shadowBlur:parameter("shadowBlur",10),shadowOpacity:parameter("shadowOpacity",0.6),shadowOffset:parameter("shadowOffset",2),borderWidth:parameter("borderWidth",2),borderColor:decorationColor)
    }
    @objc private func appearanceChanged() {
        if UserDefaults.standard.bool(forKey:"capture.selection.remember") { saveAppearanceFlags() }
        needsDisplay=true
    }
    private func saveAppearanceFlags() {
        for (key,button) in [("rounded",rounded),("shadow",shadowButton),("border",border)] { UserDefaults.standard.set(button.state == .on,forKey:"capture.selection."+key) }
    }
    @objc private func showAppearance(_ sender:NSView) {
        appearancePopover?.close()
        let popover=NSPopover();popover.behavior = .transient
        let controller=NSViewController(),stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        appearanceSliders=[:];appearanceValues=[:]
        for (key,title,minimum,maximum,fallback) in [("radius","圆角半径",0.0,120.0,12.0),("shadowBlur","阴影模糊",0.0,80.0,10.0),("shadowOpacity","阴影浓度",0.0,1.0,0.6),("shadowOffset","阴影偏移",0.0,60.0,2.0),("borderWidth","边框宽度",1.0,20.0,2.0)] {
            let row=NSStackView();row.spacing=8
            let label=NSTextField(labelWithString:title);label.widthAnchor.constraint(equalToConstant:70).isActive=true;row.addArrangedSubview(label)
            let slider=NSSlider(value:Double(parameter(key,fallback)),minValue:minimum,maxValue:maximum,target:self,action:#selector(appearanceParameterChanged));slider.widthAnchor.constraint(equalToConstant:170).isActive=true;row.addArrangedSubview(slider)
            let value=NSTextField(labelWithString:key=="shadowOpacity" ? String(format:"%.0f%%",slider.doubleValue*100):String(Int(slider.doubleValue)));value.alignment = .right;value.widthAnchor.constraint(equalToConstant:38).isActive=true;row.addArrangedSubview(value)
            appearanceSliders[key]=slider;appearanceValues[key]=value;stack.addArrangedSubview(row)
        }
        let colorRow=NSStackView();colorRow.spacing=12;colorRow.addArrangedSubview(NSTextField(labelWithString:"边框颜色"))
        borderColorWell.color=decorationColor;borderColorWell.target=self;borderColorWell.action=#selector(appearanceParameterChanged);borderColorWell.widthAnchor.constraint(equalToConstant:50).isActive=true;colorRow.addArrangedSubview(borderColorWell);stack.addArrangedSubview(colorRow)
        rememberAppearance.state=UserDefaults.standard.bool(forKey:"capture.selection.remember") ? .on:.off
        rememberAppearance.target=self;rememberAppearance.action=#selector(appearanceParameterChanged);stack.addArrangedSubview(rememberAppearance)
        let view=NSView(frame:CGRect(x:0,y:0,width:330,height:260));stack.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:12),stack.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-12)])
        controller.view=view;popover.contentViewController=controller;appearancePopover=popover;popover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)
    }
    @objc private func appearanceParameterChanged() {
        for (key,slider) in appearanceSliders {
            UserDefaults.standard.set(slider.doubleValue,forKey:"capture.selection."+key)
            appearanceValues[key]?.stringValue=key=="shadowOpacity" ? String(format:"%.0f%%",slider.doubleValue*100):String(Int(slider.doubleValue))
        }
        if let color=borderColorWell.color.usingColorSpace(.sRGB) { UserDefaults.standard.set([color.redComponent,color.greenComponent,color.blueComponent,color.alphaComponent],forKey:"capture.selection.borderColor") }
        UserDefaults.standard.set(rememberAppearance.state == .on,forKey:"capture.selection.remember")
        if rememberAppearance.state == .on { saveAppearanceFlags() }
        needsDisplay=true
    }
    @objc private func resetSelection() {
        resetHover();preparedExport=nil;session.document.finishMarkEdit();_ = annotationCanvas.cancelActiveInteraction()
        session.tool = .move;session.document.selectedMarkID=nil;selected=nil;confirmed=false;points=[];contours=[];anchor=nil;ratio=nil;lock.state = .off
        window?.makeFirstResponder(self);updateControls();needsDisplay=true
    }
    @objc private func cancelSelection() { completed?(nil,[]) }
    @objc private func finishSelection() {
        guard confirmed,let selected else { return }
        guard !session.preparingRecording, requestedLiveAction == nil else { return }
        if allowsShapes,preparedExport==nil { session.submit(.copy);return }
        window?.makeFirstResponder(self);completed?(selected,contours)
    }
    @objc private func lockChanged() { ratio=lock.state == .on ? selected.map { $0.width/$0.height } : nil }
    @objc private func applyFields() {
        guard confirmed,let old=selected else { return }
        var width=CGFloat(fields[2].doubleValue)/scale,height=CGFloat(fields[3].doubleValue)/scale
        if let ratio { if abs(width-old.width)>0.1 { height=width/ratio } else { width=height*ratio } }
        setRect(CaptureSelectionGeometry.constrain(CGRect(x:CGFloat(fields[0].doubleValue)/scale,y:CGFloat(fields[1].doubleValue)/scale,width:width,height:height),in:bounds))
    }
    func controlTextDidEndEditing(_ obj:Notification) { applyFields() }
    @objc private func refreshImage() {
        guard refreshTask==nil,let refresh else { return };refreshButton.isEnabled=false;resetHover()
        refreshTask=Task { [weak self] in
            do {
                let image=try await refresh();guard !Task.isCancelled,let self else { return }
                try self.session.document.replaceCaptureSource(image)
                self.resetHover();self.image=image
                if !self.confirmed,self.anchor == nil,self.shape == .rectangle || self.shape == .windows { self.selected=self.hoverSelection(at:self.mouse) }
                self.updateSelectionGeometry();self.needsDisplay=true;self.selectionOutline.needsDisplay=true
            }
            catch { self?.showError(error.localizedDescription) }
            self?.refreshTask=nil;self?.refreshButton.isEnabled=true
        }
    }
    func prepareForHandoff() {
        handingOff = true
        cancelRefresh()
        controls.isHidden = true
        positionSessionControls()
    }
    func cancelRefresh() {
        CaptureToolbarHelpView.dismiss(in:self)
        backdrop.cancelAnimations()
        resetHover()
        session.stop();detailsPopover?.close();detailsPopover=nil;outputHandler=nil
        refreshTask?.cancel();refreshTask=nil;appearancePopover?.close();appearancePopover=nil
        if borderColorWell.isActive { NSColorPanel.shared.orderOut(nil) }
        borderColorWell.deactivate()
    }
    func showError(_ text:String) { message.stringValue=text }
    var toolbarFrameInScreen: CGRect? {
        guard let toolbarHost, let window, !toolbarHost.frame.isEmpty else { return nil }
        return window.convertToScreen(convert(toolbarHost.frame, to: nil))
    }

    var selectionPresentationFrame: CGRect {
        guard let selected else { return .zero }
        let frame=window?.convertToScreen(convert(selected,to:nil)) ?? selected
        let padding=CGFloat(decorationPadding)/scale
        return frame.insetBy(dx:-padding,dy:-padding)
    }
    func prepareSelectionExport() throws -> CaptureSelectionExport {
        guard confirmed,let selected else { throw PluginError.invalid("请先选择截图范围。") }
        session.document.finishMarkEdit()
        try session.document.setCaptureViewport(CGRect(x:selected.minX*scale,y:selected.minY*scale,width:selected.width*scale,height:selected.height*scale))
        let pixels=session.document.captureViewport ?? .zero
        let aligned=CGRect(x:pixels.minX/scale,y:pixels.minY/scale,width:pixels.width/scale,height:pixels.height/scale)
        let masked=try CaptureSelectionGeometry.masked(session.document.image,contours:contours,rect:aligned,scale:scale)
        let output=try decorate(masked,scale:scale)
        let editable=shape == .rectangle && contours.count<=1 && contours.first?.subtract != true && rounded.state == .off && shadowButton.state == .off && border.state == .off
        return CaptureSelectionExport(image:output,base:editable ? session.document.unmarkedImage:output,marks:editable ? session.document.archiveMarks:[])
    }
    func completeCaptureOutput(_ output:CaptureSelectionExport,action:CaptureSelectionPostAction,handled:Bool) {
        guard !handingOff else { return }
        preparedExport=output;outputWasHandled=handled;postAction=action == .edit ? nil:action
        finishSelection()
    }
    private var liveCaptureRect: CGRect? {
        guard confirmed, let rect = selected, rect.width >= 8, rect.height >= 8,
              shape == .rectangle || shape == .windows, contours.count == 1,
              contours[0].points.count == 4, !contours[0].subtract else { return nil }
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        let aligned = CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
                             width: pixels.width / scale, height: pixels.height / scale)
        return (displayRects.isEmpty ? [bounds] : displayRects).contains { $0.contains(aligned) } ? rect : nil
    }

    func confirmLiveCapture(_ action: CaptureSelectionLiveAction) {
        guard !handingOff, !session.exporting, requestedLiveAction == nil,
              session.liveActions.contains(action), action.isSupported, let completed else { return }
        guard let rect = liveCaptureRect else { rejectLiveCapture(); return }
        requestedLiveAction = action
        completed(rect, contours)
    }

    func showRecordingSetup() {
        CaptureToolbarHelpView.dismiss(in: self)
        detailsPopover?.close(); detailsPopover = nil
        appearancePopover?.close(); appearancePopover = nil
        if borderColorWell.isActive { NSColorPanel.shared.orderOut(nil); borderColorWell.deactivate() }
        _ = cancelAnnotationDraft()
        configureAnnotationCanvas()
        session.focusCanvas()
    }

    func rejectLiveCapture() {
        requestedLiveAction = nil
        session.error = "请选择同一显示器内的单个矩形区域。"
    }

    func confirmCaptureRange() { guard !allowsShapes else { return };finishSelection() }
    func cancelCapture() { cancelSelection() }
    func resetCaptureSelection() { resetSelection() }
    func refreshCaptureImage() { refreshImage() }
    func setCaptureShape(_ value:Shape) {
        modes.selectedSegment=value.rawValue;modeChanged();session.pendingMode=value;session.choosingMode=false;positionSessionControls()
    }
    func setCaptureOperation(_ value:Int) { operations.selectedSegment=value;operationChanged() }
    func showSelectionDetails() {
        guard let anchor=infoHost else { return }
        detailsPopover?.close()
        let popover=NSPopover(),controller=NSViewController()
        controller.view=controls;popover.contentViewController=controller;popover.behavior = .transient
        detailsPopover=popover;popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
    }
    func showSelectionAppearance() { if let infoHost { showAppearance(infoHost) } }
    func cancelAnnotationDraft() -> Bool { annotationCanvas.cancelActiveInteraction() }
    func configureAnnotationCanvas(image rendered:CGImage?=nil) {
        let document=session.document
        window?.invalidateCursorRects(for:self)
        annotationCanvas.isHidden = !confirmed || !allowsShapes || session.preparingRecording
        guard confirmed,let viewport=captureViewportFrame else { return }
        annotationCanvas.frame=viewport
        let image=rendered ?? document.image
        if annotationCanvas.image !== image { annotationCanvas.image=image;annotationCanvas.bitmap=NSBitmapImageRep(cgImage:image) }
        annotationCanvas.captureOverlay=true;annotationCanvas.floating=false
        annotationCanvas.coordinateOrigin=document.coordinateOrigin
        var transform=CGAffineTransform(translationX:-viewport.minX,y:-viewport.minY)
        annotationCanvas.captureClip=captureClipPath().cgPath.copy(using:&transform)
        annotationCanvas.tool=session.tool;annotationCanvas.color=NSColor(session.color);annotationCanvas.width=session.width
        annotationCanvas.captureRangeEvent={ [weak self] event in
            switch event.type {
            case .leftMouseDown:self?.mouseDown(with:event)
            case .leftMouseDragged:self?.mouseDragged(with:event)
            case .leftMouseUp:self?.mouseUp(with:event)
            case .rightMouseDown:self?.rightMouseDown(with:event)
            default:break
            }
        }
        annotationCanvas.text=session.text;annotationCanvas.style=session.style;annotationCanvas.number=session.nextNumber
        annotationCanvas.marks=document.marks;annotationCanvas.selectedID=document.selectedMarkID
        annotationCanvas.selected={ [weak document] in document?.selectedMarkID=$0 }
        annotationCanvas.beginEdit={ [weak document] in document?.beginMarkEdit($0) }
        annotationCanvas.preview={ [weak document] in document?.previewMark($0) }
        annotationCanvas.finishEdit={ [weak document] in document?.finishMarkEdit() }
        annotationCanvas.marked={ [weak session] in session?.addMark($0) }
        annotationCanvas.removed={ [weak document] in document?.removeMark(at:$0) }
        annotationCanvas.selectionAction={ [weak document] in document?.selectionAction($0) }
        annotationCanvas.editText={ [weak session] in session?.editCaption($0) }
        annotationCanvas.sizeCanvas(viewport.size);annotationCanvas.needsDisplay=true
        selectionOutline.needsDisplay=true
        positionSessionControls()
    }
    private func captureClipPath() -> NSBezierPath {
        guard !contours.isEmpty else { return selected.map(NSBezierPath.init(rect:)) ?? NSBezierPath() }
        var result=CGPath(rect:.zero,transform:nil)
        for contour in contours {
            let path=CGMutablePath();path.addLines(between:contour.points);path.closeSubpath()
            result=contour.subtract ? result.subtracting(path,using:.winding):result.union(path,using:.winding)
        }
        return NSBezierPath(cgPath:result)
    }
    func positionSessionControls() {
        let visible=displayRects.first(where:{ $0.contains(selected.map { CGPoint(x:$0.midX,y:$0.midY) } ?? mouse) }) ?? bounds
        infoHost?.isHidden = !confirmed || handingOff || session.preparingRecording
        toolbarHost?.isHidden = !confirmed || handingOff || session.toolbarHidden
        modeHost?.isHidden = !session.choosingMode || handingOff || session.preparingRecording
        stylesHost?.isHidden = !confirmed || handingOff || session.toolbarHidden || !allowsShapes ||
            session.preparingRecording || !session.inspectorTool.hasAnnotationStyle
        for host in [infoHost,toolbarHost,modeHost,stylesHost].compactMap({ $0 }) where host.isHidden { CaptureToolbarHelpView.dismiss(in:host) }
        if let selected {
            let labelWidth=ceil((session.sizeLabel as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.regular)]).width)
            let infoWidth=min(max(100,labelWidth+76),max(100,visible.width-16))
            let preferredWidth = session.preparingRecording ? CaptureSelectionToolbarMetrics.recordingWidth :
                CaptureSelectionToolbarMetrics.width(allowsAnnotations: allowsShapes, liveActionCount: session.liveActions.count)
            let toolbarWidth=min(preferredWidth,max(100,visible.width-16))
            let height=CaptureSelectionToolbarMetrics.height
            let x=min(max(selected.minX,visible.minX+8),max(visible.minX+8,visible.maxX-infoWidth-8))
            let above=selected.minY-36
            let infoBelow = infoHost?.isHidden == false && above < visible.minY + 8 && selected.maxY + 44 + height + 8 < visible.maxY
            let infoY=above>=visible.minY+8 ? above:infoBelow ? selected.maxY+8:visible.minY+12
            infoHost?.frame=CGRect(x:x,y:infoY,width:infoWidth,height:30)
            let below=selected.maxY+(infoBelow ? 44:8)
            let y=below+height<=visible.maxY-8 ? below:max(visible.minY+8,selected.minY-height-44)
            toolbarHost?.frame=CGRect(x:min(max(selected.maxX-toolbarWidth,visible.minX+8),max(visible.minX+8,visible.maxX-toolbarWidth-8)),y:y,width:toolbarWidth,height:height)
        }
        if let toolbar=toolbarHost?.frame {
            let width=CaptureStyleBarMetrics.width(tool:session.inspectorTool,style:session.style)
            stylesHost?.frame=CaptureStyleBarMetrics.frame(toolbar:toolbar,visible:visible,width:width,avoid:infoHost?.isHidden == false ? infoHost?.frame:nil,flipped:true)
        }
        modeHost?.frame=CGRect(x:visible.midX-196,y:visible.midY-48,width:392,height:88)
        selectionOutline.frame=bounds
        updateSelectionGeometry()
    }
    private func selectionHandle(at point:CGPoint) -> CaptureSelectionHandle? {
        guard confirmed,let selected else { return nil }
        return CaptureSelectionHandle.allCases.first { hypot($0.point(in:selected).x-point.x,$0.point(in:selected).y-point.y)<=9 }
    }
    private func annotationCursorOverride(at point:CGPoint) -> CaptureInteractionCursor? {
        let local=annotationCanvas.convert(point,to:self)
        if session.exporting || captureControl(at:local) != nil { return .arrow }
        return selectionHandle(at:local).map(CaptureInteractionCursor.resize)
    }
    func interactionCursor(at point:CGPoint) -> CaptureInteractionCursor {
        if session.exporting { return .arrow }
        if anchor != nil {
            switch drag { case .move: return .closedHand;case .resize(let handle): return .resize(handle);case .create: return .crosshair }
        }
        if captureControl(at:point) != nil { return .arrow }
        if let handle=selectionHandle(at:point) { return .resize(handle) }
        guard confirmed,let selected,selected.contains(point),captureClipPath().contains(point) else { return .crosshair }
        return annotationCanvas.interactionCursor(at:annotationCanvas.convert(point,from:self))
    }
    private func captureControl(at point:CGPoint) -> NSView? {
        [modeHost,toolbarHost,stylesHost,infoHost].compactMap { $0 }.first { !$0.isHidden && $0.frame.contains(point) }
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        let local=convert(point,from:superview)
        if let control=captureControl(at:local) { return control.hitTest(local) ?? control }
        let hit=super.hitTest(point)
        guard hit === annotationCanvas else { return hit }
        return selectionHandle(at:local) != nil || !captureClipPath().contains(local) || session.exporting ? self:hit
    }
    private func resetHover() { cancelHoverRetry();hover.reset() }
    private func cancelHoverRetry() { hoverRetryGeneration &+= 1;hoverRetryTask?.cancel();hoverRetryTask=nil }
    private func hoverSelection(at point:CGPoint,force:Bool=false) -> CGRect? {
        let hint=force ? nil:hover.refinementHint(at:point,window:windows.first { $0.contains(point) })
        let result=hover.selectionUsingHit(at:point,window:windows.first { $0.contains(point) },
                        enabled:shape != .windows && detectElements && canDetectElements,
                        now:hoverNow(),force:force) {
            if let elementHitResolver { return elementHitResolver(point) }
            if let elementResolver { return elementResolver(point).map { CaptureElementHit(rect:$0) } }
            return elementHit(at:point,hint:hint)
        }
        scheduleHoverRetry()
        return result
    }
    private func scheduleHoverRetry() {
        guard let delay=hover.retryDelay(now:hoverNow()) else { cancelHoverRetry();return }
        guard hoverRetryTask == nil else { return }
        let generation=hoverRetryGeneration,deadline=ContinuousClock.now.advanced(by:.seconds(delay))
        // A bounded uncertain-hit validation, even
        // if the mouse stops. No idle polling, AX objects, or per-frame tasks.
        hoverRetryTask=Task { @MainActor [weak self] in
            do { if ContinuousClock.now<deadline { try await Task.sleep(until:deadline,clock:.continuous) } } catch { return }
            guard let self,!Task.isCancelled,self.hoverRetryGeneration == generation else { return }
            self.hoverRetryTask=nil
            guard self.window != nil,!self.handingOff,!self.confirmed,self.anchor == nil,!self.session.choosingMode,self.captureControl(at:self.mouse) == nil,
                  self.shape == .rectangle || self.shape == .windows else { self.resetHover();return }
            let previous=self.selected
            self.selected=self.hoverSelection(at:self.mouse)
            if self.selected != previous { self.updateSelectionGeometry();self.selectionOutline.needsDisplay=true }
        }
    }
    private func elementHit(at point:CGPoint,hint previous:CaptureElementHint?) -> CaptureElementHit? {
        let global=CGPoint(x:screenOrigin.x+point.x,y:screenOrigin.y+point.y)
        guard let target=elementTargets.first(where:{ $0.0.contains(global) }),target.1 != ProcessInfo.processInfo.processIdentifier else { return nil }
        let hint=previous.map { CaptureElementHint(anchor:CGPoint(x:$0.anchor.x+screenOrigin.x,y:$0.anchor.y+screenOrigin.y),container:$0.container.offsetBy(dx:screenOrigin.x,dy:screenOrigin.y)) }
        guard let hit=CaptureElementHitTesting.accessibilityHit(pid:target.1,at:global,within:target.0,hint:hint) else { return nil }
        func local(_ rect:CGRect)->CGRect { rect.offsetBy(dx:-screenOrigin.x,dy:-screenOrigin.y).intersection(bounds) }
        return CaptureElementHit(rect:local(hit.rect),ancestors:hit.ancestors.map(local),limited:hit.limited,visitedNodes:hit.visitedNodes,depth:hit.depth,anchor:hit.anchor.map { CGPoint(x:$0.x-screenOrigin.x,y:$0.y-screenOrigin.y) })
    }
}

/// A vector shade, not another full-screen image or raster backing bitmap.
final class CaptureSelectionBackdropView:NSView {
    static let animationKey="capture.backdrop.opacity"
    static let hoverAnimationKey="capture.hover.path"
    static let hoverOutlineName="capture.hover.outline"
    private var shadePath:CGPath?
    private var shadeFillRule:CAShapeLayerFillRule = .nonZero
    private var hoverRect:CGRect?
    private var hoverStartRect:CGRect?
    private var hoverCleanupDeadline:ContinuousClock.Instant?
    private var hoverCleanupTask:Task<Void,Never>?
    var sleepForHoverCleanup: @MainActor (ContinuousClock.Instant) async throws -> Void = { deadline in
        if ContinuousClock.now < deadline { try await Task.sleep(until: deadline, clock: .continuous) }
    }
    private let hoverOutline=CAShapeLayer()
    var presentsHover:Bool { hoverRect != nil }
    /// Read the visible pose only while a path interpolation owns the layer.
    /// Before its first CA commit, the start is the last displayed pose.
    var presentedHoverRect:CGRect? {
        guard let hoverRect else { return nil }
        guard hoverOutline.animation(forKey:Self.hoverAnimationKey) != nil else { return hoverRect }
        return hoverOutline.presentation()?.path?.boundingBoxOfPath ?? hoverStartRect ?? hoverRect
    }
    override var isFlipped:Bool { true }
    override var isOpaque:Bool { false }
    override var wantsUpdateLayer:Bool { true }
    override init(frame:NSRect) { super.init(frame:frame);wantsLayer=true }
    required init?(coder:NSCoder) { nil }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func updateLayer() {
        guard let shape=layer as? CAShapeLayer else { return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        shape.fillColor=NSColor.black.withAlphaComponent(0.44).cgColor
        shape.fillRule=shadeFillRule;shape.path=shadePath
        if hoverOutline.superlayer !== shape { shape.addSublayer(hoverOutline) }
        hoverOutline.name=Self.hoverOutlineName;hoverOutline.frame=bounds
        hoverOutline.contentsScale=window?.backingScaleFactor ?? 1
        hoverOutline.fillColor=nil;hoverOutline.strokeColor=NSColor.controlAccentColor.cgColor
        hoverOutline.lineWidth=1.5;hoverOutline.isHidden=hoverRect == nil
        hoverOutline.path=hoverRect.map { CGPath(rect:$0,transform:nil) }
        CATransaction.commit()
    }
    private func hoverShade(_ rect:CGRect) -> CGPath {
        // Always two rectangles, even when the hole touches the screen edge or
        // fills it. Boolean subtraction would change path topology mid-tween.
        let path=CGMutablePath();path.addRect(bounds);path.addRect(rect);return path
    }
    private func stopGeometryAnimation(keepCleanup:Bool=false) {
        hoverStartRect=nil
        layer?.removeAnimation(forKey:Self.hoverAnimationKey)
        hoverOutline.removeAnimation(forKey:Self.hoverAnimationKey)
        if !keepCleanup {
            hoverCleanupDeadline=nil
            hoverCleanupTask?.cancel();hoverCleanupTask=nil
        }
    }
    func cancelAnimations() {
        stopGeometryAnimation()
        layer?.removeAllAnimations();hoverOutline.removeAllAnimations()
    }
    private func scheduleHoverCleanup(after duration:TimeInterval) {
        // Core Animation can keep completed path animations attached when a
        // window is not being rendered. Model geometry is already at the
        // destination. Release both paths together even without render ticks.
        hoverCleanupDeadline=ContinuousClock.now.advanced(by:.seconds(duration))
        guard hoverCleanupTask == nil else { return }
        hoverCleanupTask=Task { @MainActor [weak self, sleep = sleepForHoverCleanup] in
            while !Task.isCancelled,let deadline=self?.hoverCleanupDeadline {
                do { try await sleep(deadline) } catch { return }
                guard let self,!Task.isCancelled else { return }
                // A retarget extends this single lease, not a queue of tasks.
                guard self.hoverCleanupDeadline == deadline else { continue }
                self.stopGeometryAnimation()
                return
            }
        }
    }
    func updateHoverGeometry(_ area:CGRect,rect:CGRect,duration:TimeInterval) {
        let duration=CaptureBackdropTransition.duration(duration)
        if frame == area,hoverRect == rect {
            if duration == 0 { stopGeometryAnimation() }
            return // Stable hits and layout must not restart the current tween.
        }
        let start=presentedHoverRect
        let animate=duration>0 && frame == area && hoverRect != nil && start != rect
        stopGeometryAnimation(keepCleanup:animate)
        frame=area;hoverRect=rect;shadeFillRule = .evenOdd;shadePath=hoverShade(rect)
        updateLayer()
        guard animate,let start,let layer else { stopGeometryAnimation();return }
        hoverStartRect=start
        let now=CACurrentMediaTime()
        for (target,from,to) in [(layer,hoverShade(start),hoverShade(rect)),
                                (hoverOutline,CGPath(rect:start,transform:nil),CGPath(rect:rect,transform:nil))] {
            let animation=CABasicAnimation(keyPath:"path")
            animation.fromValue=from;animation.toValue=to;animation.duration=duration
            animation.beginTime=target.convertTime(now,from:nil)
            animation.timingFunction=CAMediaTimingFunction(name:.easeOut)
            target.add(animation,forKey:Self.hoverAnimationKey)
        }
        scheduleHoverCleanup(after:duration)
    }
    func updateGeometry(_ area:CGRect,undimmed:CGPath?) {
        stopGeometryAnimation();hoverRect=nil;shadeFillRule = .nonZero
        frame=area
        let whole=CGPath(rect:bounds,transform:nil)
        shadePath=undimmed.map { whole.subtracting($0,using:.winding) } ?? whole
        updateLayer()
    }
    func transition(to opacity:Float,from initial:Float?=nil,duration:TimeInterval) {
        guard let layer else { return }
        let start=initial ?? layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey:Self.animationKey)
        CATransaction.begin();CATransaction.setDisableActions(true);layer.opacity=opacity;CATransaction.commit()
        guard duration>0,start != opacity else { return }
        let animation=CABasicAnimation(keyPath:"opacity")
        animation.fromValue=start;animation.toValue=opacity;animation.duration=duration
        animation.timingFunction=CAMediaTimingFunction(name:.easeOut)
        layer.add(animation,forKey:Self.animationKey)
    }
}

private final class CaptureSelectionOverlayView: NSView {
    var paint: ((NSRect)->Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point:NSPoint)->NSView? { nil }
    override func draw(_ dirtyRect:NSRect) { paint?(dirtyRect) }
}
