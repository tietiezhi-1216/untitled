import AppKit
import SwiftUI
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

@Suite(.serialized) struct CaptureScrollSegmentTests {
    @Test func segmentsKeepPixelContentAndOrderedOverlapsInBothDirections() throws {
        for axis in StitchAxis.allCases {
            for backwards in [false,true] {
                let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
                let source=pattern(axis:axis),start=backwards ? 650:0
                var capture=SegmentedScrollCapture(image:crop(source,at:start,axis:axis),axis:axis,pixelLimit:180*570,directory:root.appendingPathComponent("recovery"))
                let positions=backwards ? [520,390,260,130,0]:[130,260,390,520,650]
                for position in positions {
                    #expect(try capture.append(crop(source,at:position,axis:axis)))
                    #expect(capture.image.width*capture.image.height<=180*570)
                }
                #expect(capture.segments.count==2)
                let exported=try capture.export(to:root)
                let manifest=try JSONDecoder().decode(CaptureScrollSegmentIndex.self,from:Data(contentsOf:exported.appendingPathComponent("segments.json")))
                #expect(!manifest.containsActiveSegment)
                #expect(manifest.direction==(backwards ? -1:1))
                #expect(manifest.segments.count==3)
                #expect(manifest.segments.first?.origin==(-start))
                #expect(manifest.segments.last.map { $0.origin+(axis == .vertical ? $0.height:$0.width) }==950-start)
                let expected=NSBitmapImageRep(cgImage:source)
                for (index,segment) in manifest.segments.enumerated() {
                    #expect(segment.filename==String(format:"%04d.png",index+1))
                    #expect(segment.gapBeforePixels==0)
                    if index>0 { #expect(segment.overlapBeforePixels>=300) }
                    let decoded=try CaptureImage.load(exported.appendingPathComponent(segment.filename))
                    let output=NSBitmapImageRep(cgImage:decoded),length=axis == .vertical ? decoded.height:decoded.width
                    for along in stride(from:10,to:length-10,by:37) {
                        let x=axis == .vertical ? 80:along,y=axis == .vertical ? along:80
                        let sourceX=axis == .vertical ? x:x+segment.origin+start,sourceY=axis == .vertical ? y+segment.origin+start:y
                        let actualColor=try #require(output.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
                        let expectedColor=try #require(expected.colorAt(x:sourceX,y:sourceY)?.usingColorSpace(.sRGB))
                        #expect(abs(actualColor.redComponent-expectedColor.redComponent)<0.005)
                        #expect(abs(actualColor.greenComponent-expectedColor.greenComponent)<0.005)
                        #expect(abs(actualColor.blueComponent-expectedColor.blueComponent)<0.005)
                    }
                }
                #expect(FileManager.default.fileExists(atPath:exported.appendingPathComponent("阅读顺序.txt").path))
                #expect(FileManager.default.fileExists(atPath:capture.directory.appendingPathComponent("segments.json").path))
            }
        }
    }

    @Test func rollbackStopsAtSealedBoundaryWithoutChangingFilesOrActiveImage() throws {
        for axis in StitchAxis.allCases {
            for backwards in [false,true] {
                let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
                let source=pattern(axis:axis),start=backwards ? 650:0,sign=backwards ? -1:1
                var capture=SegmentedScrollCapture(image:crop(source,at:start,axis:axis),axis:axis,pixelLimit:180*570,directory:root)
                for step in 1...3 { _ = try capture.append(crop(source,at:start+step*130*sign,axis:axis)) }
                let indexData=try Data(contentsOf:root.appendingPathComponent("segments.json"))
                _ = try capture.append(crop(source,at:start+260*sign,axis:axis),trimOnReverse:true)
                let before=try CaptureImage.png(capture.image),origin=capture.origin
                #expect(throws:CaptureScrollSegmentError.self) {
                    _ = try capture.append(crop(source,at:start+130*sign,axis:axis),trimOnReverse:true)
                }
                #expect(capture.origin==origin)
                #expect(try CaptureImage.png(capture.image)==before)
                #expect(try Data(contentsOf:root.appendingPathComponent("segments.json"))==indexData)
                #expect(try capture.append(crop(source,at:start+390*sign,axis:axis)))
            }
        }
    }

