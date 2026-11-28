import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Untitled

@Suite(.serialized)
struct CapturePinMediaTests {
    @Test @MainActor func oldPinRecordsRemainReadableWithoutNewFields() throws {
        let item=CapturePinRecord(filename:"example.png",text:"legacy")
        var object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as? [String:Any])
        object.removeValue(forKey:"payload");object.removeValue(forKey:"adjustments");object.removeValue(forKey:"viewport")
        let decoded=try JSONDecoder().decode(CapturePinRecord.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(decoded.text=="legacy" && decoded.payload==nil && decoded.viewport==nil)
    }
    @Test @MainActor func selectedPinsMoveAndCloseTogetherAndLockedPinsStayOpen() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let manager=CapturePinManager(directory:folder,displaysWindows:false)
        let image=try #require(CaptureImage.context(width:20,height:10).makeImage())
        let first=try manager.create(image),second=try manager.create(image),third=try manager.create(image)
        manager.selectedIDs=[first,second]
        manager.toggle(first,\.locked)
        manager.closeSelection(first)
        #expect(manager.record(first)?.isOpen==true)
        #expect(manager.record(second)?.isOpen==false)
        #expect(manager.record(third)?.isOpen==true)
        #expect(manager.records.count == 3)
        #expect(manager.record(second)?.closedAt != nil)
    }
    @Test @MainActor func longPinsFitInsideDisplayMarginsWithoutDistortingTheImage() throws {
        // A secondary display above and left of the main one, with a side Dock.
        let display = CGRect(x: -1440, y: 900, width: 1440, height: 900)
        let visible = CGRect(x: -1370, y: 900, width: 1370, height: 870)
        for size in [CGSize(width: 320, height: 6400), CGSize(width: 6400, height: 320)] {
            let image = try #require(CaptureImage.context(width: Int(size.width), height: Int(size.height)).makeImage())
            let pin = ScreenshotController.scrollPinFrame(for: image, within: display, visibleFrame: visible)
            #expect(visible.insetBy(dx: 23.9, dy: 23.9).contains(pin))
            #expect(abs(pin.width * size.height / size.width - pin.height) < 0.01)
            #expect(pin.maxY == visible.maxY - 24)
        }
    }
    @Test @MainActor func draggingPastAllFourEdgesNeverSnapsThePinBack() async throws {
        let app = NSApplication.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = CapturePinManager(directory: folder, automaticExports: false)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            manager.deactivate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let context = try CaptureImage.context(width: 96, height: 672)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 672))
        let image = try #require(context.makeImage())
        let start = CGRect(x: visible.midX.rounded() - 24, y: visible.midY.rounded() - 168, width: 48, height: 336)
        let id = try manager.create(image, frame: start)
        let pin = try #require(app.windows.first { $0.isVisible && !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel })
        pin.contentView?.layoutSubtreeIfNeeded()
        let host = try #require(pin.contentView)
        func findSurface(_ view: NSView) -> CapturePinSurface.Surface? {
            (view as? CapturePinSurface.Surface) ?? view.subviews.lazy.compactMap { findSurface($0) }.first
        }
        let surface = try #require(findSurface(host))
        surface.mouseSettings = CapturePinMouseSettings(defaults: defaults)

        let local = CGPoint(x: pin.frame.width / 2, y: pin.frame.height / 2)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: local, modifierFlags: [],
                    timestamp: 0, windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: local, modifierFlags: [],
                    timestamp: 0, windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        func drag(dx: CGFloat, dy: CGFloat) throws {
            // The absolute cursor coordinate stays fixed. Only the motion in
            // the drag event changes, like continuing a drag against an edge.
            let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                          mouseCursorPosition: CGPoint(x: 100, y: 0), mouseButton: .left))
            cg.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            cg.setIntegerValueField(.mouseEventDeltaY, value: Int64(-dy))
            surface.mouseDragged(with: try #require(NSEvent(cgEvent: cg)))
        }

        let before = pin.frame
        let outside = [
            CGPoint(x: desktop.minX.rounded(.down) - before.width - 80, y: before.minY),
            CGPoint(x: desktop.maxX.rounded(.up) + 80, y: before.minY),
            CGPoint(x: before.minX, y: desktop.minY.rounded(.down) - before.height - 80),
            CGPoint(x: before.minX, y: desktop.maxY.rounded(.up) + 80),
        ]
        for (index, target) in outside.enumerated() {
            surface.mouseDown(with: down)
            try drag(dx: target.x - before.minX, dy: target.y - before.minY)
            surface.mouseUp(with: up)
            let moved = CGRect(origin: target, size: before.size)
            #expect(pin.frame == moved && !desktop.intersects(pin.frame))
            if index != outside.count - 1 {
                manager.dragSelection(id, delta: CGSize(width: before.minX - pin.frame.minX, height: before.minY - pin.frame.minY))
                #expect(pin.frame == before)
            }
        }

        let offscreen = CGRect(origin: try #require(outside.last), size: before.size)
        manager.toggleAll()
        manager.toggleAll()
        try await Task.sleep(for: .milliseconds(40))
        #expect(pin.frame == offscreen && manager.record(id)?.frame == offscreen)
        manager.deactivate()

        let reopened = CapturePinManager(directory: folder, automaticExports: false)
        defer { reopened.deactivate() }
        reopened.activate()
        let restored = try #require(app.windows.first { $0 !== pin && !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel })
        #expect(restored.frame == offscreen && reopened.record(id)?.frame == offscreen)
        reopened.restore(id) // The existing “定位” action is the opt-in way to bring it back.
        #expect(!visible.intersection(restored.frame).isEmpty)
        #expect(restored.frame.size == before.size)
    }
    @Test @MainActor func screenHeightPinCanMoveUpZoomOutAndReopenAtItsNewPosition() async throws {
        let app = NSApplication.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = CapturePinManager(directory: folder, automaticExports: false)
        defer {
            manager.deactivate()
            try? FileManager.default.removeItem(at: folder)
        }
        let context = try CaptureImage.context(width: 160, height: 6400)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 6400))
        let image = try #require(context.makeImage())
        let bottomAligned = CGRect(x: visible.midX, y: visible.minY, width: visible.height / 40, height: visible.height)
        let id = try manager.create(image, frame: bottomAligned)
        func pinWindow() throws -> NSWindow {
            try #require(app.windows.first { $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel })
        }
        let asset = manager.url(try #require(manager.record(id)))
        let original = try Data(contentsOf: asset)
        let panel = try pinWindow()
        panel.contentView?.layoutSubtreeIfNeeded()
        let before = panel.frame
        #expect(abs(before.minY - visible.minY) < 1 && abs(before.height - visible.height) < 1)
        let lift = min(85, visible.height / 5)
        manager.dragSelection(id, delta: CGSize(width: 0, height: lift))
        #expect(abs(panel.frame.minY - before.minY - lift) < 1)
        #expect(panel.frame.size == before.size)

        manager.toggle(id, \.locked)
        let lockedFrame = panel.frame
        manager.dragSelection(id, delta: CGSize(width: 0, height: lift))
        #expect(panel.frame == lockedFrame)
        manager.toggle(id, \.locked)
        manager.scroll(id, delta: -12, opacity: false)
        try await Task.sleep(for: .milliseconds(40))
        let zoomed = panel.frame
        #expect(zoomed.height < before.height * 0.9)
        #expect(abs(zoomed.width - zoomed.height / 40) < 1)
        #expect(zoomed.minY > visible.minY)

        manager.close(id)
        manager.restore(id)
        let restored = try pinWindow().frame
        #expect(abs(restored.minX - zoomed.minX) < 1 && abs(restored.minY - zoomed.minY) < 1)
        #expect(abs(restored.height - zoomed.height) < 1)
        manager.resetSize(id)
        let reset = try pinWindow().frame
        #expect(visible.insetBy(dx: 23, dy: 23).contains(reset))
        #expect(abs(reset.width - reset.height / 40) < 1)
        #expect(manager.record(id)?.viewport == nil)
        #expect(manager.visibleImage(id)?.width == image.width && manager.visibleImage(id)?.height == image.height)
        #expect(try Data(contentsOf: asset) == original)
    }
    @Test @MainActor func viewportAndTransformsPersistWithoutDestroyingOriginalPixels() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let manager=CapturePinManager(directory:folder,displaysWindows:false)
        let ctx=try CaptureImage.context(width:100,height:60)
        ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:100,height:60))
        let id=try manager.create(#require(ctx.makeImage()))
        let original=try Data(contentsOf:manager.url(#require(manager.record(id))))
        manager.adjust(id) { $0.quarterTurns=1;$0.grayscale=true }
        #expect(manager.image(id)?.width==60 && manager.image(id)?.height==100)
        manager.setViewport(id,CGRect(x:0.25,y:0.2,width:0.5,height:0.5))
        #expect(manager.visibleImage(id)?.width==30 && manager.visibleImage(id)?.height==50)
        manager.saveNow()
        let restored=CapturePinManager(directory:folder,displaysWindows:false)
        #expect(restored.record(id)?.adjustments?.quarterTurns==1)
        let viewport=try #require(restored.record(id)?.viewport)
        #expect(abs(viewport.minX-0.25)<0.000001 && abs(viewport.minY-0.2)<0.000001 && abs(viewport.width-0.5)<0.000001 && abs(viewport.height-0.5)<0.000001)
        #expect(try Data(contentsOf:manager.url(#require(manager.record(id))))==original)
    }
    @Test @MainActor func animationCopiesAllFramesAndDoesNotDependOnSourceFile() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file=folder.appendingPathComponent("source.gif")
        let destination=try #require(CGImageDestinationCreateWithURL(file as CFURL,UTType.gif.identifier as CFString,2,nil))
        for color in [NSColor.red,NSColor.blue] {
            let ctx=try CaptureImage.context(width:20,height:10);ctx.setFillColor(color.cgColor);ctx.fill(CGRect(x:0,y:0,width:20,height:10))
            CGImageDestinationAddImage(destination,try #require(ctx.makeImage()),[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let manager=CapturePinManager(directory:folder.appendingPathComponent("pins"),displaysWindows:false)
        let id=try manager.createFile(file)
        try FileManager.default.removeItem(at:file)
        let asset=try #require(manager.assetURL(id))
        #expect(manager.record(id)?.payload?.kind == .animation)
        let animation=try #require(CapturePinAnimation(url:asset));#expect(animation.count==2)
        var displayed:CGImage?;animation.changed={ displayed=$0 };animation.step(1)
        #expect(animation.paused && animation.index==1 && displayed != nil)
    }
    @Test func colorAndFormulaAreDistinguishedFromOrdinaryText() {
        #expect(CapturePinMedia.color("#f80") != nil)
        #expect(CapturePinMedia.color("rgb(20, 120, 255)") != nil)
        #expect(CapturePinMedia.color("rgb(999, 1, 1)")==nil)
        #expect(CapturePinMedia.formula("$$\\frac{a}{b}$$")=="\\frac{a}{b}")
        #expect(CapturePinMedia.formula("cost $10 only")==nil)
    }
    @Test func importedHTMLCannotLoadRemoteContentOrExecuteScripts() throws {
        let input="<script src='https://evil.test/a.js'></script><iframe src='https://evil.test'></iframe><img src='https://evil.test/pixel'><link href='https://evil.test/style.css'><span style='color:red;background-image:url(https://evil.test)'>hello</span>"
        let result=String(data:try #require(CapturePinMedia.sanitizedHTML(Data(input.utf8))),encoding:.utf8) ?? ""
        #expect(!result.contains("https://") && !result.contains("<script") && !result.contains("<img") && !result.contains("<iframe"))
        #expect(result.contains("color:red") && result.contains("hello"))
    }
    @Test @MainActor func mouseDefaultsPersistOverridesAndRejectConflicts() throws {
        let name=UUID().uuidString,defaults=try #require(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let settings=CapturePinMouseSettings(defaults:defaults)
        #expect(settings.gesture(.close)=="0:0:double")
        #expect(throws:PluginError.self) { try settings.set("0:0:double",for:.reset) }
        try settings.set("",for:.close);try settings.set("0:0:double",for:.reset)
        #expect(CapturePinMouseSettings(defaults:defaults).gesture(.reset)=="0:0:double")
    }
}
