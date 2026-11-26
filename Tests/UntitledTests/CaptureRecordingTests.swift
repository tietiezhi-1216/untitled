import AppKit
@preconcurrency import AVFoundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Untitled

@Suite(.serialized) @MainActor
struct CaptureRecordingTests {
    @Test func recordingLayoutPreservesTheSetupAnchorAndClipsOnlyTheOutlineAtDisplayEdges() {
        let screen = CGRect(x: -1440, y: 920, width: 1440, height: 900)
        let visible = CGRect(x: -1440, y: 958, width: 1440, height: 838)
        let selection = CGRect(x: -990.5, y: 1120.5, width: 530, height: 330)
        let toolbar = CGRect(x: selection.maxX - 390, y: selection.minY - 48, width: 390, height: 40)
        let layout = CaptureRecordingLayout(region: selection, screen: screen, visible: visible, previousToolbar: toolbar)
        #expect(layout.region == selection && layout.toolbar == toolbar)
        #expect(abs(layout.reviewToolbar.minX - toolbar.minX) < 1 && abs(layout.reviewToolbar.minY - toolbar.minY) < 1)
        #expect(layout.reviewToolbar.size == toolbar.size)
        #expect(layout.edges.count == 4)
        #expect(layout.edges.allSatisfy { screen.contains($0) && min($0.width, $0.height) <= 3 })
        #expect(layout.edges.allSatisfy { !$0.contains(CGPoint(x: selection.midX, y: selection.midY)) })

        let taller = CGRect(x: -750, y: screen.minY, width: 130, height: screen.height)
        let tall = CaptureRecordingLayout(region: taller, screen: screen, visible: visible, previousToolbar: nil)
        #expect(tall.region == taller && !tall.toolbar.intersects(taller) && visible.contains(tall.toolbar))
        let full = CaptureRecordingLayout(region: screen, screen: screen, visible: visible, previousToolbar: nil)
        #expect(full.region == screen && full.edges.count == 4)
        #expect(full.edges.allSatisfy { screen.contains($0) })
        #expect(full.edges.first?.minY == screen.minY && full.edges.last?.maxX == screen.maxX)
        #expect(visible.contains(full.toolbar) && visible.contains(full.reviewToolbar))
        #expect(full.reviewToolbar.minY == visible.minY + 8)
    }

    @Test func recordingOutlineIsVisibleAndClickThroughButExcludedFromCapture() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let region = CGRect(x: screen.frame.midX - 100, y: screen.frame.midY - 80, width: 200, height: 160)
        let layout = CaptureRecordingLayout(region: region, screen: screen.frame, visible: screen.visibleFrame, previousToolbar: nil)
        let presentation = CaptureRecordingPresentation(layout: layout)
        defer { presentation.close() }
        presentation.showPreparing(seconds: 2)
        let edge = try #require(presentation.outlinePanels.first)
        let view = try #require(edge.contentView)
        #expect(presentation.outlinePanels.allSatisfy { $0.isVisible && $0.ignoresMouseEvents && !$0.canBecomeKey })
        #expect(!presentation.toolbar.ignoresMouseEvents)
        #expect(view.hitTest(CGPoint(x: view.bounds.midX, y: view.bounds.midY)) == nil)
        let controls = presentation.streamControlWindows
        #expect(controls.count == presentation.outlinePanels.count + 2)
        #expect(controls.allSatisfy { $0.identifier?.rawValue.hasPrefix(CaptureWindowPolicy.controlPrefix) == true })
        #expect(CaptureWindowPolicy.contentWindowIDs(in: controls).isEmpty)
        func color() throws -> NSColor {
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            return try #require(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        let live = try color()
        #expect(live.alphaComponent > 0.95 && live.redComponent > live.greenComponent + 0.2)
        presentation.setOutlineColor(.systemOrange)
        let paused = try color()
        #expect(paused.greenComponent > live.greenComponent + 0.15)
        #expect(presentation.outlinePanels.map(\.frame) == layout.edges)
        presentation.close()
        #expect(controls.allSatisfy { !$0.isVisible && $0.contentView == nil })
    }

