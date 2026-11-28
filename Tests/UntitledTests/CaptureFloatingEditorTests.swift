import AppKit
import SwiftUI
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized)
struct CaptureFloatingEditorTests {
    @Test func selectionCoordinatesPreserveRetinaSizeAndMultipleScreenOrigins() {
        let screen = CGRect(x: -1440, y: 900, width: 1440, height: 900)
        let selection = CGRect(x: 125.5, y: 100, width: 400, height: 250)
        let frame = CaptureFloatingLayout.screenRect(selection, on: screen)
        #expect(frame == CGRect(x: -1314.5, y: 1450, width: 400, height: 250))
        #expect(CaptureFloatingLayout.imageFrame(size: CGSize(width: 800, height: 500), preferred: frame, screen: screen, pixelsPerPoint: 2) == frame)
    }
    @Test func freshCaptureFramesAreNotRefittedToOneScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selected = CGRect(x: -600, y: 120, width: 1800, height: 500)
        let size = CGSize(width: 3600, height: 1000)
        #expect(CaptureFloatingLayout.imageFrame(size: size, preferred: selected, screen: screen,
            pixelsPerPoint: 2, preservePreferredFrame: true) == selected)
        // History/old pin placement still adapts to a disconnected/off-screen monitor.
        let restored = CaptureFloatingLayout.imageFrame(size: size, preferred: selected, screen: screen, pixelsPerPoint: 2)
        #expect(screen.contains(restored) && restored != selected)
        let decoratedEdge = CGRect(x: -16, y: -16, width: 1432, height: 832)
        #expect(CaptureFloatingLayout.imageFrame(size: CGSize(width: 2864, height: 1664), preferred: decoratedEdge,
            screen: screen, pixelsPerPoint: 2, preservePreferredFrame: true) == decoratedEdge)
    }
    @Test @MainActor func selectionSurfacesStayVisibleUntilTheEditorHasItsFinalGeometry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureHandoff-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = try #require(NSScreen.main)
        let selected = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 200)
        let selectionPanel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        selectionPanel.isReleasedWhenClosed = false
        selectionPanel.contentView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        CaptureWindowPolicy.markControl(selectionPanel, name: "testSelection")
        selectionPanel.orderFrontRegardless()
        let presentation = CaptureSelectionPresentation(panels: [selectionPanel])
        defer { presentation.dismiss() }
        let controller = ScreenshotController(directory: folder)
        defer { controller.deactivate() }
        controller.accept(try fixture(width: 800, height: 400), at: selected)
        let editor = try #require(controller.editors.first)
        #expect(selectionPanel.isVisible)
        #expect(selectionPanel.animationBehavior == .none)
        #expect(editor.canvasPanel.animationBehavior == .none && editor.toolsPanel.animationBehavior == .none)
        #expect(editor.imageFrame == selected)
        let canvas = try #require(editor.canvasPanel.contentView)
        let hosting = try #require(canvas as? CaptureFirstMouseHostingView<CaptureFloatingCanvasView>)
        #expect(hosting.sizingOptions.isEmpty)
        let drawing = try #require(findDrawing(in: canvas))
        let firstImageRect = drawing.imageRect
        #expect(firstImageRect == CGRect(origin: .zero, size: selected.size))
        presentation.dismiss()
        presentation.dismiss()
        #expect(!selectionPanel.isVisible && selectionPanel.contentView == nil)
        #expect(editor.canvasPanel.isVisible && editor.toolsPanel.isVisible)
        for _ in 0..<5 {
            await Task.yield()
            canvas.layoutSubtreeIfNeeded()
            #expect(editor.imageFrame == selected && drawing.imageRect == firstImageRect)
        }
    }
    @Test @MainActor func tenHandoffsReleaseBothSourceAndEditorWindows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureHandoffCycles-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        defer { controller.deactivate() }
        let screen = try #require(NSScreen.main)
        let frame = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 200)
        let image = try fixture(width: 800, height: 400)
        for iteration in 0..<10 {
            let source = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false; source.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
            source.level = .screenSaver; source.orderFrontRegardless()
            let presentation = CaptureSelectionPresentation(panels: [source])
            controller.accept(image, at: frame, presentation: presentation)
            let editor = try #require(controller.editors.last)
            if iteration.isMultiple(of: 2) {
                try await Task.sleep(for: .milliseconds(230))
                #expect(!source.isVisible && editor.canvasPanel.level == .floating)
            }
            editor.close()
            #expect(controller.editors.isEmpty)
            #expect(!source.isVisible && source.contentView == nil)
            #expect(!editor.canvasPanel.isVisible && !editor.toolsPanel.isVisible)
            #expect(editor.canvasPanel.contentView == nil && editor.toolsPanel.contentView == nil)
            await Task.yield()
        }
    }
    @Test @MainActor func backdropDurationRespectsReducedMotionAndIsBounded() {
        #expect(CaptureBackdropTransition.effectiveDuration(reduceMotion: true) == 0)
        #expect(CaptureBackdropTransition.effectiveDuration(reduceMotion: false) == 0.12)
        #expect(CaptureBackdropTransition.duration(100) == 0.2)
        #expect(CaptureBackdropTransition.duration(-1) == 0)
        #expect(CaptureBackdropTransition.duration(.nan) == 0)
    }
    @Test(arguments: [0.0, 0.03]) @MainActor func backdropEntranceDoesNotAnimateGeometry(duration: TimeInterval) async throws {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 100)
        let panel = testPanel(frame)
        defer { panel.close() }
        CaptureBackdropTransition.show(panel, duration: duration)
        #expect(panel.isVisible && panel.animationBehavior == .none && panel.frame == frame)
        try await Task.sleep(for: .milliseconds(100))
        #expect(panel.alphaValue == 1 && panel.frame == frame)
    }
    @Test @MainActor func boundedFadeLeaseReleasesAnOtherwiseAbandonedPresentation() async throws {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 100)
        let source = testPanel(frame), canvas = testPanel(frame)
        source.level = .screenSaver; canvas.level = .floating
        source.orderFrontRegardless(); canvas.orderFrontRegardless()
        defer { source.close(); canvas.close() }
        var presentation: CaptureSelectionPresentation? = CaptureSelectionPresentation(panels: [source])
        weak var reference = presentation
        presentation?.beginHandoff(above: [canvas], duration: 0.04)
        presentation = nil
        #expect(reference != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(reference == nil && !source.isVisible && source.contentView == nil)
        #expect(canvas.isVisible && canvas.level == .floating && canvas.alphaValue == 1)
    }
    @Test @MainActor func aBusyMainActorDoesNotStartANewFullLeaseAfterTheDeadline() async throws {
        let frame=CGRect(x:100,y:100,width:160,height:100)
        let source=testPanel(frame),canvas=testPanel(frame)
        source.level = .screenSaver;canvas.level = .floating
        source.orderFrontRegardless();canvas.orderFrontRegardless()
        defer { source.close();canvas.close() }
        let presentation=CaptureSelectionPresentation(panels:[source])
        presentation.beginHandoff(above:[canvas],duration:0.03)
        // Deliberate synchronous layout-like work before the task can start.
        func occupyMainActor() { Thread.sleep(forTimeInterval:0.14) }
        occupyMainActor()
        try await Task.sleep(for:.milliseconds(40))
        #expect(!source.isVisible && !presentation.isActive)
        #expect(canvas.level == .floating && canvas.alphaValue == 1)
    }

    @Test @MainActor func backgroundFadeNeverAnimatesTheEditorAndRestoresItsLevel() async throws {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 100)
        let backdrop = testPanel(frame)
        backdrop.level = .screenSaver; backdrop.orderFrontRegardless()
        let canvas = testPanel(frame), toolbar = testPanel(frame.offsetBy(dx: 0, dy: -120))
        for panel in [canvas, toolbar] { panel.level = .floating; panel.orderFrontRegardless() }
        defer { backdrop.close(); canvas.close(); toolbar.close() }
        let presentation = CaptureSelectionPresentation(panels: [backdrop])
        presentation.beginHandoff(above: [canvas, toolbar], duration: 0.04)
        presentation.complete() // The caller's defer must not cut off the fade.
        #expect(backdrop.isVisible && backdrop.ignoresMouseEvents)
        #expect(canvas.level.rawValue > backdrop.level.rawValue && toolbar.level == canvas.level)
        #expect(canvas.alphaValue == 1 && toolbar.alphaValue == 1 && canvas.frame == frame)
        try await Task.sleep(for: .milliseconds(180))
        #expect(!backdrop.isVisible && backdrop.contentView == nil)
        #expect(canvas.isVisible && toolbar.isVisible)
        #expect(canvas.level == .floating && toolbar.level == .floating)
        #expect(canvas.alphaValue == 1 && toolbar.alphaValue == 1 && canvas.frame == frame)
    }
    @Test @MainActor func cancellingABackdropFadeRestoresLevelsImmediatelyAndIsIdempotent() async throws {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 100)
        let backdrop = testPanel(frame), canvas = testPanel(frame)
        backdrop.level = .screenSaver; canvas.level = .floating
        backdrop.orderFrontRegardless(); canvas.orderFrontRegardless()
        defer { backdrop.close(); canvas.close() }
        let presentation = CaptureSelectionPresentation(panels: [backdrop])
        presentation.beginHandoff(above: [canvas], duration: 0.12)
        presentation.dismiss(); presentation.dismiss(); presentation.complete()
        #expect(!backdrop.isVisible && backdrop.contentView == nil)
        #expect(canvas.level == .floating && canvas.frame == frame && canvas.alphaValue == 1)
        try await Task.sleep(for: .milliseconds(230))
        #expect(canvas.isVisible && canvas.level == .floating && canvas.frame == frame)
    }
    @Test @MainActor func closingTheEditorAlsoCancelsItsPendingBackdrop() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureFadeClose-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backdrop = testPanel(CGRect(x: 80, y: 80, width: 320, height: 200))
        backdrop.level = .screenSaver; backdrop.orderFrontRegardless()
        defer { backdrop.close() }
        let presentation = CaptureSelectionPresentation(panels: [backdrop])
        let controller = ScreenshotController(directory: folder)
        defer { controller.deactivate() }
        controller.accept(try fixture(width: 640, height: 400), at: backdrop.frame, presentation: presentation)
        let editor = try #require(controller.editors.first)
        let frame = editor.imageFrame
        #expect(editor.canvasPanel.alphaValue == 1 && editor.toolsPanel.alphaValue == 1)
        editor.close()
        #expect(!backdrop.isVisible && backdrop.contentView == nil && controller.editors.isEmpty)
        #expect(editor.canvasPanel.level == .floating && editor.toolsPanel.level == .floating)
        #expect(editor.imageFrame == frame)
    }
    @Test @MainActor func reducedMotionPathDoesNotRaiseOrFadeTheCanvas() {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 100)
        let backdrop = testPanel(frame), canvas = testPanel(frame)
        backdrop.level = .screenSaver; canvas.level = .floating
        backdrop.orderFrontRegardless(); canvas.orderFrontRegardless()
        defer { backdrop.close(); canvas.close() }
        let presentation = CaptureSelectionPresentation(panels: [backdrop])
        presentation.beginHandoff(above: [canvas], duration: 0)
        #expect(!backdrop.isVisible && backdrop.contentView == nil)
        #expect(canvas.level == .floating && canvas.frame == frame && canvas.alphaValue == 1)
    }
    @Test @MainActor func abandoningHandoffReleasesEverySelectionSurface() async throws {
        let panels = (0..<2).map { _ in
            let panel = NSPanel(contentRect: CGRect(x: 40, y: 40, width: 100, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
            panel.orderFrontRegardless()
            return panel
        }
        var presentation: CaptureSelectionPresentation? = CaptureSelectionPresentation(panels: panels)
        #expect(presentation != nil && panels.allSatisfy(\.isVisible))
        presentation = nil
        try await Task.sleep(for: .milliseconds(20))
        #expect(panels.allSatisfy { !$0.isVisible && $0.contentView == nil })
    }
    @Test func toolbarAvoidsScreenEdgesAndChoosesTheFreeSide() {
        let visible = CGRect(x: -1280, y: -300, width: 1280, height: 780)
        let middle = CGRect(x: -1100, y: -50, width: 400, height: 250)
        let below = CaptureFloatingLayout.toolbarFrame(image: middle, visible: visible)
        #expect(visible.contains(below))
        #expect(below.maxY <= middle.minY)
        let bottom = CGRect(x: -100, y: -295, width: 80, height: 60)
        let above = CaptureFloatingLayout.toolbarFrame(image: bottom, visible: visible)
        #expect(visible.contains(above))
        #expect(above.minY >= bottom.maxY)
        for image in [visible, CGRect(x: -1280, y: 400, width: 30, height: 30), CGRect(x: -40, y: -290, width: 25, height: 25)] {
            #expect(visible.contains(CaptureFloatingLayout.toolbarFrame(image: image, visible: visible)))
        }
    }
    @Test @MainActor func captureEditsInPlaceAndPinsAtTheSamePosition() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FloatingEditorTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        defer { controller.deactivate() }
        let screen = try #require(NSScreen.main)
        let frame = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 200)
        let image = try fixture(width: 800, height: 400)
        controller.accept(image, at: frame)
        let editor = try #require(controller.editors.first)
        #expect(editor.imageFrame == frame)
        #expect(!editor.canvasPanel.styleMask.contains(.titled))
        #expect(editor.canvasPanel.standardWindowButton(.closeButton) == nil)
        #expect(editor.canvasPanel.contentView?.bounds.size == frame.size)
        #expect(screen.visibleFrame.contains(editor.toolsPanel.frame))
        editor.document.add(CaptureMark(tool: .cover, points: [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 100)], color: .black, width: 3))
        editor.perform(.undo); #expect(editor.document.marks.isEmpty)
        editor.perform(.redo); #expect(editor.document.marks.count == 1)
        editor.perform(.pin)
        #expect(editor.isClosed && controller.editors.isEmpty)
        let pin = try #require(controller.pinManager.records.first)
        #expect(pin.frame == frame)
        let saved = try CaptureImage.load(controller.pinManager.url(pin))
        #expect(NSBitmapImageRep(cgImage: saved).colorAt(x: 60, y: 60)!.brightnessComponent < 0.05)
        #expect(controller.history.count == 1)
    }
    @Test @MainActor func textToolsAndHiddenToolbarKeepTheSameCanvasAndCloseTogether() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FloatingLayoutTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        let editor = CaptureFloatingEditor(document: CaptureDocument(image: try fixture(width: 640, height: 320)), controller: controller)
        defer { editor.close() }
        editor.show()
        let frame = editor.imageFrame
        editor.perform(.text)
        for _ in 0..<3 { await Task.yield() }
        #expect(editor.imageFrame == frame)
        #expect(editor.toolsPanel.frame.height == CaptureFloatingLayout.toolbarSize.height)
        editor.document.add(CaptureMark(tool: .crop, points: [CGPoint(x: 40, y: 40), CGPoint(x: 320, y: 240)], color: .red, width: 2))
        for _ in 0..<3 { await Task.yield() }
        let factor = frame.width / 640
        #expect(abs(editor.imageFrame.minX - (frame.minX + 40 * factor)) < 0.01)
        #expect(abs(editor.imageFrame.maxY - (frame.maxY - 40 * factor)) < 0.01)
        editor.perform(.undo)
        for _ in 0..<3 { await Task.yield() }
        #expect(editor.imageFrame == frame)
        editor.perform(.hideToolbar)
        for _ in 0..<3 { await Task.yield() }
        #expect(!editor.toolsPanel.isVisible && editor.canvasPanel.isVisible)
        editor.perform(.hideToolbar)
        for _ in 0..<3 { await Task.yield() }
        #expect(editor.toolsPanel.isVisible)
        editor.close()
        #expect(editor.isClosed && !editor.toolsPanel.isVisible && !editor.canvasPanel.isVisible)
    }
    @Test @MainActor func placeholderWindowNumbersAreSkippedWithoutIntegerTraps() {
        #expect(CaptureWindowPolicy.captureID(0) == nil)
        #expect(CaptureWindowPolicy.captureID(-1) == nil)
        #expect(CaptureWindowPolicy.captureID(Int.max) == nil)
        #expect(CaptureWindowPolicy.captureID(Int(UInt32.max) + 1) == nil)
        #expect(CaptureWindowPolicy.captureID(1234) == 1234)
    }
    @Test @MainActor func snapshotKeepsMainContentAndPinsButOmitsCaptureControls() throws {
        let main = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let pin = NSPanel(contentRect: CGRect(x: 70, y: 70, width: 120, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
        let toolbar = NSPanel(contentRect: CGRect(x: 70, y: 170, width: 150, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let hidden = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        let windows = [main, pin, toolbar, hidden]
        for window in windows { window.isReleasedWhenClosed = false }
        defer { windows.forEach { $0.close() } }
        CaptureWindowPolicy.markControl(toolbar, name: "testToolbar")
        main.orderFront(nil); pin.orderFront(nil); toolbar.orderFront(nil)
        let included = CaptureWindowPolicy.contentWindowIDs(in: windows)
        #expect(included.contains(CGWindowID(main.windowNumber)))
        #expect(included.contains(CGWindowID(pin.windowNumber)))
        #expect(!included.contains(CGWindowID(toolbar.windowNumber)))
        #expect(!included.contains(CGWindowID(hidden.windowNumber)))
    }
    @Test @MainActor func firstDragAfterToolbarFocusCreatesTheSelectedMark() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureFocusTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        let editor = CaptureFloatingEditor(document: CaptureDocument(image: try fixture(width: 640, height: 320)), controller: controller)
        defer { editor.close() }
        editor.show()
        func drawingView(in view: NSView) -> CaptureDrawingView? {
            if let drawing = view as? CaptureDrawingView { return drawing }
            return view.subviews.lazy.compactMap { drawingView(in: $0) }.first
        }
        let root = try #require(editor.canvasPanel.contentView)
        for (index, action) in [CaptureShortcutAction.rectangle, .arrow, .mosaic].enumerated() {
            editor.perform(action)
            for _ in 0..<3 { await Task.yield() }
            root.layoutSubtreeIfNeeded()
            let drawing = try #require(drawingView(in: root))
            #expect(drawing.tool == action.tool)
            #expect(root.acceptsFirstMouse(for: nil))
            #expect(drawing.acceptsFirstMouse(for: nil))
            editor.toolsPanel.makeKeyAndOrderFront(nil)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: drawing.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.canvasPanel.windowNumber,
                    context: nil, eventNumber: index + 1, clickCount: 1, pressure: 1))
            }
            editor.canvasPanel.sendEvent(try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
            editor.canvasPanel.sendEvent(try event(.leftMouseDragged, CGPoint(x: 90, y: 60)))
            editor.canvasPanel.sendEvent(try event(.leftMouseUp, CGPoint(x: 90, y: 60)))
            #expect(editor.document.marks.count == index + 1)
            #expect(editor.document.marks.last?.tool == action.tool)
        }
    }
    @Test @MainActor func defaultDragMovesImageAndToolbarWithoutDrawingOrAccumulatedOffset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMoveTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        let original = try fixture(width: 640, height: 320)
        let visible = try #require(NSScreen.main?.visibleFrame)
        let toolbarWidth = min(CaptureFloatingLayout.toolbarSize.width, visible.width - 16)
        let horizontalMove = min(55, max(0, (visible.width - toolbarWidth - 16) / 2))
        // Start with room for the requested motion; boundary clamping is tested separately.
        let preferred = CGRect(x: visible.maxX - 8 - horizontalMove - 640,
                               y: visible.midY - 160, width: 640, height: 320)
        let editor = CaptureFloatingEditor(document: CaptureDocument(image: original), controller: controller,
                                           preferredFrame: preferred)
        defer { editor.close() }
        editor.show()
        for _ in 0..<3 { await Task.yield() }
        let root = try #require(editor.canvasPanel.contentView)
        root.layoutSubtreeIfNeeded()
        func drawingView(in view: NSView) -> CaptureDrawingView? {
            if let drawing = view as? CaptureDrawingView { return drawing }
            return view.subviews.lazy.compactMap { drawingView(in: $0) }.first
        }
        let drawing = try #require(drawingView(in: root))
        #expect(editor.tool == .move && drawing.tool == .move)
        #expect(editor.canvasPanel.collectionBehavior.contains(.canJoinAllApplications))
        #expect(editor.toolsPanel.collectionBehavior.contains(.canJoinAllApplications))
        let before = editor.imageFrame, toolbar = editor.toolsPanel.frame
        let start = editor.canvasPanel.convertPoint(toScreen: drawing.convert(CGPoint(x: 20, y: 20), to: nil))
        func event(_ type: NSEvent.EventType, dx: CGFloat, dy: CGFloat) throws -> NSEvent {
            let point = CGPoint(x: start.x + dx, y: start.y + dy)
            return try #require(NSEvent.mouseEvent(with: type, location: editor.canvasPanel.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.canvasPanel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        editor.toolsPanel.makeKeyAndOrderFront(nil)
        editor.canvasPanel.sendEvent(try event(.leftMouseDown, dx: 0, dy: 0))
        editor.canvasPanel.sendEvent(try event(.leftMouseDragged, dx: horizontalMove / 2, dy: -10))
        editor.canvasPanel.sendEvent(try event(.leftMouseDragged, dx: horizontalMove, dy: -35))
        editor.canvasPanel.sendEvent(try event(.leftMouseUp, dx: horizontalMove, dy: -35))
        #expect(editor.imageFrame == before.offsetBy(dx: horizontalMove, dy: -35))
        #expect(editor.toolsPanel.frame == toolbar.offsetBy(dx: horizontalMove, dy: -35))
        #expect(editor.document.marks.isEmpty && editor.document.undoCount == 0)
        #expect(editor.document.image === original)
    }
    @Test @MainActor func moreMenuGlyphSharesTheHoverPlateCenterBeforeAndAfterHover() async throws {
        let observation=MenuBounds()
        let content=HStack(spacing:12) {
            Menu { Button("工具顺序") {} } label: {
                CaptureToolbarMoreIcon().panelRegion("more.label")
            }
            .menuStyle(.button).menuIndicator(.hidden).frame(width:28,height:28)
            .modifier(CaptureToolbarControl(hint:"工具顺序与更多操作"))
            .panelRegion("more.control")
            Button {} label: { Image(systemName:"ellipsis").frame(width:28,height:28) }
                .modifier(CaptureToolbarControl(hint:"对比图标"))
                .panelRegion("more.reference")
        }.padding(6).font(.system(size:13))
        .coordinateSpace(name:PanelLayout.coordinateSpace)
        .onPreferenceChange(PanelLayoutBoundsKey.self) { value in MainActor.assumeIsolated { observation.frames=value } }
        let host=NSHostingView(rootView:content);host.sizingOptions=[]
        let panel=testPanel(CGRect(x:0,y:0,width:80,height:40));panel.contentView=host;panel.orderFrontRegardless()
        defer { CaptureToolbarHelpView.dismiss(in:host);panel.close();panel.contentView=nil }
        panel.displayIfNeeded();try await Task.sleep(for:.milliseconds(60))
        let control=try #require(observation.frames["more.control"])
        #expect(control.size == CGSize(width:28,height:28) && observation.frames["more.label"] == control)
        let help=try #require(menuDescendants(host).compactMap { $0 as? CaptureToolbarHelpView }.first { $0.hint == "工具顺序与更多操作" })
        for hovering in [false,true] {
            if hovering {
                let event=try #require(NSEvent.mouseEvent(with:.mouseMoved,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0))
                help.mouseEntered(with:event);try await Task.sleep(for:.milliseconds(30))
            }
            host.displayIfNeeded()
            let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            let scale=CGFloat(bitmap.pixelsWide)/host.bounds.width
            func ink(_ frame:CGRect)->(peak:CGFloat,coverage:CGFloat) {
                var peak:CGFloat=0,coverage:CGFloat=0
                for y in Int(frame.minY*scale)..<Int(frame.maxY*scale) {
                    for x in Int(frame.minX*scale)..<Int(frame.maxX*scale) {
                        let alpha=bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0
                        peak=max(peak,alpha);if alpha>0.2 { coverage += alpha }
                    }
                }
                return (peak,coverage)
            }
            let dots=ink(control),reference=ink(try #require(observation.frames["more.reference"]))
            #expect(dots.peak>=reference.peak*0.95 && dots.coverage>=reference.coverage*0.95)
            var minX=bitmap.pixelsWide,maxX = -1,minY=bitmap.pixelsHigh,maxY = -1
            for y in Int(control.minY*scale)..<Int(control.maxY*scale) {
                for x in Int(control.minX*scale)..<Int(control.maxX*scale) {
                    if let color=bitmap.colorAt(x:x,y:y),color.alphaComponent>0.6 {
                        minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
                    }
                }
            }
            #expect(maxX>=minX && maxY>=minY)
            let center=CGPoint(x:CGFloat(minX+maxX+1)/(2*scale),y:CGFloat(minY+maxY+1)/(2*scale))
            #expect(abs(center.x-control.midX)<0.26 && abs(center.y-control.midY)<0.26)
            #expect(observation.frames["more.label"] == control)
        }
    }
    @MainActor private final class MenuBounds { var frames:[String:CGRect]=[:] }
    @MainActor private func menuDescendants(_ root:NSView)->[NSView] { [root]+root.subviews.flatMap(menuDescendants) }
    @Test @MainActor func hoverHelpWorksWithoutActivationAndDoesNotInterceptClicks() throws {
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 120, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let help = CaptureToolbarHelpView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        help.hint = "箭头（⇧3）"
        panel.contentView = help
        defer { help.dismissHint(); panel.close() }
        panel.orderFrontRegardless()
        help.updateTrackingAreas()
        #expect(help.trackingAreas.contains { $0.options.contains(.activeAlways) })
        #expect(help.hitTest(CGPoint(x: 14, y: 14)) == nil)
        help.showHint()
        let hint = try #require(help.hintPanel)
        #expect(hint.isVisible && hint.ignoresMouseEvents && !hint.canBecomeKey)
        help.dismissHint()
        #expect(!hint.isVisible && help.hintPanel == nil)
    }
    @Test @MainActor func hoverFeedbackHasOneDelayedHintAndReleasesWhenChromeHides() async throws {
        let panel=testPanel(CGRect(x:100,y:100,width:80,height:32))
        let container=try #require(panel.contentView)
        let first=CaptureToolbarHelpView(frame:CGRect(x:0,y:0,width:28,height:28))
        let second=CaptureToolbarHelpView(frame:CGRect(x:32,y:0,width:28,height:28))
        first.hint="箭头";second.hint="复制"
        var entered=false,exited=false
        first.hoverChanged={ if $0 { entered=true } else { exited=true } }
        container.addSubview(first);container.addSubview(second);panel.orderFrontRegardless()
        defer { first.endHover();second.endHover();panel.close();panel.contentView=nil }
        let event=try #require(NSEvent.mouseEvent(with:.mouseMoved,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0))
        first.mouseEntered(with:event)
        #expect(entered && first.isHovering && first.hintPanel == nil)
        // The 350 ms dwell runs on the main actor; CI may schedule it late.
        // Wait for the actual panel without weakening the delayed-show assertion.
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while first.hintPanel == nil && first.isHovering && ContinuousClock.now<deadline {
            try await Task.sleep(for:.milliseconds(20))
        }
        let hint=try #require(first.hintPanel)
        #expect(hint.isVisible && !panel.isKeyWindow)
        second.mouseEntered(with:event)
        #expect(exited && !first.isHovering && !hint.isVisible && first.hintPanel == nil)
        #expect(second.isHovering && second.hintPanel == nil)
        container.isHidden=true
        CaptureToolbarHelpView.dismiss(in:container)
        try await Task.sleep(for:.milliseconds(410))
        #expect(!second.isHovering && second.hintPanel == nil)
        first.showHint()
        #expect(first.hintPanel == nil)
    }
    @MainActor private func testPanel(_ frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        return panel
    }
    @MainActor private func findDrawing(in view: NSView) -> CaptureDrawingView? {
        if let drawing = view as? CaptureDrawingView { return drawing }
        return view.subviews.lazy.compactMap { findDrawing(in: $0) }.first
    }
    private func fixture(width: Int, height: Int) throws -> CGImage {
        let context = try CaptureImage.context(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
