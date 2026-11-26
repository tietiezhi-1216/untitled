import AppKit
import AVFoundation
import ImageIO
import PDFKit
import SwiftUI
import Testing
@testable import Untitled

@Suite(.serialized)
struct CaptureTests {
    @Test @MainActor func exportedAnnotationsUseImageCoordinatesAndSupportUndo() throws {
        let source = try solid(width: 200, height: 120, color: .white)
        let document = CaptureDocument(image: source)
        document.add(CaptureMark(tool: .cover, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 35)], color: .black, width: 3))
        let image = NSBitmapImageRep(cgImage: document.image)
        #expect(image.colorAt(x: 20, y: 20)!.brightnessComponent < 0.05)
        #expect(image.colorAt(x: 20, y: 90)!.brightnessComponent > 0.95)
        #expect(document.undoCount == 1)
        document.undo()
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 20, y: 20)!.brightnessComponent > 0.95)
        document.redo()
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 20, y: 20)!.brightnessComponent < 0.05)
        document.add(CaptureMark(tool: .arrow, points: [CGPoint(x: 60, y: 60), CGPoint(x: 160, y: 60)], color: .red, width: 4))
        let arrow = NSBitmapImageRep(cgImage: document.image).colorAt(x: 100, y: 60)!
        #expect(arrow.redComponent > 0.9 && arrow.greenComponent < 0.1)
        document.add(CaptureMark(tool: .crop, points: [CGPoint(x: 5, y: 5), CGPoint(x: 105, y: 85)], color: .red, width: 3))
        #expect(document.image.width == 100 && document.image.height == 80)
        document.undo()
        #expect(document.image.width == 200 && document.image.height == 120)
        document.rotate()
        #expect(document.image.width == 120 && document.image.height == 200)
    }

    @Test @MainActor func mosaicChangesExportedPixelsOnlyInsideTheRegion() throws {
        let source = try pattern(width: 180, height: 140)
        let mark = CaptureMark(tool: .mosaic, points: [CGPoint(x: 20, y: 15), CGPoint(x: 100, y: 85)], color: .red, width: 5)
        let result = try CaptureImage.render(source, marks: [mark])
        let a = NSBitmapImageRep(cgImage: source), b = NSBitmapImageRep(cgImage: result)
        #expect(a.colorAt(x: 150, y: 110) == b.colorAt(x: 150, y: 110))
        var changed = 0
        for y in 20..<75 {
            for x in 25..<90 where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { changed += 1 }
        }
        #expect(changed > 2000)
        let file = try temporary().appendingPathComponent("redacted.png")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try CaptureImage.write(result, to: file)
        let loaded = try CaptureImage.load(file)
        #expect(loaded.width == source.width && loaded.height == source.height)
        let savedColor = try #require(NSBitmapImageRep(cgImage: loaded).colorAt(x: 40, y: 40))
        let expectedColor = try #require(b.colorAt(x: 40, y: 40))
        #expect(abs(savedColor.redComponent - expectedColor.redComponent) < 1 / 255.0)
        #expect(abs(savedColor.greenComponent - expectedColor.greenComponent) < 1 / 255.0)
        #expect(abs(savedColor.blueComponent - expectedColor.blueComponent) < 1 / 255.0)
    }

    @Test func verticalAndHorizontalStitchingFindOverlapAndHandleReverseScrolling() throws {
        for axis in StitchAxis.allCases {
            let source = try pattern(width: axis == .vertical ? 180 : 900, height: axis == .vertical ? 900 : 180)
            func crop(_ position: Int) -> CGImage {
                source.cropping(to: axis == .vertical ? CGRect(x: 0, y: position, width: 180, height: 300) : CGRect(x: position, y: 0, width: 300, height: 180))!
            }
            let a = crop(0), b = crop(130), c = crop(260)
            #expect(ImageStitcher.displacement(a, b, axis: axis) == 130)
            #expect(ImageStitcher.displacement(b, a, axis: axis) == -130)
            var stitcher = ImageStitcher(image: a, axis: axis)
            #expect(try stitcher.append(b))
            #expect(try stitcher.append(c))
            #expect(try stitcher.append(b))
            #expect(!(try stitcher.append(b)))
            #expect(axis == .vertical ? stitcher.image.height == 560 : stitcher.image.width == 560)
            let output = NSBitmapImageRep(cgImage: stitcher.image)
            let expected = NSBitmapImageRep(cgImage: source)
            #expect(output.colorAt(x: 80, y: 80) == expected.colorAt(x: 80, y: 80))
            let x = axis == .vertical ? 80 : 400, y = axis == .vertical ? 400 : 80
            #expect(output.colorAt(x: x, y: y) == expected.colorAt(x: x, y: y))
        }
    }

    @Test func reverseCropTrimsOnlyAfterReturningAlongTheCaptureAxis() throws {
        for axis in StitchAxis.allCases {
            let source = try pattern(width: axis == .vertical ? 180 : 900, height: axis == .vertical ? 900 : 180)
            func crop(_ position: Int) -> CGImage {
                source.cropping(to: axis == .vertical ? CGRect(x: 0, y: position, width: 180, height: 300) : CGRect(x: position, y: 0, width: 300, height: 180))!
            }
            for start in [0, 260] {
                let next = start == 0 ? 130 : 130, end = start == 0 ? 260 : 0
                var stitcher = ImageStitcher(image: crop(start), axis: axis)
                #expect(try stitcher.append(crop(next), trimOnReverse: true))
                #expect(try stitcher.append(crop(end), trimOnReverse: true))
                #expect(try stitcher.append(crop(next), trimOnReverse: true))
                #expect(axis == .vertical ? stitcher.image.height == 430 : stitcher.image.width == 430)
                #expect(stitcher.viewport.width == CGFloat(crop(next).width))
            }
        }
    }

    @Test func largeRetinaFramesKeepExactSeams() throws {
        let source = try pattern(width: 720, height: 1400)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 720, height: 600))!
        let second = source.cropping(to: CGRect(x: 0, y: 137, width: 720, height: 600))!
        let shift = try #require(ImageStitcher.displacement(first, second, axis: .vertical))
        #expect(shift == 137)
    }

    @Test func staticAndUnrelatedImagesDoNotProduceFalseLongScreenshots() throws {
        let white = try solid(width: 180, height: 300, color: .white)
        var stitcher = ImageStitcher(image: white, axis: .vertical)
        #expect(!(try stitcher.append(white)))
        let black = try solid(width: 180, height: 300, color: .black)
        #expect(!(try stitcher.append(black)))
        #expect(stitcher.image.height == 300)
    }

    @Test func csvAndOfficeExportsPreserveQuotesUnicodeAndLiteralCells() throws {
        let rows = [["名称", "备注"], ["a,b", "他说\"你好\"\n第二行"], ["=1+1", "<tag>&"]]
        let csv = CaptureDocumentExport.csv(rows)
        #expect(CaptureDocumentExport.parseCSV(csv) == rows)
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xlsx = directory.appendingPathComponent("table.xlsx"), docx = directory.appendingPathComponent("document.docx")
        try CaptureDocumentExport.spreadsheet(rows, to: xlsx)
        try CaptureDocumentExport.document("# 标题\n<tag>& 引号\" 测试\n| 姓名 | 年龄 |\n| --- | --- |\n| 张三 | 20 |", to: docx)
        let sheet = try unzip(xlsx, file: "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("inlineStr"))
        #expect(sheet.contains("=1+1"))
        #expect(!sheet.contains("<f>"))
        let document = try unzip(docx, file: "word/document.xml")
        #expect(document.contains("&lt;tag&gt;&amp;"))
        #expect(document.contains("测试"))
        #expect(document.contains("<w:tbl>"))
        #expect(document.contains("<w:b/>"))
        let pdf = directory.appendingPathComponent("document.pdf")
        try CaptureDocumentExport.textPDF("可搜索文字 Capture 123", to: pdf)
        #expect(PDFDocument(url: pdf)?.string?.contains("Capture 123") == true)
    }

    @Test @MainActor func screenshotPluginInstallsThreeDefaultsAndPersistsHistory() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
        try manifest.validate()
        let store = PluginStore(directory: directory.appendingPathComponent("Plugins"), captureDirectory: directory.appendingPathComponent("Images"))
        try store.installManifest(manifest)
        #expect(store.installed[0].commands.count == 3)
        let original = try #require(store.installed[0].commands.first { $0.action == .captureRegion })
        #expect(original.hotKey?.display == "⌃1")
        #expect(store.installed[0].manifest.hasCaptureCapability)
        var command = original
        command.hotKey = nil
        try store.saveCommand(command, pluginID: manifest.id)
        #expect(store.installed[0].commands[0] == command && store.installed[0].commands.count == 3)
        let record = try store.screenshots.storeImage(solid(width: 100, height: 80, color: .blue))
        let reloaded = ScreenshotController(directory: directory.appendingPathComponent("Images"))
        #expect(reloaded.history.first?.id == record.id)
        #expect(!ScreenshotController.safeFilename("../../bad.png"))
        #expect(!ScreenshotController.safeFilename("not-a-uuid.png"))
        store.setEnabled(false, pluginID: manifest.id)
        #expect(!store.installed.contains { $0.isEnabled && $0.manifest.hasCaptureCapability })
        #expect(!store.screenshots.canUseFeatures())
        #expect(FileManager.default.fileExists(atPath: reloaded.url(record).path))
    }

    @Test @MainActor func localOCRReadsSyntheticText() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: CGSize(width: 900, height: 540))
        image.lockFocus()
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 900, height: 540).fill()
        for (index, line) in ["CAPTURE TEST 123", "Arrow / Mosaic / OCR / Translation",
                              "Name          Quantity          Price", "Apple             2                10", "Orange            3                20"].enumerated() {
            (line as NSString).draw(at: CGPoint(x: 30, y: 460 - index * 70),
                                   withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let file = directory.appendingPathComponent("fixture.png")
        try CaptureImage.write(#require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)), to: file)
        let result = try await CaptureRecognition.recognize(CaptureImage.load(file))
        #expect(result.text.contains("CAPTURE TEST 123"))
        #expect(result.text.contains("Apple"))
        #expect(result.text.contains("Orange"))
    }

    @Test func visionServiceRequiresExplicitHTTPSConfiguration() {
        #expect(CaptureAISettings(endpoint: "http://example.com", model: "vision").url == nil)
        #expect(CaptureAISettings(endpoint: "https://user:pass@example.com", model: "vision").url == nil)
        #expect(CaptureAISettings(endpoint: "https://example.com/v1/chat/completions", model: "").url == nil)
        #expect(CaptureAISettings(endpoint: "https://example.com/v1/chat/completions", model: "vision").url != nil)
    }

    @Test @MainActor func backgroundEraseFillsAPlainBackground() throws {
        let context = try CaptureImage.context(width: 160, height: 120)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 45, y: 40, width: 40, height: 25))
        let source = context.makeImage()!
        let result = try CaptureImage.render(source, marks: [CaptureMark(tool: .erase,
            points: [CGPoint(x: 35, y: 45), CGPoint(x: 95, y: 90)], color: .red, width: 3)])
        #expect(NSBitmapImageRep(cgImage: result).colorAt(x: 60, y: 70)!.brightnessComponent > 0.95)
    }

    @Test func cancellingRecognitionReturnsWithoutWaitingForTheVisionRequest() async throws {
        let image = try solid(width: 200, height: 120, color: .white)
        let request = Task { try await CaptureRecognition.recognize(image) }
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Cancelled recognition unexpectedly completed")
        } catch is CancellationError {
        }
    }

    @Test func localTableGroupingAlignsCentredNumbersUnderWideHeaders() {
        let text = CaptureText(lines: [
            RecognizedLine(text: "Title", rect: CGRect(x: 0.05, y: 0.9, width: 0.8, height: 0.05)),
            RecognizedLine(text: "Name", rect: CGRect(x: 0.05, y: 0.7, width: 0.1, height: 0.05)),
            RecognizedLine(text: "Quantity", rect: CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.05)),
            RecognizedLine(text: "Price", rect: CGRect(x: 0.75, y: 0.7, width: 0.12, height: 0.05)),
            RecognizedLine(text: "Apple", rect: CGRect(x: 0.05, y: 0.5, width: 0.1, height: 0.05)),
            RecognizedLine(text: "2", rect: CGRect(x: 0.48, y: 0.5, width: 0.03, height: 0.05)),
            RecognizedLine(text: "10", rect: CGRect(x: 0.79, y: 0.5, width: 0.05, height: 0.05))
        ], codes: [])
        #expect(text.table == [["Name", "Quantity", "Price"], ["Apple", "2", "10"]])
    }

    @Test func recordingExportsCreateAnimatedGIFAndTrimmedMovie() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let address = CVPixelBufferGetBaseAddress(pixels) {
                let bytes = address.assumingMemoryBound(to: UInt8.self)
                for y in 0..<64 {
                    for x in 0..<64 {
                        let index = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                        bytes[index] = 255; bytes[index + 1] = UInt8(frame * 20); bytes[index + 2] = UInt8(x * 3); bytes[index + 3] = UInt8(y * 3)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let gif = directory.appendingPathComponent("output.gif")
        try await RecordingExporter.gif(from: video, to: gif, start: 0.2, end: 0.8, fps: 5)
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let movie = directory.appendingPathComponent("trimmed.mp4")
        try await RecordingExporter.movie(from: video, to: movie, start: 0.2, end: 0.8)
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        #expect(abs(duration - 0.6) < 0.12)
    }

    @Test func historyGroupsByLocalDayAndKeepsNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let formatter = ISO8601DateFormatter()
        let dates = try ["2025-01-02T15:45:00Z", "2025-01-02T16:10:00Z", "2025-01-02T16:30:00Z"]
            .map { try #require(formatter.date(from: $0)) }
        let older = CaptureRecord(id: UUID(), date: dates[0], filename: "old.png", width: 20, height: 10)
        let first = CaptureRecord(id: UUID(), date: dates[1], filename: "image.png", width: 20, height: 10)
        let latest = CaptureRecord(id: UUID(), date: dates[2], filename: "recording.mp4", width: 0, height: 0)

        let groups = CaptureHistorySection.group([first, older, latest], calendar: calendar)
        #expect(groups.map { $0.records.map(\.id) } == [[latest.id, first.id], [older.id]])
        #expect(groups.first?.day == calendar.startOfDay(for: dates[1]))
        #expect(CaptureHistorySection.group([], calendar: calendar).isEmpty)
    }

    @Test @MainActor func thumbnailDownsamplesWithoutCroppingAndSkipsCancelledWork() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("wide.png")
        try CaptureImage.png(solid(width: 960, height: 320, color: .systemTeal)).write(to: input)

        let loader = CaptureThumbnailLoader()
        let decoded = await loader.image(at: input)
        let thumbnail = try #require(decoded)
        #expect(thumbnail.width == 480)
        #expect(thumbnail.height == 160)
        let missing = await loader.image(at: directory.appendingPathComponent("missing.png"))
        #expect(missing == nil)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await loader.image(at: input)
        }.value
        #expect(cancelled == nil)
    }

    @Test func historyRetentionCountsFromSaveTimeAndGrantsUpgradeGrace() {
        let day = CaptureHistoryRetention.secondsPerDay
        let upgrade = Date(timeIntervalSince1970: 2_000_000)
        let old = retentionRecord(date: upgrade.addingTimeInterval(-10 * day))
        let new = retentionRecord(date: upgrade.addingTimeInterval(day))
        #expect(CaptureHistoryRetention.deadline(for: old, days: 7, rollout: upgrade) == upgrade.addingTimeInterval(7 * day))
        #expect(CaptureHistoryRetention.deadline(for: new, days: 7, rollout: upgrade) == upgrade.addingTimeInterval(8 * day))
        #expect(CaptureHistoryRetention.deadline(for: new, days: 2, rollout: upgrade) == upgrade.addingTimeInterval(3 * day))
        #expect(CaptureHistoryRetention.deadline(for: old, days: 30, rollout: upgrade) == upgrade.addingTimeInterval(20 * day))
        #expect(CaptureHistoryRetention.deadline(for: old, days: 0, rollout: upgrade) == nil)
    }

    @Test @MainActor func retentionMovesOnlyExpiredHistoryAndItsOwnAttachments() throws {
        let work = try temporary()
        defer { try? FileManager.default.removeItem(at: work) }
        let name = "Untitled.CaptureRetention.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let day = CaptureHistoryRetention.secondsPerDay
        let now = Date()
        let rollout = now.addingTimeInterval(-20 * day)
        defaults.set(rollout, forKey: CaptureHistoryRetention.rolloutKey)
        let capture = work.appendingPathComponent("Capture", isDirectory: true)
        let pins = capture.appendingPathComponent("Pins", isDirectory: true)
        let exports = work.appendingPathComponent("Exports", isDirectory: true)
        let trash = work.appendingPathComponent("Trash", isDirectory: true)
        for directory in [pins, exports, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let oldImage = retentionRecord(date: now.addingTimeInterval(-8 * day))
        let oldVideo = retentionRecord(date: now.addingTimeInterval(-7 * day), video: true)
        let recent = retentionRecord(date: now.addingTimeInterval(-6 * day))
        let editable = CaptureEditableArchive.url(for: capture.appendingPathComponent(oldImage.filename)).lastPathComponent
        let stems = ["events.json", "system.m4a", "microphone.m4a", "audio.json"]
            .map { "\(oldVideo.id.uuidString).\($0)" }
        let outsideHistory = [pins.appendingPathComponent(oldImage.filename), exports.appendingPathComponent(oldImage.filename),
                              capture.appendingPathComponent("unindexed.png")]
        for url in outsideHistory { try Data([4]).write(to: url) }
        try writeRetentionFixture([recent, oldVideo, oldImage], directory: capture)
        for sidecar in [editable] + stems { try Data([3]).write(to: capture.appendingPathComponent(sidecar)) }

        let controller = ScreenshotController(directory: capture, historyDefaults: defaults) { url in
            let moved = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
        defer { controller.setHistoryCleanupActive(false) }
        #expect(controller.historyRetentionDays == 7)
        try controller.pruneExpiredHistory(at: now)
        #expect(controller.history.count == 3) // No cleanup before activation.
        controller.setHistoryCleanupActive(true)
        try controller.pruneExpiredHistory(at: now)
        #expect(controller.history.map(\.id) == [recent.id])
        #expect(try JSONDecoder().decode([CaptureRecord].self, from:
            Data(contentsOf: capture.appendingPathComponent("history.json"))).map(\.id) == [recent.id])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)) ==
                Set([oldImage.filename, oldVideo.filename, editable] + stems))
        #expect(outsideHistory.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: capture.appendingPathComponent(recent.filename).path))

        controller.setHistoryRetentionDays(0)
        try controller.pruneExpiredHistory(at: now.addingTimeInterval(100 * day))
        #expect(controller.history.map(\.id) == [recent.id])
        #expect(ScreenshotController(directory: capture, historyDefaults: defaults).historyRetentionDays == 0)
        controller.setHistoryRetentionDays(2)
        #expect(ScreenshotController(directory: capture, historyDefaults: defaults).historyRetentionDays == 2)
        controller.setHistoryCleanupActive(false)
        try controller.pruneExpiredHistory(at: now)
        #expect(controller.history.count == 1)
        controller.setHistoryCleanupActive(true)
        try controller.pruneExpiredHistory(at: now)
        #expect(controller.history.isEmpty)
    }

    @Test @MainActor func retentionKeepsIndexAndRestoresMovedFilesOnFailure() throws {
        let work = try temporary()
        defer { try? FileManager.default.removeItem(at: work) }
        let name = "Untitled.CaptureRetention.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let capture = work.appendingPathComponent("Capture", isDirectory: true)
        let trash = work.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let now = Date()
        let record = retentionRecord(date: now.addingTimeInterval(-12 * CaptureHistoryRetention.secondsPerDay))
        defaults.set(now.addingTimeInterval(-20 * CaptureHistoryRetention.secondsPerDay), forKey: CaptureHistoryRetention.rolloutKey)
        try writeRetentionFixture([record], directory: capture)
        let image = capture.appendingPathComponent(record.filename)
        let archive = CaptureEditableArchive.url(for: image)
        let index = capture.appendingPathComponent("history.json")
        let savedIndex = try Data(contentsOf: index)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: archive)
        var failOnAttachment = true

        let controller = ScreenshotController(directory: capture, historyDefaults: defaults) { url in
            if url == archive, failOnAttachment { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        defer { controller.setHistoryCleanupActive(false) }
        controller.setHistoryCleanupActive(true)
        #expect(throws: Error.self) { try controller.pruneExpiredHistory(at: now) }
        #expect(try Data(contentsOf: index) == savedIndex)
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(try Data(contentsOf: archive) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)

        failOnAttachment = false
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        #expect(throws: Error.self) { try controller.pruneExpiredHistory(at: now) }
        #expect(controller.history.map(\.id) == [record.id])
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(try Data(contentsOf: archive) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    @Test @MainActor func retentionRunsWithoutOpeningSettingsAndSkipsAnOpenEditor() async throws {
        _ = NSApplication.shared
        let capture = try temporary()
        defer { try? FileManager.default.removeItem(at: capture) }
        let name = "Untitled.CaptureRetention.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        let day = CaptureHistoryRetention.secondsPerDay
        defaults.set(now.addingTimeInterval(-20 * day), forKey: CaptureHistoryRetention.rolloutKey)
        let edited = retentionRecord(date: now.addingTimeInterval(-9 * day))
        let unused = retentionRecord(date: now.addingTimeInterval(-10 * day))
        try writeRetentionFixture([edited, unused], directory: capture)
        let editedURL = capture.appendingPathComponent(edited.filename)
        try CaptureImage.png(solid(width: 96, height: 64, color: .systemTeal)).write(to: editedURL)
        let trash = capture.appendingPathComponent("TestTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let controller = ScreenshotController(directory: capture, historyDefaults: defaults) { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        controller.setHistoryCleanupActive(true)
        defer { controller.deactivate() }
        controller.open(edited)
        let editor = try #require(controller.editors.first)
        for _ in 0..<40 where controller.history.count == 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.history.map(\.id) == [edited.id])
        #expect(FileManager.default.fileExists(atPath: editedURL.path))
        editor.close()
        for _ in 0..<40 where !controller.history.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: editedURL.path))
    }

    private func retentionRecord(date: Date, video: Bool = false) -> CaptureRecord {
        let id = UUID()
        return CaptureRecord(id: id, date: date, filename: id.uuidString + (video ? ".mp4" : ".png"),
                             width: 0, height: 0)
    }

    private func writeRetentionFixture(_ records: [CaptureRecord], directory: URL) throws {
        for record in records { try Data([1]).write(to: directory.appendingPathComponent(record.filename)) }
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("history.json"))
    }

    @Test @MainActor func galleryScrollerPaintsRoundCapsOnlyWhenContentOverflows() throws {
        _ = NSApplication.shared
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let rect = CGRect(x: 0, y: 0, width: width, height: 120)
        let scroller = PanelGalleryScroller(frame: rect)
        scroller.scrollerStyle = .legacy
        scroller.knobProportion = 0.3
        scroller.doubleValue = 0.5

        func render() throws -> NSBitmapImageRep {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = graphics
            graphics.cgContext.clear(rect)
            scroller.draw(rect)
            return bitmap
        }

        func alpha(in bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> CGFloat {
            bitmap.colorAt(x: Int(x), y: bitmap.pixelsHigh - 1 - Int(y))?.alphaComponent ?? 0
        }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            scroller.appearance = NSAppearance(named: name)
            scroller.isEnabled = true
            let slot = scroller.rect(for: .knobSlot)
            let knob = scroller.rect(for: .knob)
            try #require(!slot.isEmpty && !knob.isEmpty)
            let image = try render()
            func paintedWidth(at y: CGFloat, threshold: CGFloat) -> Int {
                (0..<image.pixelsWide).count { alpha(in: image, x: CGFloat($0), y: y) > threshold }
            }
            let trackRow = slot.minY + slot.width
            let trackWidth = paintedWidth(at: trackRow, threshold: 0.02)
            let knobWidth = paintedWidth(at: knob.midY, threshold: 0.3)
            // Both pills occupy the same 11-point column, with up to one
            // antialiased pixel difference at fractional boundaries.
            let expectedWidth = min(11, slot.width, knob.width)
            #expect(abs(CGFloat(trackWidth) - expectedWidth) <= 1)
            #expect(abs(CGFloat(knobWidth) - expectedWidth) <= 1)
            #expect(abs(trackWidth - knobWidth) <= 1)
            for y in [slot.minY + 0.5, slot.maxY - 0.5] {
                #expect(paintedWidth(at: y, threshold: 0.02) < trackWidth)
                #expect(alpha(in: image, x: slot.midX, y: y) > 0.02)
            }
            #expect(alpha(in: image, x: knob.midX, y: knob.midY) > 0.5)
            if !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                #expect((0.04...0.055).contains(alpha(in: image, x: slot.midX, y: trackRow)))
            }
            scroller.isEnabled = false
            let empty = try render()
            #expect(alpha(in: empty, x: knob.midX, y: knob.midY) == 0)
        }
    }

    @Test @MainActor func screenshotHomeShowsOnlyHistoryAndSettingsContainThreeShortcutRows() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
        let media = directory.appendingPathComponent("Images")
        // Persist a closed pin before the workspace loads it. No pin window or system input is used.
        let pinFixture = CapturePinManager(directory: media.appendingPathComponent("Pins"), displaysWindows: false)
        let pinID = try pinFixture.create(solid(width: 120, height: 70, color: .systemGreen))
        pinFixture.close(pinID)

        let domain = "CaptureGalleryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = PluginStore(directory: directory.appendingPathComponent("Plugins"),
                                captureDirectory: media,
                                ordinaryHotKeyDriver: .init(register: { _, _ in {} }),
                                captureFactory: { path in
            ScreenshotController(directory: path, globalMouse: CaptureGlobalMouse(preferences: {
                CaptureGlobalMousePreferences(defaults: defaults)
            }), historyDefaults: defaults)
        })
        try store.installManifest(manifest)
        let ui = try #require(manifest.ui)
        #expect(ui.items(in: .content) == [.component("history", "capture.history")])
        let actions = ui.items(in: .headerTrailing)
        let actionIDs = ["captureMenu", "info", "preferencesButton", "more"]
        try #require(actions.map(\.id) == actionIDs)
        let screenshotMenu = actions[0]
        #expect(screenshotMenu.kind == .menu)
        func commands(_ item: PluginUIItem) -> [String] {
            [item.command].compactMap { $0 } + (item.items ?? []).flatMap(commands)
        }
        let screenshotCommands = Set(commands(screenshotMenu))
        #expect(screenshotCommands.isSuperset(of: [
            "capture.region", "capture.window", "capture.screen", "capture.delayed", "capture.copy", "capture.repeatRegion",
            "capture.importImage", "capture.pinFiles", "capture.togglePins", "capture.restorePin",
            "capture.scrollVertical", "capture.scrollHorizontal", "capture.record",
        ]))
        let managePins = try #require(ui.allItems.first { $0.id == "pinMenu.manage" })
        #expect(managePins.panel == "pins" && managePins.presentation == .sheet)
        let gear = try #require(ui.items(in: .headerTrailing).first { $0.id == "preferencesButton" })
        #expect(gear.panel == "preferences" && gear.presentation == .sheet)
        let preferencePages = try #require(ui.panel("preferences")?.slots?["content"]?.first)
        #expect(preferencePages.panels == ["options", "shortcuts"])
        #expect(ui.panel("options")?.component == "capture.options")
        #expect(ui.panel("shortcuts")?.component == "capture.shortcuts")
        #expect(ui.panel("windowShortcuts") == nil)
        #expect(!screenshotCommands.contains("capture.pinClipboard") && !screenshotCommands.contains("capture.cycleGroup"))
        #expect(!ui.allItems.contains { $0.component == "host.addCommand" || $0.component == "capture.localShortcuts" })

        let navigation = PluginUINavigation()
        let context = PluginUIContext(pluginID: manifest.id, store: store, navigation: navigation)
        let capture = store.screenshots
        defer { capture.deactivate() }
        let olderImage = try solid(width: 160, height: 90, color: .systemGray)
        for _ in 0..<12 { try capture.storeImage(olderImage) }
        let square = try capture.storeImage(solid(width: 240, height: 240, color: .systemPink))
        let first = try capture.storeImage(solid(width: 610, height: 125, color: .systemBlue))
        let second = try capture.storeImage(solid(width: 182, height: 814, color: .systemOrange))
        let third = try capture.storeImage(solid(width: 320, height: 220, color: .systemPurple))
        #expect(capture.pinManager.records.first?.id == pinID)

        let layout = PluginUILayoutView(slots: ui.slots, context: context, root: true)
            .environmentObject(store)
        let sizes: [(CGSize, NSAppearance.Name, Int)] = [
            (CGSize(width: 655, height: 580), .aqua, 3),
            (CGSize(width: 944, height: 855), .darkAqua, 4),
        ]
        var metadataHeight: CGFloat?
        for (size, appearance, columnCount) in sizes {
            let records = [third, second, first, square].prefix(columnCount)
            let last = try #require(records.last)
            let frames = try await capturePanelFrames(layout, size: size, appearance: appearance,
                                                      preview: "history-\(columnCount)-columns") { host, frames in
                let card = try #require(frames["capture.history.card.\(last.id.uuidString)"])
                try verifyPersistentHistoryScroller(in: host, lastColumnEdge: card.maxX)
                let labels = headerHoverAnchors(in: host).map(\.title)
                #expect(Set(labels) == Set(["截图操作", "插件详情", "截图设置", "插件更多操作"]))
            }
            let header = try #require(frames["panel.header"])
            let toolbar = try #require(frames["plugin.header.actions"])
            let identity = try #require(frames["plugin.ui.identity"])
            let viewport = try #require(frames["plugin.content.bounds"])
            let title = try #require(frames["capture.history.summary"])
            let gallery = try #require(frames["capture.history.gallery"])
            #expect(header.contains(toolbar) && identity.maxX < toolbar.minX)
            let buttons = try actionIDs.map { try #require(frames["plugin.ui.\($0)"]) }
            for button in buttons {
                #expect(toolbar.contains(button))
                #expect(abs(button.width - PanelLayout.headerActionSize) < 1)
                #expect(abs(button.height - PanelLayout.headerActionSize) < 1)
                #expect(abs(button.midY - toolbar.midY) < 1)
            }
            for (left, right) in zip(buttons, buttons.dropFirst()) {
                #expect(abs(right.minX - left.maxX - PanelLayout.headerActionSpacing) < 1)
            }
            #expect(frames["plugin.toolbar"] == nil && frames["plugin.footer"] == nil)
            #expect(frames["plugin.ui.pages.tabs"] == nil && frames["capture.pins"] == nil)
            #expect(title.minY == viewport.minY && viewport.contains(gallery))
            #expect(abs(title.maxX + PanelLayout.contentInset - viewport.maxX) < 1)
            let cards = try records.map { record in
                let card = try #require(frames["capture.history.card.\(record.id.uuidString)"])
                let metadata = try #require(frames["capture.history.metadata.\(record.id.uuidString)"])
                #expect(gallery.contains(card))
                #expect(abs(card.height - card.width * 0.75) < 1)
                #expect(abs(card.maxY - metadata.maxY) < 1 && abs(card.width - metadata.width) < 1)
                if let metadataHeight { #expect(abs(metadata.height - metadataHeight) < 1) }
                else { metadataHeight = metadata.height }
                return card
            }
            #expect(cards.allSatisfy { abs($0.midY - cards[0].midY) < 1 })
            for (left, right) in zip(cards, cards.dropFirst()) {
                #expect(abs(right.minX - left.maxX - 14) < 1)
            }
        }

        // The simplified gear sheet uses the same manifest routing as the app.
        let settings = PluginPanelSheet(panelID: "preferences", context: context).environmentObject(store)
        navigation.open("options", presentation: .inline, interface: ui)
        let generalFrames = try await capturePanelFrames(settings, size: CGSize(width: 720, height: 600),
                                                         appearance: .darkAqua, preview: "history-retention")
        let generalBounds = try #require(generalFrames["plugin.sheet.content.bounds"])
        #expect(generalBounds.contains(try #require(generalFrames["capture.settings.historyRetention"])))
        #expect(capture.historyRetentionDays == CaptureHistoryRetention.defaultDays)

        navigation.open("shortcuts", presentation: .inline, interface: ui)
        #expect(navigation.inlinePanel == nil && navigation.selectedTabs["preferencesPages"] == "shortcuts")
        let settingsFrames = try await capturePanelFrames(settings, size: CGSize(width: 720, height: 600),
                                                          appearance: .darkAqua, preview: "shortcuts")
        let settingsBounds = try #require(settingsFrames["plugin.sheet.content.bounds"])
        for id in ["region", "pin", "restore-pin"] {
            #expect(settingsBounds.contains(try #require(settingsFrames["capture.settings.shortcut.\(id)"])))
        }
        #expect(settingsFrames.keys.filter { $0.hasPrefix("capture.settings.shortcut.") }.count == 3)
        #expect(settingsFrames["plugin.ui.shortcut.windowBindings"] == nil)

        let pins = PluginPanelSheet(panelID: "pins", context: context).environmentObject(store)
        let pinsFrames = try await capturePanelFrames(pins, size: CGSize(width: 660, height: 560),
                                                      appearance: .darkAqua, preview: "manage-pins")
        #expect(pinsFrames["capture.pins.toolbar"] != nil)
        #expect(capture.pinManager.records.first?.id == pinID)
    }

    @Test @MainActor func headerHintsAppearForMenusAndButtonsWithoutMovingHistory() async throws {
        let work = try temporary()
        defer { try? FileManager.default.removeItem(at: work) }
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
        let domain = "CaptureHeaderHintTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = PluginStore(directory: work.appendingPathComponent("Plugins"),
                                captureDirectory: work.appendingPathComponent("Capture"),
                                ordinaryHotKeyDriver: .init(register: { _, _ in {} }),
                                captureFactory: { path in
            ScreenshotController(directory: path, globalMouse: CaptureGlobalMouse(preferences: {
                CaptureGlobalMousePreferences(defaults: defaults)
            }), historyDefaults: defaults)
        })
        try store.installManifest(manifest)
        store.setEnabled(false, pluginID: manifest.id)

        let bounds = Bounds()
        let measured = PluginWorkspaceView(pluginID: manifest.id)
            .environmentObject(store)
            .background(PanelPalette.content(.dark))
            .coordinateSpace(name: PanelLayout.coordinateSpace)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { value in
                MainActor.assumeIsolated { bounds.frames = value }
            }
        let host = NSHostingView(rootView: measured)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 655, height: 580),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless()
        defer { window.close(); window.contentView = nil }

        func settle() async throws {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func waitForHint() async throws -> CGRect {
            for _ in 0..<20 {
                try await settle()
                if let hint = bounds.frames["plugin.header.hoverHint"] { return hint }
            }
            return try #require(bounds.frames["plugin.header.hoverHint"])
        }
        try await settle()
        let anchors = headerHoverAnchors(in: host)
        let menu = try #require(anchors.first { $0.title == "截图操作" })
        let settings = try #require(anchors.first { $0.title == "截图设置" })
        let more = try #require(anchors.first { $0.title == "插件更多操作" })
        for anchor in [menu, settings, more] {
            let area = try #require(anchor.trackingAreas.first { $0.owner === anchor })
            #expect(area.options.contains([.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow]))
            #expect(anchor.bounds.size == CGSize(width: 32, height: 32))
            #expect(anchor.hitTest(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)) == nil)
        }

        let motion = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
        let before = bounds.frames
        #expect(before["plugin.header.hoverHint"] == nil)
        menu.mouseEntered(with: motion)
        try await settle()
        #expect(bounds.frames["plugin.header.hoverHint"] == nil)
        let menuHint = try await waitForHint()
        let menuButton = try #require(before["plugin.ui.captureMenu"])
        #expect(abs(menuHint.minY - menuButton.maxY - 6) < 1)
        #expect(abs(menuHint.midX - menuButton.midX) < 1)
        #expect(bounds.frames["plugin.content.bounds"] == before["plugin.content.bounds"])
        #expect(bounds.frames["plugin.header.actions"] == before["plugin.header.actions"])

        if let path = ProcessInfo.processInfo.environment["UNTITLED_CAPTURE_HISTORY_PREVIEWS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = URL(fileURLWithPath: path).appendingPathComponent("screenshot-toolbar-hover.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }

        // Entering a different control clears the old name before showing the next.
        settings.mouseEntered(with: motion)
        try await settle()
        #expect(bounds.frames["plugin.header.hoverHint"] == nil)
        let settingsHint = try await waitForHint()
        #expect(settingsHint.midX > menuHint.midX)
        settings.mouseExited(with: motion)
        try await settle()
        #expect(bounds.frames["plugin.header.hoverHint"] == nil)

        more.mouseEntered(with: motion)
        let moreHint = try await waitForHint()
        #expect(moreHint.maxX <= host.bounds.maxX - 7)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await settle()
        #expect(bounds.frames["plugin.header.hoverHint"] == nil)

        // Leaving before the dwell completes must not show a stale tooltip.
        menu.mouseEntered(with: motion)
        menu.mouseExited(with: motion)
        try await Task.sleep(for: .milliseconds(340))
        try await settle()
        #expect(bounds.frames["plugin.header.hoverHint"] == nil)
    }

    @MainActor private func headerHoverAnchors(in view: NSView) -> [PluginHeaderHoverTracking.Anchor] {
        if let anchor = view as? PluginHeaderHoverTracking.Anchor { return [anchor] }
        return view.subviews.flatMap { headerHoverAnchors(in: $0) }
    }

    @MainActor private func capturePanelFrames<Body: View>(_ view: Body, size: CGSize,
                                                           appearance: NSAppearance.Name,
                                                           preview: String,
                                                           verify: ((NSView, [String: CGRect]) throws -> Void)? = nil) async throws -> [String: CGRect] {
        let observation = Bounds()
        let measured = view
            .background(Color(nsColor: .windowBackgroundColor))
            .coordinateSpace(name: PanelLayout.coordinateSpace)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { value in
                MainActor.assumeIsolated { observation.frames = value }
            }
        let host = NSHostingView(rootView: measured)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        if let path = ProcessInfo.processInfo.environment["UNTITLED_CAPTURE_HISTORY_PREVIEWS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = URL(fileURLWithPath: path).appendingPathComponent("\(appearance.rawValue)-\(preview).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        let frames = observation.frames
        try verify?(host, frames)
        return frames
    }

    @MainActor private func verifyPersistentHistoryScroller(in host: NSView, lastColumnEdge: CGFloat) throws {
        func findAnchor(in view: NSView) -> PanelGalleryScrollIndicator.Anchor? {
            if let view = view as? PanelGalleryScrollIndicator.Anchor { return view }
            return view.subviews.lazy.compactMap { findAnchor(in: $0) }.first
        }
        let anchor = try #require(findAnchor(in: host))
        let scroll = try #require(anchor.enclosingScrollView)
        let scroller = try #require(scroll.verticalScroller as? PanelGalleryScroller)
        #expect(scroll.scrollerStyle == .legacy && scroller.scrollerStyle == .legacy && !scroll.autohidesScrollers)
        #expect(abs(scroll.contentSize.width + scroller.bounds.width - scroll.bounds.width) < 1)
        #expect(abs(scroll.contentSize.height - scroll.bounds.height) < 1)
        #expect(scroller.isEnabled && !scroller.isHiddenOrHasHiddenAncestor && scroller.alphaValue == 1)
        #expect(scroller.knobProportion > 0 && scroller.knobProportion < 1)
        #expect(scroller.target === scroll && scroller.action != nil)

        let gallery = scroll.convert(scroll.bounds, to: host)
        let indicator = scroller.convert(scroller.bounds, to: host)
        let knob = scroller.convert(scroller.rect(for: .knob), to: host)
        #expect(abs(host.bounds.maxX - indicator.maxX - 8) < 1)
        #expect(!knob.isEmpty && indicator.contains(knob))
        #expect(indicator.minX - lastColumnEdge >= 7)
        #expect(indicator.minY - gallery.minY >= 5)
        #expect(gallery.maxY - indicator.maxY >= 5)

        let nativeKnob = scroller.rect(for: .knob)
        let knobCenter = scroller.convert(CGPoint(x: nativeKnob.midX, y: nativeKnob.midY), to: nil)
        #expect(scroller.testPart(knobCenter) == .knob)
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let document = try #require(scroll.documentView)
        let top = document.frame.minY
        clip.scroll(to: CGPoint(x: origin.x, y: abs(origin.y - top) < 10 ? top + 120 : top))
        scroll.reflectScrolledClipView(clip)
        #expect(abs(clip.bounds.minY - origin.y) > 1)
        #expect(abs(scroller.rect(for: .knob).midY - nativeKnob.midY) > 1)

        // Local refresh must not replace the scroller or its current position.
        anchor.installScroller()
        #expect(scroll.verticalScroller === scroller && !scroll.autohidesScrollers)
    }

    @MainActor private final class Bounds { var frames: [String: CGRect] = [:] }

    private func solid(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try CaptureImage.context(width: width, height: height)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    private func pattern(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let value = UInt64(x / 5) &* 73_856_093 ^ UInt64(y / 7) &* 19_349_663
                bytes[i] = UInt8(truncatingIfNeeded: value)
                bytes[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[i + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func unzip(_ url: URL, file: String) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, file]; process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(data: data, encoding: .utf8)!
    }
}