    @Test @available(macOS 15, *)
    func recordingResolvesAllControlIDsBeforeStartAndReusesThePopoverWindow() async throws {
        let presentation = try makeReviewPresentation()
        defer { presentation.close() }
        #expect(presentation.recordingPopover == nil)
        presentation.showPreparing(seconds: 0)
        let popover = try #require(presentation.recordingPopover)
        let id = try #require(CaptureWindowPolicy.captureID(popover.windowNumber))
        #expect(popover.alphaValue == 0 && popover.ignoresMouseEvents)
        let ids = Set(presentation.streamControlWindows.compactMap { CaptureWindowPolicy.captureID($0.windowNumber) })
        #expect(ids.count == presentation.streamControlWindows.count && ids.contains(id))
        let displayID = try #require(presentation.toolbar.screen?.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID)
        var validated = false
        for _ in 0..<12 {
            // Own-window metadata only. No Screen Recording permission or actual screen capture.
            let content = try await SCShareableContent.currentProcess
            if let display = content.displays.first(where: { $0.displayID == displayID }),
               CaptureService.recordingFilter(display: display, in: content, excluding: ids) != nil {
                #expect(CaptureService.recordingFilter(display: display, in: content, excluding: ids.union([.max])) == nil)
                #expect(CaptureService.recordingFilter(display: display, in: content, excluding: []) == nil)
                validated = true
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(validated)
        for width: CGFloat in [322, 280, 322] {
            presentation.hideRecordingPopover()
            #expect(!popover.isVisible && popover.contentView == nil)
            presentation.showRecordingPopover(Text("录屏工具"), size: CGSize(width: width, height: 148))
            #expect(popover.isVisible && popover.alphaValue == 1 && !popover.ignoresMouseEvents)
            #expect(CGWindowID(popover.windowNumber) == id && popover.frame.width == width)
        }
        presentation.showSaving()
        #expect(!popover.isVisible && popover.contentView == nil)
        presentation.close()
        #expect(presentation.recordingPopover == nil)
    }

    @Test func finalizationShowsPausedVideoInOriginalRegionAndKeepsTheToolbarPut() async throws {
        let folder = try temporaryFolder("recording-in-place")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let url = folder.appendingPathComponent(id.uuidString + ".mp4")
        try await makeVideo(at: url)
        let original = try Data(contentsOf: url)
        let controller = ScreenshotController(directory: folder)
        defer { controller.deactivate() }
        let screen = try #require(NSScreen.main)
        let rect = CGRect(x: screen.frame.midX - 127.5, y: screen.frame.maxY - 192.5, width: 256, height: 192)
        let layout = CaptureRecordingLayout(region: rect, screen: screen.frame, visible: screen.visibleFrame, previousToolbar: nil)
        let presentation = CaptureRecordingPresentation(layout: layout)
        presentation.showPreparing(seconds: 0)
        let toolbar = presentation.toolbar
        let originalFrame = toolbar.frame
        let alreadyVisible = Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        presentation.showSaving()
        #expect(presentation.playback == nil && toolbar.frame == originalFrame)

        try controller.completeRecording(url, warning: nil, in: presentation)
        let panel = try #require(presentation.playbackPanel)
        let playback = try #require(presentation.playback)
        let canvas = try #require(panel.contentView?.subviews.first as? CaptureRecordingReviewCanvas)
        let layer = try #require(canvas.video.layer as? AVPlayerLayer)
        #expect(panel.isVisible && panel.frame == rect.integral && layer.videoGravity == .resizeAspect)
        #expect(panel.convertToScreen(canvas.convert(canvas.bounds, to: nil)) == rect)
        #expect(presentation.toolbar === toolbar && toolbar.frame == layout.reviewToolbar)
        #expect(NSApplication.shared.windows.filter {
            $0.isVisible && !alreadyVisible.contains(ObjectIdentifier($0))
        } == [panel])
        #expect(CaptureWindowPolicy.contentWindowIDs(in: [panel, toolbar]).isEmpty)
        let record = try #require(controller.history.first)
        #expect(record.id == id && record.isVideo)
        let saved = try JSONDecoder().decode([CaptureRecord].self, from: Data(contentsOf: folder.appendingPathComponent("history.json")))
        #expect(saved.map(\.id) == [id])
        controller.remove(record)
        #expect(FileManager.default.fileExists(atPath: url.path) && controller.history.count == 1)

        for _ in 0..<120 {
            if playback.duration > 0 && layer.isReadyForDisplay { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.duration > 1.8 && layer.isReadyForDisplay)
        #expect(playback.dimensions == "128 × 96 px")
        canvas.layoutSubtreeIfNeeded()
        #expect(canvas.video.frame.width * panel.backingScaleFactor == 128)
        #expect(canvas.video.frame.height * panel.backingScaleFactor == 96)
        #expect(playback.player.rate == 0 && !playback.isPlaying)
        playback.toggle()
        #expect(playback.isPlaying)
        playback.pause()
        playback.seek(0.8)
        #expect(abs(playback.position - 0.8) < 0.001)
        presentation.close()
        #expect(controller.recordingPresentation == nil)
        #expect(!panel.isVisible && !toolbar.isVisible && playback.player.currentItem == nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func videoIsPixelAlignedAtNativeScaleAndNeverUpscalesARecordedFile() {
        let source = CGSize(width: 534, height: 418)
        let original = CGRect(x: 0, y: 0, width: 534, height: 419)
        #expect(CaptureRecordingVideoGeometry.frame(pixels: source, within: original, backingScale: 1) ==
                CGRect(x: 0, y: 0, width: 534, height: 418))
        let retina = CGRect(x: 0.5, y: 0.5, width: 534, height: 419)
        let doubled = CGSize(width: 1068, height: 838)
        #expect(CaptureRecordingVideoGeometry.frame(pixels: doubled, within: retina, backingScale: 2) ==
                retina)
        let preview = CaptureRecordingVideoGeometry.frame(pixels: source, within: retina, backingScale: 2)
        #expect(retina.contains(preview) && preview.size == CGSize(width: 267, height: 209))
        #expect((preview.minX * 2).rounded() == preview.minX * 2 && (preview.minY * 2).rounded() == preview.minY * 2)
        let cap = RecordingOptions(maximumEdge: 1280).pixelSize(for: CGSize(width: 1024, height: 512), scale: 2)
        #expect(cap == CGSize(width: 1280, height: 640))
        #expect(RecordingOptions().pixelSize(for: original.size, scale: 1) == source)
    }

    @Test(arguments: [true, false])
    func commandAndControlCopyCloseAfterWritingTheOriginalMP4(useCommand: Bool) async throws {
        let folder = try temporaryFolder("recording-copy-shortcut")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("original.mp4")
        try await makeVideo(at: url)
        let board = NSPasteboard(name: .init("recording-copy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let presentation = try makeReviewPresentation()
        defer { presentation.close() }
        presentation.showReview(url: url) { board }
        let playback = try #require(presentation.playback)
        let canvas = try #require(presentation.playbackPanel)
        try await waitUntil { playback.canEdit }
        let original = try Data(contentsOf: url)
        let window = useCommand ? presentation.toolbar : canvas
        let modifiers: NSEvent.ModifierFlags = useCommand ? .command : .control
        let count = board.changeCount
        #expect(window.performKeyEquivalent(with: try copyKey(in: window, modifiers: modifiers, repeated: true)))
        _ = window.performKeyEquivalent(with: try copyKey(in: window, modifiers: [modifiers, .shift]))
        #expect(board.changeCount == count && !presentation.isClosed)

        let key = try copyKey(in: window, modifiers: modifiers)
        if useCommand { #expect(window.performKeyEquivalent(with: key)) }
        else { window.keyDown(with: key) }

        #expect(presentation.isClosed && !canvas.isVisible && !presentation.toolbar.isVisible)
        #expect(presentation.outlinePanels.allSatisfy { !$0.isVisible })
        #expect(playback.player.currentItem == nil)
        let fileURL = try #require(board.string(forType: .fileURL))
        let file = try #require(URL(string: fileURL))
        #expect(file == url)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func missingOriginalDoesNotCloseThePreviewOrClearTheClipboard() async throws {
        let folder = try temporaryFolder("recording-copy-missing-original")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("original.mp4")
        try await makeVideo(at: url)
        let board = NSPasteboard(name: .init("recording-copy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("existing clipboard", forType: .string)
        let presentation = try makeReviewPresentation()
        defer { presentation.close() }
        presentation.showReview(url: url) { board }
        let playback = try #require(presentation.playback)
        try await waitUntil { playback.canEdit }
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("moved.mp4"))
        let key = try copyKey(in: presentation.toolbar, modifiers: .command)
        #expect(presentation.toolbar.performKeyEquivalent(with: key))
        #expect(playback.feedback == "复制失败，请重试。")
        #expect(board.string(forType: .string) == "existing clipboard")
        #expect(!presentation.isClosed && presentation.playbackPanel?.isVisible == true)
    }

    @Test func editedCopyClosesOnlyAfterPublishingTheEditedMP4() async throws {
        let folder = try temporaryFolder("recording-copy-edits")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("original.mp4")
        try await makeVideo(at: url)
        let original = try Data(contentsOf: url)
        let board = NSPasteboard(name: .init("recording-copy-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let presentation = try makeReviewPresentation()
        defer { presentation.close() }
        presentation.showReview(url: url, clipboardCache: folder.appendingPathComponent("copies")) { board }
        let playback = try #require(presentation.playback)
        try await waitUntil { playback.canEdit }
        playback.setStart(0.4); playback.setEnd(1.6)
        playback.edit.options.speed = 2
        playback.toggleCrop()
        #expect(playback.cropping)
        playback.edit.options.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        playback.toggleCrop()
        try await waitUntil { playback.work == nil }
        #expect(!playback.cropping && !playback.isPlaying)
        #expect(playback.timeline == 0.4...1.6 && playback.videoPixels == CGSize(width: 64, height: 96))
        #expect(playback.player.currentItem?.videoComposition?.renderSize == playback.videoPixels)

        let key = try copyKey(in: presentation.toolbar, modifiers: .command)
        #expect(presentation.toolbar.performKeyEquivalent(with: key))
        #expect(playback.work == .copying && !presentation.isClosed)
        board.clearContents(); board.setString("new selection", forType: .string)
        try await waitUntil { playback.work == nil }
        #expect(board.string(forType: .string) == "new selection")
        #expect(playback.feedback == "剪贴板已变化，未覆盖较新的内容。")
        #expect(!presentation.isClosed && presentation.toolbar.isVisible)

        #expect(presentation.toolbar.performKeyEquivalent(with: key))
        #expect(playback.work == .copying && !presentation.isClosed)
        try await waitUntil { playback.work == nil }
        #expect(presentation.isClosed && !presentation.toolbar.isVisible)
        let editedURL = try #require(board.string(forType: .fileURL))
        let edited = try #require(URL(string: editedURL))
        #expect(edited != url)
        let media = try await CaptureRecordingPlayback.Media.read(AVURLAsset(url: edited))
        #expect(abs(media.duration - 0.6) < 0.11 && media.size == CGSize(width: 64, height: 96))
        #expect(try Data(contentsOf: url) == original)
    }

    private func makeReviewPresentation() throws -> CaptureRecordingPresentation {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let rect = CGRect(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.midY - 120, width: 320, height: 240)
        return CaptureRecordingPresentation(layout: .init(region: rect, screen: screen.frame,
                                                          visible: screen.visibleFrame, previousToolbar: nil))
    }

    private func copyKey(in window: NSWindow, modifiers: NSEvent.ModifierFlags, repeated: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "c",
                                    charactersIgnoringModifiers: "c", isARepeat: repeated, keyCode: 8))
    }

    @Test func exportRequestsOneSaveDialogAndAnUneditedMP4KeepsEveryByte() async throws {
        let folder = try temporaryFolder("recording-export-inline")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("original.mp4")
        try await makeVideo(at: url)
        let original = try Data(contentsOf: url)
        let screen = try #require(NSScreen.main)
        let region = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 110, width: 400, height: 220)
        let presentation = CaptureRecordingPresentation(layout: .init(region: region, screen: screen.frame,
                                                          visible: screen.visibleFrame, previousToolbar: nil))
        defer { presentation.close() }
        presentation.showReview(url: url)
        let playback = try #require(presentation.playback)
        try await waitUntil { playback.canEdit }
        let windows = Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        var shown = 0
        var cancel: (@MainActor () -> Void)?
        playback.chooseExportDestination(above: presentation.toolbar) { save, finish in
            shown += 1
            #expect(save.allowedContentTypes == [.mpeg4Movie])
            #expect(save.level.rawValue > presentation.toolbar.level.rawValue)
            cancel = { finish(.cancel) }
        }
        #expect(shown == 1 && playback.work == .choosingDestination)
        #expect(Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init)) == windows)
        cancel?(); cancel = nil
        try await waitUntil { playback.work == nil }
        #expect(presentation.playbackPanel?.isVisible == true && presentation.toolbar.isVisible)
        let target = folder.appendingPathComponent("exported.mp4")
        try Data("previous file".utf8).write(to: target)
        playback.export(to: target, format: .mp4)
        try await waitUntil { playback.work == nil }
        #expect(try Data(contentsOf: target) == original)
        playback.export(to: url, format: .mp4)
        #expect(playback.work == nil && playback.feedback?.contains("不会被覆盖") == true)
        #expect(try Data(contentsOf: url) == original)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "未达到预期的录屏编辑状态")
    }

    @Test func cancellingTheCountdownClosesEveryControlAndNeverStartsCapture() async throws {
        let screen = try #require(NSScreen.main)
        let region = CGRect(x: screen.frame.midX - 60, y: screen.frame.midY - 40, width: 120, height: 80)
        let layout = CaptureRecordingLayout(region: region, screen: screen.frame, visible: screen.visibleFrame, previousToolbar: nil)
        let presentation = CaptureRecordingPresentation(layout: layout)
        defer { presentation.close() }
        presentation.showPreparing(seconds: 10)
        let waiting = Task { await presentation.waitForStart { true } }
        await Task.yield()
        presentation.toolbar.cancelOperation(nil)
        #expect(await waiting.value == false)
        #expect(presentation.isClosed && !presentation.toolbar.isVisible && presentation.playback == nil)
        #expect(presentation.outlinePanels.allSatisfy { !$0.isVisible })
    }

    @Test func finalizingForQuitKeepsTheMovieWithoutCreatingAnyReview() async throws {
        let folder = try temporaryFolder("recording-quit")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(UUID().uuidString + ".mp4")
        try await makeVideo(at: url)
        let controller = ScreenshotController(directory: folder)
        let windowCount = NSApplication.shared.windows.filter(\.isVisible).count
        try controller.completeRecording(url, warning: nil, in: nil)
        #expect(controller.history.count == 1 && controller.recordingPresentation == nil)
        #expect(NSApplication.shared.windows.filter(\.isVisible).count == windowCount)
    }

    @Test func recordingExportRejectsInvalidCropAndSpeed() throws {
        var options = RecordingEditOptions()
        options.speed = 0
        #expect(throws: (any Error).self) { try options.validated() }
        options.speed = 1; options.crop = CGRect(x: 0.9, y: 0, width: 0.5, height: 1)
        #expect(throws: (any Error).self) { try options.validated() }
    }

    @Test func realVideoTrimCropSpeedGIFAndSegmentJoin() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await makeVideo(at: source)
        let originalDuration = try await AVURLAsset(url: source).load(.duration).seconds
        #expect(originalDuration > 1.8)
        let joined = folder.appendingPathComponent("joined.mp4")
        try await RecordingExporter.join([source, source], to: joined)
        let joinedDuration = try await AVURLAsset(url: joined).load(.duration).seconds
        #expect(abs(joinedDuration - 2 * originalDuration) < 0.05)
        var options = RecordingEditOptions()
        options.speed = 2; options.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1); options.fps = 5
        let movie = folder.appendingPathComponent("crop.mp4")
        try await RecordingExporter.movie(from: source, to: movie, start: 0, end: originalDuration, options: options)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(duration - originalDuration / 2) < 0.15)
        #expect(size.width == 64 && size.height == 96)
        let gif = folder.appendingPathComponent("crop.gif")
        try await RecordingExporter.animation(from: source, to: gif, start: 0, end: originalDuration, options: options, webP: false)
        let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == Int(ceil(originalDuration / 2 * 5)))
        let frame = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(frame.width == 64 && frame.height == 96)
        // The selected right half of the source must remain blue after the AV transform.
        let sample = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(sample.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[2] > 200 && bytes[0] < 50)
        if RecordingExporter.webPEncoder != nil {
            let webp = folder.appendingPathComponent("crop.webp")
            try await RecordingExporter.animation(from: source, to: webp, start: 0, end: originalDuration, options: options, webP: true)
            let data = try Data(contentsOf: webp)
            #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
            #expect(String(decoding: data[8..<12], as: UTF8.self) == "WEBP")
        }
    }
    @Test func editableEventEffectsAndCroppedGeometryUseRealVideoFrames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-effects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await makeVideo(at: source, quadrants: true)
        let archive = RecordingEventArchive(events: [
            .init(time: 0.05, kind: .pointer, x: 0.7, y: 0.3, label: ""),
            .init(time: 0.1, kind: .key, x: 0, y: 0, label: "⌘C"),
            .init(time: 0.15, kind: .leftClick, x: 0.7, y: 0.3, label: "")])
        try archive.save(for: source)
        #expect(RecordingEventArchive.read(for: source)?.events == archive.events)
        var options = RecordingEditOptions()
        let enabled = try await frame(source, options: options)
        options.effects.cursor = false; options.effects.clicks = false; options.effects.keys = false
        let disabled = try await frame(source, options: options)
        #expect(try CaptureImage.png(enabled) != CaptureImage.png(disabled))
        options.crop = CGRect(x: 0, y: 0.75, width: 1, height: 0.25)
        let cropped = try await frame(source, options: options)
        #expect(cropped.width == 128 && cropped.height == 24)
        let color = try #require(NSBitmapImageRep(cgImage: cropped).colorAt(x: 20, y: 12)?.usingColorSpace(.sRGB))
        let raw = try await AVAssetImageGenerator(asset: AVURLAsset(url: source)).image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let reference = try #require(NSBitmapImageRep(cgImage: raw).colorAt(x: 20, y: 90)?.usingColorSpace(.sRGB))
        #expect(abs(color.greenComponent - reference.greenComponent) < 0.03)
        #expect(abs(color.redComponent - reference.redComponent) < 0.03)
        #expect(color.greenComponent > 0.8 && color.blueComponent < 0.2)
        // Exercise the same effects composition through actual MP4 export, not only AVAssetImageGenerator.
        options.crop = CGRect(x: 0, y: 0, width: 1, height: 1); options.effects.keys = true
        let exported = folder.appendingPathComponent("effects.mp4")
        try await RecordingExporter.movie(from: source, to: exported, start: 0, end: 1, options: options)
        #expect(try await AVURLAsset(url: exported).load(.duration).seconds > 0.9)
    }
    @Test func recoveryAndIndependentAudioStems() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        var manifest = RecordingRecoveryManifest(targetFilename: "recovered.mp4", expectedAudioNames: ["system", "microphone"]); manifest.ownerPID = 0
        try manifest.save(in: session)
        let source = session.appendingPathComponent("0.mp4")
        try await makeVideo(at: source)
        try makeAudio(at: RecordingAudioStems.url(for: source, name: "system"), frequency: 440)
        try makeAudio(at: RecordingAudioStems.url(for: source, name: "microphone"), frequency: 880)
        let candidates = CaptureRecordingRecovery.list(in: folder)
        #expect(candidates.count == 1)
        let recovered = try await CaptureRecordingRecovery.recover(#require(candidates.first))
        #expect(CaptureRecordingRecovery.list(in: folder).isEmpty)
        #expect(Set(RecordingAudioStems.names(for: recovered)) == ["system", "microphone"])
        var options = RecordingEditOptions(); options.systemVolume = 0; options.microphoneVolume = 0.5
        let prepared = try await RecordingExporter.prepare(from: recovered, start: 0, end: 1.9, options: options)
        #expect(prepared.audio.inputParameters.count == 2)
        var volumes: [Float] = []
        for parameters in prepared.audio.inputParameters {
            var start: Float = -1, end: Float = -1, range = CMTimeRange.zero
            #expect(parameters.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
            volumes.append(start)
        }
        #expect(volumes.sorted() == [0, 0.5])
    }
    @Test func incompleteStemsFallBackToMixedAudioForTheWholeRecording() async throws {
        let folder = try temporaryFolder("recording-stem-fallback")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let first = session.appendingPathComponent("0.mp4"), second = session.appendingPathComponent("1.mp4")
        try await makeMixedVideo(at: first)
        try FileManager.default.copyItem(at: first, to: second)
        // The first segment lost both optional stems, but its MP4 still has sound.
        for name in RecordingAudioStems.supportedNames { try makeAudio(at: RecordingAudioStems.url(for: second, name: name), frequency: 440) }
        let destination = folder.appendingPathComponent("saved.mp4")
        let result = try await RecordingFinalization.finish(in: session, to: destination, expectedAudioNames: ["system", "microphone"]) {}
        #expect(result.retainedSource && result.warning != nil)
        #expect(RecordingAudioStems.names(for: destination).isEmpty)
        let prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 4, options: .init())
        let tracks = try await prepared.asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let audio = try #require(tracks.first)
        #expect(try await audio.load(.timeRange).duration.seconds > 3.9)
        #expect(prepared.audio.inputParameters.count == 1)
    }
    @Test func deletingOrCorruptingOnePublishedStemRestoresBothMixedSources() async throws {
        let folder = try temporaryFolder("recording-stem-invalidated")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4"), destination = folder.appendingPathComponent("saved.mp4")
        try await makeMixedVideo(at: source)
        try FileManager.default.copyItem(at: source, to: destination)
        for name in RecordingAudioStems.supportedNames { try makeAudio(at: RecordingAudioStems.url(for: source, name: name), frequency: 440) }
        try await RecordingAudioStems.join(segments: [source], to: destination, expectedNames: ["system", "microphone"])
        #expect(await RecordingAudioStems.validatedNames(for: destination).count == 2)
        let mic = RecordingAudioStems.url(for: destination, name: "microphone")
        try FileManager.default.removeItem(at: mic)
        #expect(RecordingAudioStems.names(for: destination).isEmpty)
        var prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 1.9, options: .init())
        #expect(prepared.audio.inputParameters.count == 1)
        try Data("incomplete AAC file".utf8).write(to: mic)
        #expect(await RecordingAudioStems.validatedNames(for: destination).isEmpty)
        prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 1.9, options: .init())
        #expect(prepared.audio.inputParameters.count == 1)
    }
    @Test func optionalSidecarWriteFailuresKeepTheMovieAndSourceArchive() async throws {
        let folder = try temporaryFolder("recording-sidecar-failure")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let source = session.appendingPathComponent("0.mp4"), destination = folder.appendingPathComponent("saved.mp4")
        try await makeMixedVideo(at: source)
        for name in RecordingAudioStems.supportedNames { try makeAudio(at: RecordingAudioStems.url(for: source, name: name), frequency: 440) }
        // Real filesystem failures, not an assertion-only mock: a directory blocks each sidecar destination.
        let blockedStem = RecordingAudioStems.url(for: destination, name: "microphone")
        let blockedEvents = RecordingEventArchive.url(for: destination)
        try FileManager.default.createDirectory(at: blockedStem, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blockedEvents, withIntermediateDirectories: true)
        let result = try await RecordingFinalization.finish(in: session, to: destination, expectedAudioNames: ["system", "microphone"]) {
            try RecordingEventArchive().save(for: destination)
        }
        #expect(result.retainedSource && result.warning != nil)
        #expect(try await AVURLAsset(url: result.url).load(.duration).seconds > 1.9)
        #expect(FileManager.default.fileExists(atPath: source.path))
        // System stem may have published before microphone failed, but rollback must remove it and its marker.
        #expect(!FileManager.default.fileExists(atPath: RecordingAudioStems.url(for: destination, name: "system").path))
        #expect(!FileManager.default.fileExists(atPath: RecordingAudioStems.manifestURL(for: destination).path))
        let prepared = try await RecordingExporter.prepare(from: destination, start: 0, end: 1.9, options: .init())
        #expect(prepared.audio.inputParameters.count == 1)
    }
    @Test func unfinishedPendingSegmentIsPreservedAndReadableUnindexedSegmentIsRecovered() async throws {
        let folder = try temporaryFolder("recording-pending-segment")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = folder.appendingPathComponent(".recording-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        var manifest = RecordingRecoveryManifest(targetFilename: "recovered.mp4", expectedAudioNames: []); manifest.ownerPID = 0
        try manifest.save(in: session)
        let source = session.appendingPathComponent("0.mp4")
        try await makeVideo(at: source)
        // Segment 1 is playable even though the native completion callback never indexed it.
        try FileManager.default.copyItem(at: source, to: session.appendingPathComponent("1.mp4"))
        let pending = session.appendingPathComponent("2.mp4")
        try Data("unfinished native movie".utf8).write(to: pending)
        #expect(RecordingFinalization.nextSegmentURL(in: session).lastPathComponent == "3.mp4")
        let candidate = try #require(CaptureRecordingRecovery.list(in: folder).first)
        let result = try await CaptureRecordingRecovery.recoverWithResult(candidate)
        #expect(try await AVURLAsset(url: result.url).load(.duration).seconds > 3.9)
        #expect(result.retainedSource && result.warning != nil)
        #expect(try Data(contentsOf: pending) == Data("unfinished native movie".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
    private func temporaryFolder(_ prefix: String) throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func makeMixedVideo(at destination: URL) async throws {
        let video = destination.deletingPathExtension().appendingPathExtension("source.mp4")
        let audio = destination.deletingPathExtension().appendingPathExtension("source.m4a")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: audio) }
        try await makeVideo(at: video); try makeAudio(at: audio, frequency: 660)
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        defer { withExtendedLifetime([videoAsset, audioAsset]) {} }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)).insertTimeRange(range, of: videoTrack, at: .zero)
        try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)).insertTimeRange(range, of: audioTrack, at: .zero)
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        if #available(macOS 15, *) { try await exporter.export(to: destination, as: .mp4) }
        else { exporter.outputURL = destination; exporter.outputFileType = .mp4; await exporter.export(); #expect(exporter.status == .completed) }
    }
    private func frame(_ source: URL, options: RecordingEditOptions) async throws -> CGImage {
        let prepared = try await RecordingExporter.prepare(from: source, start: 0, end: 1, options: options)
        let generator = AVAssetImageGenerator(asset: prepared.asset); generator.videoComposition = prepared.video
        generator.requestedTimeToleranceAfter = .zero; generator.requestedTimeToleranceBefore = .zero
        return try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
    }
    private func makeAudio(at url: URL, frequency: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        let channel = try #require(buffer.floatChannelData)[0]
        for i in 0..<96000 { channel[i] = Float(sin(Double(i) / 48000 * frequency * 2 * .pi) * 0.2) }
        try file.write(from: buffer)
    }
    private func makeVideo(at url: URL, quadrants: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PluginError.invalid("测试视频编码失败。") }
        writer.startSession(atSourceTime: .zero)
        let sourceColorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        for index in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sourceColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
            context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 64, y: 0, width: 64, height: 96))
            if quadrants { context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x: 0, y: 0, width: 128, height: 24)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished(); await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
