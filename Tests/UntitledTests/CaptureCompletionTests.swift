import AppKit
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor
struct CaptureCompletionTests {
    @Test func releasingAnOrdinaryRegionKeepsTheSameEditableSelection() throws {
        let (view, panel) = try selection()
        defer { panel.close() }
        var regions: [CGRect] = []
        view.completed = { rect, _ in if let rect { regions.append(rect) } }
        try drag(view, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 230, y: 150))
        #expect(regions.isEmpty && view.session.hasSelection)
        #expect(view.selected == CGRect(x: 30, y: 30, width: 200, height: 120))
        #expect(view.initialTool == nil && view.postAction == nil)
        try drag(view,from:CGPoint(x:230,y:150),to:CGPoint(x:290,y:190))
        #expect(view.selected == CGRect(x:30,y:30,width:260,height:160))
        #expect(regions.isEmpty)
    }

    @Test func aHandingOffSelectionIsFrozenAndCannotCompleteAgain() throws {
        let (view, panel) = try selection()
        defer { panel.close() }
        var completed = 0
        view.completed = { rect, _ in
            if rect != nil { completed += 1; view.prepareForHandoff() }
        }
        try drag(view, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 230, y: 150))
        view.keyDown(with: try key(36, "\r", in: panel))
        try drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 170))
        view.keyDown(with: try key(36, "\r", in: panel))
        #expect(completed == 1)
        #expect(view.session.stopped)
        let bars=view.subviews.filter { $0 is CaptureFirstMouseHostingView<CaptureSelectionToolbar> || $0 is CaptureFirstMouseHostingView<CaptureSelectionInfoBar> }
        let hidden=bars.allSatisfy { $0.isHidden }
        #expect(hidden)
    }

    @Test(arguments: [CaptureSelectionView.Shape.freehand, .polygon])
    func completingASingleFreeformShapeDoesNotNeedAnotherEditConfirmation(shape: CaptureSelectionView.Shape) throws {
        let (view, panel) = try selection()
        defer { panel.close() }
        view.setCaptureShape(shape)
        var completed = 0
        view.completed = { rect, _ in if rect != nil { completed += 1 } }
        if shape == .polygon {
            for point in [CGPoint(x: 30, y: 30), CGPoint(x: 230, y: 30), CGPoint(x: 130, y: 150)] {
                view.mouseDown(with: try mouse(.leftMouseDown, at: point, in: view))
                view.mouseUp(with: try mouse(.leftMouseUp, at: point, in: view))
            }
            #expect(completed == 0)
            view.keyDown(with: try key(36, "\r", in: panel))
        } else {
            view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 30, y: 30), in: view))
            for point in [CGPoint(x: 230, y: 30), CGPoint(x: 230, y: 150), CGPoint(x: 30, y: 150)] {
                view.mouseDragged(with: try mouse(.leftMouseDragged, at: point, in: view))
            }
            view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 30, y: 150), in: view))
        }
        #expect(completed == 0 && view.session.hasSelection && view.initialTool == nil && view.postAction == nil)
    }

    @Test func clickingADetectedWindowAlsoEntersEditingWithoutConfirmation() throws {
        let (view, panel) = try selection()
        defer { panel.close() }
        let region = CGRect(x: 25, y: 25, width: 240, height: 160)
        view.windows = [region]
        var completed: CGRect?
        view.completed = { rect, _ in completed = rect }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 60, y: 60), in: view))
        #expect(completed == nil && view.selected == region && view.session.hasSelection)
    }

    @Test func invalidDragsDoNotAdvanceAndRecordingRangeStillRequiresConfirmation() throws {
        for allowsShapes in [true, false] {
            let (view, panel) = try selection(allowsShapes: allowsShapes)
            defer { panel.close() }
            var completed = 0
            view.completed = { rect, _ in if rect != nil { completed += 1 } }
            try drag(view, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 32, y: 32))
            #expect(completed == 0)
            if !allowsShapes {
                try drag(view, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 230, y: 150))
                #expect(completed == 0)
                view.keyDown(with: try key(36, "\r", in: panel))
                #expect(completed == 1)
                #expect(view.postAction == nil)
            }
        }
    }

    @Test func multipleWindowsStaySelectableUntilExplicitConfirmation() throws {
        let (view, panel) = try selection()
        defer { panel.close() }
        view.setCaptureShape(.windows)
        view.windows = [CGRect(x: 20, y: 20, width: 100, height: 80), CGRect(x: 200, y: 20, width: 100, height: 80)]
        var contours: [CaptureSelectionContour] = []
        var completions = 0
        view.completed = { rect, paths in if rect != nil { contours = paths; completions += 1 } }
        for point in [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 50)] {
            view.mouseDown(with: try mouse(.leftMouseDown, at: point, in: view))
            view.mouseUp(with: try mouse(.leftMouseUp, at: point, in: view))
        }
        #expect(completions == 0)
        view.keyDown(with: try key(36, "\r", in: panel))
        #expect(completions == 1 && contours.count == 2)
    }

    @Test func commandCInAConfirmedComplexSelectionCopiesTheImageNotPixelColor() throws {
        let (view, panel) = try selection()
        defer { panel.close() }
        view.setCaptureShape(.windows)
        view.windows = [CGRect(x: 20, y: 20, width: 120, height: 80)]
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 50, y: 50), in: view))
        var completions = 0
        view.completed = { rect, _ in if rect != nil { completions += 1 } }
        view.keyDown(with: try key(8, "c", flags: .command, in: panel))
        #expect(completions == 1 && view.postAction == .copy)
    }

    @Test(arguments: [CaptureShortcutAction.copy, .copyAndClose])
    func copyingAnnotatedImageClosesBothPanelsAndRetainsTheLatestPixels(action: CaptureShortcutAction) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureCopy-" + UUID().uuidString)
        let domain = "CaptureCopy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: domain); pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        var writes = 0, commits = 0, closes = 0
        let document = CaptureDocument(image: try image(width: 100, height: 80), copyDefaults: defaults, writeClipboard: { data in
            writes += 1; pasteboard.clearContents(); return pasteboard.setData(data, forType: .png)
        })
        document.add(CaptureMark(tool: .cover, points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)], color: .black, width: 2))
        var storedPNG: Data?
        document.commit = { _, png in commits += 1; storedPNG = png }
        let controller = ScreenshotController(directory: folder)
        let editor = CaptureFloatingEditor(document: document, controller: controller, annotationDefaults: defaults)
        defer { editor.close() }
        editor.onClose = { closes += 1 }
        editor.show()
        editor.perform(action)
        let data = try #require(pasteboard.data(forType: .png))
        #expect(data == storedPNG)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 100 && bitmap.pixelsHigh == 80)
        let color = try #require(bitmap.colorAt(x: 20, y: 20))
        #expect(color.brightnessComponent < 0.05)
        #expect(editor.isClosed && !editor.canvasPanel.isVisible && !editor.toolsPanel.isVisible)
        #expect(editor.canvasPanel.contentView == nil && editor.toolsPanel.contentView == nil)
        #expect(writes == 1 && commits == 1 && closes == 1)
        editor.perform(action)
        #expect(writes == 1 && closes == 1)
    }

    @Test func completedCaptureOffersTheSamePNGOnlyAfterLocalClipboardSucceeds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureCopyOffer-" + UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        var accepts = false
        let controller = ScreenshotController(directory: folder, writePNGToPasteboard: {
            accepts ? CaptureClipboard.writePNG($0, to: board) : nil
        })
        var offered = 0
        controller.didCopyPNG = { png, generation in
            offered += 1
            #expect(png == board.data(forType: .png) && board.changeCount == generation)
            if let record = controller.history.first {
                #expect((try? Data(contentsOf: controller.url(record))) == png)
            } else {
                Issue.record("Copy offered without a saved capture")
            }
        }
        defer { controller.didCopyPNG = { _, _ in } }
        let source = try image(width: 320, height: 240)
        #expect(throws: PluginError.self) { try controller.copyAndStore(source) }
        #expect(offered == 0 && board.data(forType: .png) == nil)
        accepts = true
        try controller.copyAndStore(source)
        #expect(offered == 1)
    }

    @Test func clipboardRejectionKeepsTheEditorOpenAndAllowsRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureCopyRetry-" + UUID().uuidString)
        let domain = "CaptureCopyRetry-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: folder) }
        var accepts = false, writes = 0
        let document = CaptureDocument(image: try image(width: 100, height: 80), copyDefaults: defaults, writeClipboard: { _ in writes += 1; return accepts })
        let controller = ScreenshotController(directory: folder)
        let editor = CaptureFloatingEditor(document: document, controller: controller, annotationDefaults: defaults)
        defer { editor.close() }
        editor.show()
        editor.perform(.copy)
        #expect(!editor.isClosed && editor.canvasPanel.isVisible && editor.toolsPanel.isVisible)
        #expect(document.error?.contains("剪贴板") == true && writes == 1)
        accepts = true
        editor.perform(.copyAndClose)
        #expect(editor.isClosed && writes == 2)
    }

    @Test func failedPersistenceDoesNotWriteTheClipboardOrDiscardAnnotations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureCopyFailure-" + UUID().uuidString)
        let domain = "CaptureCopyFailure-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: folder) }
        var writes = 0
        let document = CaptureDocument(image: try image(width: 100, height: 80), copyDefaults: defaults, writeClipboard: { _ in writes += 1; return true })
        document.add(CaptureMark(tool: .cover, points: [.zero, CGPoint(x: 20, y: 20)], color: .black, width: 2))
        document.commit = { _, _ in throw PluginError.invalid("Test persistence failed") }
        let controller = ScreenshotController(directory: folder)
        let editor = CaptureFloatingEditor(document: document, controller: controller, annotationDefaults: defaults)
        defer { document.commit = nil; editor.close() }
        editor.show()
        editor.perform(.copyAndClose)
        #expect(!editor.isClosed && writes == 0 && document.marks.count == 1)
        #expect(document.error?.contains("Test persistence failed") == true)
    }

    private func selection(allowsShapes: Bool = true) throws -> (CaptureSelectionView, NSPanel) {
        let view = CaptureSelectionView(image: try image(width: 1200, height: 800), allowsShapes: allowsShapes)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = view
        return (view, panel)
    }
    private func drag(_ view: CaptureSelectionView, from start: CGPoint, to end: CGPoint) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: end, in: view))
    }
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try CaptureImage.context(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