    @Test func hugeViewportRollsWithoutAllocatingTwoFullFrames() throws {
        let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let source=pattern(axis:.vertical)
        var capture=SegmentedScrollCapture(image:crop(source,at:0,axis:.vertical),axis:.vertical,pixelLimit:180*300,directory:root)
        #expect(try capture.append(crop(source,at:130,axis:.vertical)))
        #expect(capture.image.height==300)
        let all=SegmentedScrollCapture.ordered(try capture.checkpoint(),axis:.vertical)
        #expect(all.count==2 && all[1].origin==130 && all[1].overlapBeforePixels==170)
    }

    @Test func diskFailureDoesNotAdvanceStateAndCheckpointRemovesOnlySupersededActiveFiles() throws {
        let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let source=pattern(axis:.vertical),blocked=root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to:blocked)
        var capture=SegmentedScrollCapture(image:crop(source,at:0,axis:.vertical),axis:.vertical,pixelLimit:180*430,directory:blocked)
        _ = try capture.append(crop(source,at:130,axis:.vertical))
        let before=try CaptureImage.png(capture.image)
        #expect(throws:(any Error).self) { _ = try capture.append(crop(source,at:260,axis:.vertical)) }
        #expect(capture.segments.isEmpty && capture.origin==0)
        #expect(try CaptureImage.png(capture.image)==before)
        try FileManager.default.removeItem(at:blocked)
        #expect(try capture.append(crop(source,at:260,axis:.vertical)))
        let first=try capture.checkpoint(),second=try capture.checkpoint()
        #expect(first.last?.filename != second.last?.filename)
        #expect(!FileManager.default.fileExists(atPath:blocked.appendingPathComponent(first.last!.filename).path))
        for segment in second { #expect(FileManager.default.fileExists(atPath:blocked.appendingPathComponent(segment.filename).path)) }
    }

    @Test func cropOffsetAndExportGapAreExplicit() throws {
        let root=try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let source=pattern(axis:.vertical)
        var capture=SegmentedScrollCapture(image:crop(source,at:0,axis:.vertical),axis:.vertical,pixelLimit:180*430,directory:root)
        _ = try capture.append(crop(source,at:130,axis:.vertical))
        _ = try capture.append(crop(source,at:260,axis:.vertical))
        let all=SegmentedScrollCapture.ordered(try capture.checkpoint(start:0.9,end:1),axis:.vertical)
        #expect(all[1].origin==517 && all[1].height==43)
        #expect(all[1].gapBeforePixels==87)
        #expect(all[0].height==430)
    }

    @Test func darkChatRejectsLookalikeAndNonoverlappingViewportsWithoutLosingItsReference() throws {
        let source = chatPage()
        let first = chatViewport(source, at: 0)
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        var capture = SegmentedScrollCapture(image: first, axis: .vertical, directory: root)
        // The old mean-luma matcher placed these at +107 and +420 px.
        for offset in [515, 1236] {
            #expect(try capture.appendFrame(chatViewport(source, at: offset)) == .unmatched)
            #expect(capture.image === first && capture.viewport.minY == 0)
        }
        #expect(try capture.appendFrame(first) == .unchanged)
        #expect(try capture.appendFrame(chatViewport(source, at: 157)) == .appended)
        #expect(capture.viewport.minY == 157)
        let expected = try #require(source.cropping(to: CGRect(x: 0, y: 0, width: 622, height: 857)))
        #expect(try pixels(capture.image) == pixels(expected))
    }

    @Test func repeatDistancesAreRejectedInsteadOfChoosingTheFirstLowScore() {
        let page = chatPage(repeating: true)
        let a = chatViewport(page, at: 0)
        let b = chatViewport(page, at: 43)
        #expect(CaptureScrollMatcher.align(a, b, axis: .vertical) == nil)
    }

    @Test func fixedChromeStaysOnlyAtTheEndsOfTheStitchedImage() throws {
        let page = chatPage()
        for backwards in [false, true] {
            let offsets = backwards ? [421, 288, 157, 0] : [0, 157, 288, 421]
            let first = try fixedEdgeChrome(chatViewport(page, at: offsets[0]))
            var stitcher = ImageStitcher(image: first, axis: .vertical)
            for offset in offsets.dropFirst() {
                #expect(try stitcher.append(fixedEdgeChrome(chatViewport(page, at: offset))))
            }
            let body = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 622, height: 1121)))
            let expected = try fixedEdgeChrome(body)
            #expect(stitcher.image.height == 1121)
            #expect(try pixels(stitcher.image) == pixels(expected))
        }
    }

    private func chatPage(repeating: Bool = false) -> CGImage {
        let width = 622, height = repeating ? 1600 : 2611
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let block = repeating ? 0 : (y + 26) / 204
            let line = (y + 26) % 204
            for x in 0..<width {
                let bubble = line < 63 && x > width / 3 + (block % 4) * 11
                let text = bubble ? (19..<31).contains(line) :
                    (line > 84 && (line - 86) % 25 < 13 && x < width * 85 / 100)
                let seed = (x / 5) &* 5371 ^ (line / 25) &* 1889 ^ block &* 1597 ^ (line % 25) &* 73
                let ink = text && x % 7 > 1 && seed % 19 < 9 && line % 25 % 6 > 0
                let value: UInt8 = ink ? 193 : bubble ? 50 : 23
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    private func chatViewport(_ page: CGImage, at offset: Int) -> CGImage {
        page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: 700))!
    }

    private func fixedEdgeChrome(_ image: CGImage) throws -> CGImage {
        let w = image.width, h = image.height
        let context = try CaptureImage.context(width: w, height: h, colorSpace: image.colorSpace)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(gray: 0.24, alpha: 1)
        context.fill(CGRect(x: 0, y: h - 32, width: w, height: 32))
        context.setFillColor(gray: 0.28, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: 42))
        context.setFillColor(gray: 0.85, alpha: 1)
        for x in stride(from: 20, to: w - 20, by: 22) {
            context.fill(CGRect(x: x, y: h - 22, width: 8, height: 4))
            context.fill(CGRect(x: x, y: 18, width: 12, height: 3))
        }
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try CaptureImage.context(width: image.width, height: image.height,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }

    @Test func longCaptureKeepsThePreviousToolbarAndPreviewsOutsideTheSelection() throws {
        let visible = CGRect(x: -1280, y: 400, width: 1280, height: 800)
        let selection = CGRect(x: -920, y: 590, width: 610, height: 465)
        let prior = CGRect(x: -1186, y: 542, width: 876, height: 40)
        let layout = CaptureScrollOverlayLayout(selection: selection, visible: visible, previousToolbar: prior)
        #expect(layout.toolbar.minY == prior.minY && layout.toolbar.maxX == prior.maxX)
        let preview = try #require(layout.preview)
        #expect(visible.contains(preview) && !preview.intersects(selection) && !preview.intersects(layout.toolbar))
        let full = CaptureScrollOverlayLayout(selection: visible, visible: visible, previousToolbar: nil)
        #expect(full.preview == nil && visible.contains(full.toolbar))
    }

    @Test @MainActor func enteringLongCaptureReusesTheBackdropAndLeavesTheLiveAreaTransparent() async throws {
        let frame = CGRect(x: 100, y: 40, width: 850, height: 660)
        let selection = CGRect(x: 305, y: 160, width: 385, height: 465)
        let oldPanel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        oldPanel.isReleasedWhenClosed = false
        oldPanel.contentView = NSView(frame: .init(origin: .zero, size: frame.size))
        let lease = CaptureSelectionPresentation(panels: [oldPanel])
        let handoff = try #require(lease.takePanelForLiveCapture(at: CGPoint(x: selection.midX, y: selection.midY)))
        #expect(handoff.panel === oldPanel && !lease.isActive)
        lease.complete()

        let raster = crop(pattern(axis: .vertical), at: 0, axis: .vertical)
        let session = ScrollCaptureSession(image: raster, axis: .vertical, sampleFrame: {
            Issue.record("Showing the overlay must not capture the desktop.")
            return raster
        }) { _, _, _ in Issue.record("Showing the overlay must not export data.") }
        let previous = CGRect(x: 110, y: 112, width: 580, height: 40)
        let overlay = CaptureScrollOverlay(session: session, selection: selection, screenFrame: frame, visible: frame,
                                           previousToolbar: previous, reusing: handoff.panel, displayChanged: {})
        defer { overlay.close() }
        overlay.show()
        #expect(overlay.backdrop === oldPanel && overlay.backdrop.ignoresMouseEvents && !overlay.backdrop.isOpaque)
        #expect(!overlay.toolbar.ignoresMouseEvents && !overlay.toolbar.styleMask.contains(.titled))
        #expect(overlay.toolbar.frame.maxX == previous.maxX && overlay.toolbar.frame.minY == previous.minY)
        #expect(CaptureWindowPolicy.contentWindowIDs(in: [overlay.toolbar, overlay.backdrop]).isEmpty)

        let shade = try #require(overlay.backdrop.contentView)
        for _ in 0..<3 {
            shade.layoutSubtreeIfNeeded(); overlay.backdrop.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let bitmap = try #require(shade.bitmapImageRepForCachingDisplay(in: shade.bounds))
        shade.cacheDisplay(in: shade.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / shade.bounds.width
        func opacity(at position: CGPoint) -> CGFloat {
            bitmap.colorAt(x: Int(position.x * scale),
                           y: bitmap.pixelsHigh - 1 - Int(position.y * scale))?.alphaComponent ?? 0
        }
        let shadeOpacity = opacity(at: CGPoint(x: 10, y: 10))
        #expect(shadeOpacity > 0.25)
        let preview = try #require(overlay.layout.preview).offsetBy(dx: -frame.minX, dy: -frame.minY)
        // The preview margin has only the desktop shade, while the stitched
        // image is visible. This also catches drawing an opaque preview plate.
        #expect(abs(opacity(at: CGPoint(x: preview.minX + 3, y: preview.maxY - 3)) - shadeOpacity) < 0.015)
        #expect(opacity(at: CGPoint(x: preview.midX, y: preview.midY)) > 0.96)
        let localArea = selection.offsetBy(dx: -frame.minX, dy: -frame.minY)
        #expect(opacity(at: CGPoint(x: localArea.midX, y: localArea.midY)) < 0.01)
        #expect(shade.hitTest(CGPoint(x: localArea.midX, y: localArea.midY)) == nil)
        overlay.close()
        #expect(!overlay.backdrop.isVisible && overlay.backdrop.contentView == nil && overlay.toolbar.contentView == nil)
    }

    @Test @MainActor func pinAndCopyUseStitchedPixelsAndCancelledSaveKeepsTheSession() async throws {
        let source = pattern(axis: .vertical)
        let first = crop(source, at: 0, axis: .vertical)
        let next = crop(source, at: 130, axis: .vertical)
        for requested in [CaptureSelectionPostAction.pin, .copy] {
            var outputs: [(CaptureSelectionPostAction, CGSize)] = []
            var closed = 0
            let session = ScrollCaptureSession(image: first, axis: .vertical, sampleFrame: { next }, chooseURL: { _ in nil }) {
                image, action, _ in outputs.append((action, CGSize(width: image.width, height: image.height)))
            }
            session.finished = { closed += 1 }
            await session.sample()
            #expect(session.count == 2 && session.size.height == 430)
            #expect(session.pixelDimensions == "180 × 430 px" && session.status == nil)
            await session.sample()
            #expect(session.pixelDimensions == "180 × 430 px" && session.status == nil)
            session.submit(.save)
            try await awaitOutput(session)
            #expect(!session.closed && outputs.isEmpty && session.isPaused)
            #expect(session.size.height == 430)
            session.submit(requested)
            session.submit(requested)
            try await awaitOutput(session)
            #expect(session.closed && closed == 1 && outputs.count == 1)
            let exported = try #require(outputs.first)
            #expect(exported.0 == requested && exported.1 == CGSize(width: 180, height: 430))
        }
        let sourceRect = CGRect(x: 350, y: 240, width: 180, height: 300)
        let pin = ScreenshotController.scrollPinFrame(for: source, within: sourceRect,
                                                       visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900))
        #expect(sourceRect.contains(pin) && pin.maxY == sourceRect.maxY && pin.minX == sourceRect.minX)
        #expect(abs(pin.width / pin.height - 0.18) < 0.001)
    }

    @Test func autoScrollEasesInAndReleasesOnlyMatchedDistance() {
        var motion = ScrollCaptureMotion(extent: 600)
        var deltas: [Int] = []
        for _ in 0..<12 {
            let step = motion.nextStep()
            motion.record(step)
            deltas.append(step)
        }
        #expect(deltas.prefix(2).allSatisfy { $0 < 2 })
        #expect(deltas.suffix(4).allSatisfy { (7...8).contains($0) })
        let capturedThrough = motion.sent
        for _ in 0..<140 { motion.record(motion.nextStep()) }
        #expect(motion.sent == motion.limit && motion.nextStep() == 0)
        motion.acceptFrame(capturedThrough: capturedThrough)
        #expect(!motion.isLimited)
        for _ in 0..<140 { motion.record(motion.nextStep()) }
        #expect(motion.sent == motion.limit + capturedThrough)

        var small = ScrollCaptureMotion(extent: 72)
        for _ in 0..<30 { small.record(small.nextStep()) }
        #expect(small.sent > 0 && small.sent <= 27)
        #expect(ScrollCaptureMotion(extent: 1000).speed == 320)
    }

    @Test @MainActor func automaticWheelKeepsMovingDuringCaptureAndStopsOutsideTheRegion() async throws {
        let first = crop(pattern(axis: .vertical), at: 0, axis: .vertical)
        let area = CGRect(x: -800, y: 20, width: 480, height: 540)
        let target = CGPoint(x: -530, y: 250)
        var mouse = target
        var outsideChecks = 0
        var events: [(StitchAxis, Int, CGPoint)] = []
        let frame = ScrollFrameLatch()
        let wheel = ScrollCaptureWheelDriver(selection: area, pointer: {
            if !area.contains(mouse) { outsideChecks += 1 }
            return mouse
        }, authorize: {}, post: { axis, step, point in
            events.append((axis, step, point))
            return true
        })
        let session = ScrollCaptureSession(image: first, axis: .horizontal, sampleFrame: {
            await frame.capture()
        }, wheel: wheel) { _, _, _ in }
        defer { session.suspendPresentation(); frame.release(first) }

        let sampling = Task { await session.sample() }
        try await waitForScroll { frame.waiting }
        session.toggleAutomaticScroll()
        try await waitForScroll { events.count >= 8 }
        #expect(frame.waiting)
        #expect(events.allSatisfy { $0.0 == .horizontal && (1...6).contains($0.1) && $0.2 == target })

        mouse = .zero
        try await waitForScroll { outsideChecks >= 1 }
        let stoppedAt = events.count
        try await waitForScroll { outsideChecks >= 2 }
        #expect(events.count == stoppedAt && session.automaticScroll)
        mouse = target
        try await waitForScroll { events.count >= stoppedAt + 3 }
        #expect(events[stoppedAt].1 <= 2)
        session.togglePause()
        let pausedAt = events.count
        #expect(!session.automaticScroll && session.isPaused)
        frame.release(first)
        await sampling.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.count == pausedAt)
    }

    @Test @MainActor func scrollingStopsAtTheOverlapBudgetUntilFramesMatchAgain() async throws {
        let source = pattern(axis: .vertical)
        let first = crop(source, at: 0, axis: .vertical)
        let selection = CGRect(x: 0, y: 0, width: 180, height: 300)
        let position = ScrollTestPosition()
        var sent = 0
        let wheel = ScrollCaptureWheelDriver(selection: selection, pointer: { CGPoint(x: 50, y: 80) },
                                            authorize: {}, post: { _, step, _ in sent += step; return true })
        let session = ScrollCaptureSession(image: first, axis: .vertical, sampleFrame: {
            crop(source, at: position.offset, axis: .vertical)
        }, wheel: wheel) { _, _, _ in }
        defer { session.suspendPresentation() }
        session.toggleAutomaticScroll()
        let limit = ScrollCaptureMotion(extent: selection.height).limit
        try await waitForScroll { sent >= limit }
        await session.sample()
        #expect(session.automaticScroll && sent == limit)
        await session.sample()
        #expect(!session.automaticScroll && sent == limit && session.count == 1)
        #expect(session.status?.contains("无法拼接") == true)

        position.offset = 130
        await session.sample() // An accepted frame restores the travel budget.
        #expect(session.count == 2 && session.size.height == 430)
        session.toggleAutomaticScroll()
        try await waitForScroll { sent > limit }
        session.suspendPresentation()
        let stoppedAt = sent
        try await Task.sleep(for: .milliseconds(100))
        #expect(!session.automaticScroll && sent == stoppedAt)
    }

    @Test @MainActor func automaticScrollRechecksPermissionAndStopsSendingEventsOnDenial() async throws {
        let first = crop(pattern(axis: .vertical), at: 0, axis: .vertical)
        var allowed = false
        var checks = 0
        var events = 0
        let wheel = ScrollCaptureWheelDriver(
            selection: CGRect(x: 0, y: 0, width: 600, height: 720),
            pointer: { CGPoint(x: 20, y: 20) },
            authorize: { checks += 1; if !allowed { throw PluginError.invalid("test denial") } },
            post: { _, _, _ in events += 1; return true }
        )
        let session = ScrollCaptureSession(image: first, axis: .vertical, sampleFrame: { first }, wheel: wheel) { _, _, _ in }
        defer { session.suspendPresentation() }
        session.toggleAutomaticScroll()
        #expect(checks == 1 && !session.automaticScroll && events == 0)
        allowed = true
        session.toggleAutomaticScroll()
        try await waitForScroll { events >= 2 }
        allowed = false
        try await waitForScroll { !session.automaticScroll }
        let stoppedAt = events
        #expect(checks >= 3 && session.status?.contains("权限") == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(events == stoppedAt)
    }

    @Test @MainActor func finishingAutomaticScrollIncludesTheLastVisibleFrame() async throws {
        let source = pattern(axis: .vertical)
        let first = crop(source, at: 0, axis: .vertical)
        var sent = 0
        var copiedHeight: Int?
        let wheel = ScrollCaptureWheelDriver(selection: CGRect(x: 0, y: 0, width: 180, height: 300),
                                            pointer: { CGPoint(x: 50, y: 80) }, authorize: {},
                                            post: { _, step, _ in sent += step; return true })
        let session = ScrollCaptureSession(image: first, axis: .vertical, sampleFrame: {
            crop(source, at: sent, axis: .vertical)
        }, wheel: wheel) { image, action, _ in
            #expect(action == .copy)
            copiedHeight = image.height
        }
        defer { session.suspendPresentation() }
        session.toggleAutomaticScroll()
        try await waitForScroll { sent >= 30 }
        session.submit(.copy)
        let stoppedAt = sent
        try await awaitOutput(session)
        #expect(session.closed && !session.automaticScroll && sent == stoppedAt)
        #expect(copiedHeight == 300 + stoppedAt)
    }

    @MainActor private func waitForScroll(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The automated scroll did not reach the expected state.")
        throw CancellationError()
    }

    @MainActor private final class ScrollTestPosition { var offset = 0 }

    @MainActor private final class ScrollFrameLatch {
        private var pending: CheckedContinuation<CGImage, Never>?
        var waiting: Bool { pending != nil }
        func capture() async -> CGImage { await withCheckedContinuation { pending = $0 } }
        func release(_ image: CGImage) {
            pending?.resume(returning: image)
            pending = nil
        }
    }

    @Test @MainActor func failedCheckpointKeepsTheCurrentStitchForAnotherOutput() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailable = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: unavailable)
        let raster = crop(pattern(axis: .vertical), at: 0, axis: .vertical)
        let session = ScrollCaptureSession(image: raster, axis: .vertical, recoveryRoot: unavailable,
                                           sampleFrame: { raster }) { _, _, _ in }
        #expect(await session.preserveAndClose() == false)
        #expect(!session.closed && session.isPaused && session.status?.contains("暂存失败") == true)
        session.submit(.copy)
        try await awaitOutput(session)
        #expect(session.closed)
    }

    @Test @MainActor func longCaptureToolbarKeepsPinSaveAndCopyAtTheTrailingEdge() async throws {
        let raster = crop(pattern(axis: .vertical), at: 0, axis: .vertical)
        let session = ScrollCaptureSession(image: raster, axis: .vertical, sampleFrame: { raster }) { _, _, _ in }
        for width in [CGFloat(390), 275] {
            let observation = ScrollToolbarBounds()
            let body = CaptureScrollToolbar(session: session, showPreview: width < 300)
                .background(PanelPalette.content(.dark))
                .coordinateSpace(name: PanelLayout.coordinateSpace)
                .onPreferenceChange(PanelLayoutBoundsKey.self) { value in MainActor.assumeIsolated { observation.frames = value } }
            let host = NSHostingView(rootView: body)
            host.sizingOptions = []
            let panel = NSPanel(contentRect: CGRect(x: 80, y: 80, width: width, height: 40),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host; panel.orderFrontRegardless()
            panel.appearance = NSAppearance(named: .darkAqua)
            defer { CaptureToolbarHelpView.dismiss(in: host); panel.close(); panel.contentView = nil }
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let frame = try #require(observation.frames["capture.scroll.toolbar"])
            let names = ["pin", "save", "copy", "close"]
            let controls = try names.map { try #require(observation.frames["capture.scroll.action.\($0)"]) }
            #expect(abs(controls[3].maxX - (width - 8)) < 1)
            for (index, button) in controls.enumerated() {
                #expect(frame.contains(button) && button.size == CGSize(width: 28, height: 28))
                #expect(abs(controls[3].maxX - button.maxX - CGFloat(3 - index) * 30) < 1)
            }
            if let folder = ProcessInfo.processInfo.environment["UNTITLED_SCROLL_PREVIEWS"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = URL(fileURLWithPath: folder).appendingPathComponent("long-capture-toolbar-\(Int(width)).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    @MainActor private func awaitOutput(_ session: ScrollCaptureSession) async throws {
        for _ in 0..<100 {
            if !session.isSaving || session.closed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Long capture output did not finish.")
        throw CancellationError()
    }

    @MainActor private final class ScrollToolbarBounds { var frames: [String: CGRect] = [:] }

    private func temporary() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("CaptureScrollTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func crop(_ image:CGImage,at position:Int,axis:StitchAxis) -> CGImage {
        image.cropping(to:axis == .vertical ? CGRect(x:0,y:position,width:180,height:300):CGRect(x:position,y:0,width:300,height:180))!
    }
    private func pattern(axis:StitchAxis) -> CGImage {
        let width=axis == .vertical ? 180:1000,height=axis == .vertical ? 1000:180
        var bytes=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let i=(y*width+x)*4,value=UInt64(x/5)&*73_856_093 ^ UInt64(y/7)&*19_349_663
            bytes[i]=UInt8(truncatingIfNeeded:value);bytes[i+1]=UInt8(truncatingIfNeeded:value>>8);bytes[i+2]=UInt8(truncatingIfNeeded:value>>16)
        } }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
}
