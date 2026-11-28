import AppKit
@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CaptureRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let filename: String
    var width: Int
    var height: Int
    var revision: UUID?
    var isVideo: Bool { filename.hasSuffix(".mp4") }
}

@MainActor enum CaptureClipboard {
    /// The complete PNG is available on this Mac immediately. Never offer
    /// the copy as a Continuity promise or make a local paste fetch it back.
    static func writePNG(_ data: Data, to pasteboard: NSPasteboard = .general) -> Int? {
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { return nil }
        let claim = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.changeCount == claim, pasteboard.writeObjects([item]) else { return nil }
        return pasteboard.changeCount
    }
}

@MainActor final class CaptureDocument: ObservableObject {
    @Published private(set) var image: CGImage
    @Published private(set) var marks: [CaptureMark] = []
    @Published private(set) var canvasOffset = CGPoint.zero
    @Published var selectedMarkID: UUID?
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    var reportError: ((String) -> Void)?
    @Published var error: String? { didSet { if let error { reportError?(error) } } }
    @Published private(set) var analyzing = false
    private var base: CGImage
    private(set) var captureViewport: CGRect?
    var coordinateOrigin: CGPoint { captureViewport?.origin ?? .zero }
    var archiveMarks: [CaptureMark] { marks.map { $0.moving(by: CGSize(width: -coordinateOrigin.x, height: -coordinateOrigin.y)) } }
    /// A screenshot keeps its full source until output. Changing the crop never
    /// transforms marks or records another full-image undo snapshot.
    func setCaptureViewport(_ rect: CGRect) throws {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { throw PluginError.invalid("截图范围无效。") }
        guard captureViewport != clipped else { return }
        let previous = captureViewport
        captureViewport = clipped
        do { image = try renderCurrent() } catch { captureViewport = previous; throw error }
    }
    func replaceCaptureSource(_ source:CGImage) throws {
        let previous=base;base=source
        do { image=try renderCurrent();undoStack=[];redoStack=[];markEdit=nil;updateCounts() }
        catch { base=previous;throw error }
    }
    private func renderCurrent() throws -> CGImage {
        let source: CGImage
        if let captureViewport {
            guard let cropped = base.cropping(to: captureViewport) else { throw PluginError.invalid("无法读取截图范围。") }
            source = cropped
        } else { source = base }
        return marks.isEmpty ? source : try CaptureImage.render(source, marks: archiveMarks)
    }
    private struct Snapshot { let base: CGImage; let marks: [CaptureMark]; let offset: CGPoint }
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []
    private var markEdit: Snapshot?
    private var lastCommittedImage: CGImage?
    var commit: ((CGImage, Data?) throws -> Void)?
    private let copyDefaults: UserDefaults
    private let writeClipboard: (Data) -> Bool

    init(image: CGImage, copyDefaults: UserDefaults = .standard,
         writeClipboard: @escaping (Data) -> Bool = { CaptureClipboard.writePNG($0) != nil }) {
        self.image = image; base = image
        self.copyDefaults = copyDefaults; self.writeClipboard = writeClipboard
    }
    func add(_ mark: CaptureMark) {
        guard mark.tool != .move, mark.tool != .select else { return }
        change {
            if mark.tool == .crop {
                let rect = mark.rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else { return }
                canvasOffset.x += rect.minX; canvasOffset.y += rect.minY
                base = cropped; marks = []
            } else { marks.append(mark) }
        }
        selectedMarkID = mark.tool == .crop ? nil : mark.id
    }
    func restoreAnnotations(base:CGImage,marks:[CaptureMark]) throws {
        let rendered=try CaptureImage.render(base,marks:marks)
        self.base=base;self.marks=marks;captureViewport=nil;image=rendered;canvasOffset = .zero
        undoStack=[];redoStack=[];selectedMarkID=nil;updateCounts()
    }
    func persist(encodedPNG: Data? = nil) throws {
        guard lastCommittedImage !== image else { return }
        try commit?(image, encodedPNG);lastCommittedImage=image
    }
    var selectedMark: CaptureMark? { marks.first { $0.id == selectedMarkID } }
    var unmarkedImage: CGImage { captureViewport.flatMap { base.cropping(to: $0) } ?? base }
    var isEditingMark: Bool { markEdit != nil }
    func nextNumber(format: CaptureNumberFormat, start: Int = 1) -> Int {
        max(start,(marks.filter { $0.tool == .number && $0.style.numberFormat == format }.compactMap { $0.numberValue ?? Int($0.text) }.max() ?? (start-1)) + 1)
    }
    func beginMarkEdit(_ id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        finishMarkEdit(); selectedMarkID = id
        markEdit = Snapshot(base:base,marks:marks,offset:canvasOffset)
    }
    func previewMark(_ value: CaptureMark) {
        guard markEdit != nil, let index=marks.firstIndex(where: { $0.id == value.id }) else { return }
        marks[index] = value
        do { image=try renderCurrent() } catch { self.error=error.localizedDescription }
    }
    func finishMarkEdit() {
        guard let snapshot=markEdit else { return };markEdit=nil
        if snapshot.marks != marks { undoStack.append(snapshot);if undoStack.count > 40 { undoStack.removeFirst() };redoStack=[];updateCounts() }
    }
    func updateSelected(_ action: (inout CaptureMark) -> Void) {
        guard let index=marks.firstIndex(where: { $0.id == selectedMarkID }) else { return }
        change { action(&marks[index]) }
    }
    func replaceMark(_ value: CaptureMark) {
        guard let index=marks.firstIndex(where: { $0.id == value.id }) else { return }
        change { marks[index]=value }
    }
    func selectionAction(_ action:CaptureSelectionAction) {
        guard let index=marks.firstIndex(where:{ $0.id == selectedMarkID }) else { return }
        switch action {
        case .delete: removeMark(at:index)
        case .duplicate:
            var copy=marks[index].moving(by:CGSize(width:14,height:14));copy.id=UUID()
            if copy.tool == .number { copy.numberValue=nextNumber(format:copy.style.numberFormat) }
            add(copy)
        case .front: change { let value=marks.remove(at:index);marks.append(value) }
        case .back: change { let value=marks.remove(at:index);marks.insert(value,at:0) }
        case .straighten: updateSelected { $0.control=nil }
        }
    }
    func rotate() { change { base = try CaptureImage.rotate(image); marks = [] } }
    func undo() {
        finishMarkEdit()
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, marks: marks, offset: canvasOffset)); restore(snapshot)
    }
    func redo() {
        finishMarkEdit()
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, marks: marks, offset: canvasOffset)); restore(snapshot)
    }
    @discardableResult func copy() -> Bool {
        do {
            finishMarkEdit()
            let data = try CaptureImage.png(image)
            try persist(encodedPNG: data)
            if copyDefaults.bool(forKey: "capture.autoSaveCopy") { _ = try CaptureOutputPreferences.save(image) }
            guard writeClipboard(data) else { throw PluginError.invalid("无法写入系统剪贴板，请重试复制。") }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func clearMarks() { guard !marks.isEmpty else { return }; change { marks = [] } }
    func moveMark(at index: Int, by offset: CGSize) {
        guard marks.indices.contains(index), offset != .zero else { return }
        change { marks[index] = marks[index].moving(by:offset) }
    }
    func removeMark(at index: Int) {
        guard marks.indices.contains(index) else { return }
        change {
            let removed=marks.remove(at:index)
            if removed.tool == .number {
                var next=(removed.numberValue ?? Int(removed.text) ?? 1)+1
                while let i=marks.firstIndex(where:{ $0.tool == .number && $0.style.numberFormat == removed.style.numberFormat && ($0.numberValue ?? Int($0.text)) == next }) {
                    marks[i].numberValue=next-1;next += 1
                }
            }
        }
        selectedMarkID=nil
    }
    @discardableResult func quickSave(directory: URL? = nil) -> Bool {
        do {
            try persist()
            _ = try CaptureOutputPreferences.save(image, folder: directory)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func printImage() {
        let view = NSImageView(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        view.image = NSImage(cgImage: image, size: .zero)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        NSPrintOperation(view: view, printInfo: info).run()
    }
    func repairBackground(in rect: CGRect, intelligent: Bool = false) async {
        guard !analyzing else { return }; analyzing = true; defer { analyzing = false }
        let original = image
        do {
            let repaired: CGImage
            if intelligent { repaired = try await CaptureInpaintingEngine.shared.repair(original, rect: rect) }
            else { repaired = try await Task.detached { try CaptureTextureRepair.repair(original, rect: rect) }.value }
            guard image === original else { throw PluginError.invalid("图片已修改，请重新选择修补区域。") }
            change { base = repaired; marks = [] }
        } catch { self.error = error.localizedDescription }
    }
    func applyRedactions(_ regions: [CGRect]) {
        change { marks += regions.map { CaptureMark(tool: .mosaic, points: [$0.origin, CGPoint(x: $0.maxX, y: $0.maxY)], color: .black, width: 8) } }
    }
    func automaticallyRedact() async {
        guard !analyzing else { return }
        analyzing = true; defer { analyzing = false }
        let original = image
        do {
            let regions = try await CaptureRecognition.redactionRegions(original)
            guard image === original else { throw PluginError.invalid("图片已修改，请重新执行自动马赛克。") }
            guard !regions.isEmpty else { throw PluginError.invalid("未检测到人脸或常见敏感文本，可使用马赛克手动框选。") }
            change { marks += regions.map { CaptureMark(tool: .mosaic, points: [$0.origin, CGPoint(x: $0.maxX, y: $0.maxY)], color: .black, width: 8) } }
        } catch { self.error = error.localizedDescription }
    }
    func save(completion: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = CaptureOutputPreferences.supportedFormats.compactMap { UTType(filenameExtension: $0) } + [.pdf]
        panel.nameFieldStringValue = CaptureOutputPreferences.filename(width: image.width, height: image.height) + "." + CaptureOutputPreferences.format
        panel.directoryURL = CaptureOutputPreferences.directory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try self.persist(); try CaptureImage.write(self.image, to: url); completion?() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func change(_ action: () throws -> Void) {
        let previous = Snapshot(base: base, marks: marks, offset: canvasOffset)
        do {
            try action()
            let rendered = try renderCurrent()
            undoStack.append(previous)
            if undoStack.count > 40 { undoStack.removeFirst() }
            redoStack.removeAll()
            image = rendered; updateCounts()
        } catch {
            base = previous.base; marks = previous.marks; canvasOffset = previous.offset
            self.error = error.localizedDescription
        }
    }
    private func restore(_ snapshot: Snapshot) {
        base = snapshot.base; marks = snapshot.marks; canvasOffset = snapshot.offset
        do { image = try renderCurrent() }
        catch { self.error = error.localizedDescription }
        if !marks.contains(where: { $0.id == selectedMarkID }) { selectedMarkID=nil }
        updateCounts()
    }
    private func updateCounts() { undoCount = undoStack.count; redoCount = redoStack.count }
}

@MainActor final class ScreenshotController: ObservableObject {
    @Published private(set) var history: [CaptureRecord] = [] {
        didSet { scheduleHistoryCleanup() }
    }
    @Published private(set) var historyRetentionDays: Int
    @Published private(set) var historyCleanupWarning: String?
    @Published private(set) var busy = false
    @Published private(set) var recordingStarted: Date?
    @Published var errorMessage: String? {
        didSet { if let errorMessage { reportError?(errorMessage) } }
    }
    var reportError: ((String) -> Void)?
    @Published var notice: String?
    var showHistory: () -> Void = {}
    var canUseFeatures: () -> Bool = { true }
    var didCopyPNG: (Data, Int) -> Void = { _, _ in }
    let directory: URL
    private let service: CaptureService
    private let writePNGToPasteboard: (Data) -> Int?
    let globalMouse: CaptureGlobalMouse
    private(set) var editors: [CaptureFloatingEditor] = []
    private let historyDefaults: UserDefaults
    private let trashHistoryFile: (URL) throws -> URL
    private var historyCleanupActive = false
    private var historyCleanupTask: Task<Void, Never>?
    private var openHistoryRecords: [UUID: Int] = [:]
    private var captureGeneration = 0
    private var delayPanel: NSPanel?
    private var delayCancelled = false
    lazy var pinManager: CapturePinManager = {
        let manager = CapturePinManager(directory: directory.appendingPathComponent("Pins", isDirectory: true))
        manager.isAllowed = { [weak self] in self?.canUseFeatures() == true }
        manager.reportError = { [weak self] in self?.errorMessage = $0 }
        manager.edit = { [weak self] image, id, tab in self?.openEditor(image, record: nil, pinID: id, recognition: tab) }
        return manager
    }()
    private var scrollSession: ScrollCaptureSession?
    private var recorder: NSObject?
    private(set) var recordingPresentation: CaptureRecordingPresentation?
    private var recordingReviewID: UUID?
    private var historyReviewTask: Task<Void, Never>?
    private var stoppingRecording = false
    private var camera: CaptureCameraPair?
    private var recordingAnnotations: CaptureRecordingAnnotations?
    var isRecording: Bool { recordingStarted != nil }

    init(directory: URL? = nil, service: CaptureService = CaptureService(), globalMouse: CaptureGlobalMouse = CaptureGlobalMouse(),
         writePNGToPasteboard: @escaping (Data) -> Int? = { CaptureClipboard.writePNG($0) },
         historyDefaults: UserDefaults = .standard,
         trashHistoryFile: @escaping (URL) throws -> URL = CaptureHistoryRetention.trash) {
        self.service=service;self.globalMouse=globalMouse
        self.writePNGToPasteboard = writePNGToPasteboard
        self.historyDefaults = historyDefaults
        self.trashHistoryFile = trashHistoryFile
        historyRetentionDays = CaptureHistoryRetention.readDays(from: historyDefaults)
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.untitled.app/Capture", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let index = self.directory.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let records = try JSONDecoder().decode([CaptureRecord].self, from: Data(contentsOf: index))
                history = records.filter { Self.safeFilename($0.filename) && FileManager.default.fileExists(atPath: self.directory.appendingPathComponent($0.filename).path) }
            }
        } catch { errorMessage = "无法读取截图历史：\(error.localizedDescription)" }
    }

    static func safeFilename(_ filename: String) -> Bool {
        guard let id = UUID(uuidString: String(filename.split(separator: ".").first ?? "")) else { return false }
        return [id.uuidString + ".png", id.uuidString + ".mp4"].contains(filename)
    }

    func configureGlobalMouse(permissions: PluginPermissionClient, allowed: @escaping () -> Bool) {
        globalMouse.start(isAllowed: { [weak self] in
            guard let self else { return false }
            return allowed() && self.canUseFeatures() && !self.busy && !self.service.hasActiveCapture && !self.isRecording && self.scrollSession == nil
        }, permissions: permissions) { [weak self] selection, action in
            guard let self, self.canUseFeatures() else { return }
            self.busy = true; defer { self.busy = false }
            switch action {
            case .edit: self.accept(selection.image, at: selection.presentationFrame)
            case .copy: try self.copyAndStore(selection.image)
            case .pin: _ = try self.pinManager.create(selection.image, frame: selection.presentationFrame)
            case .text:
                let result = try await CaptureRecognition.recognize(selection.image)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
            case .save: _ = try CaptureOutputPreferences.save(selection.image)
            }
        }
    }

    func shouldIgnoreCaptureRequest(_ action:ActionKind) -> Bool {
        if action == .captureRecording,isRecording { return false } // Explicit stop remains available.
        switch action {
        case .captureRegion,.captureWindow,.captureScreen,.captureScrolling,.captureRecording,.captureDelayed,.captureAndCopy,.captureLastRegion:
            return busy || service.hasActiveCapture || scrollSession != nil || isRecording || globalMouse.hasActiveCapture
        default: return false
        }
    }
    func perform(_ action: ActionKind, permissions: PluginPermissionClient,
                 liveActions: Set<CaptureSelectionLiveAction> = [],
                 pinShortcutMatches: @escaping (UInt32, UInt32) -> Bool = { _, _ in false },
                 allowsLiveAction: @escaping @MainActor (ActionKind) -> Bool = { _ in false }) async throws {
        guard !shouldIgnoreCaptureRequest(action) else { return }
        if action == .captureRecording, isRecording { try await stopRecording(); return }
        switch action {
        case .captureHistory: showHistory(); return
        case .pinSelection, .pinClipboard:
            if canUseFeatures() { service.pinCurrentSelection() }
            return
        case .togglePins: togglePins(); return
        case .restorePin: pinManager.restoreLastClosed(); return
        case .closePins: pinManager.closeAll(); return
        case .hideOtherPins: pinManager.toggleOthers(); return
        case .togglePinClickThrough: pinManager.toggleClickThrough(); return
        case .cyclePinGroup: return // Legacy no-op; pins are no longer grouped.
        case .pinFiles: pinFiles(); return
        default: break
        }
        guard !busy, scrollSession == nil, !isRecording else { return }
        busy = true
        defer { busy = false }
        let generation = captureGeneration
        if action == .captureDelayed, !(try await waitForDelay()) { return }
        guard generation == captureGeneration, canUseFeatures() else { return }
        let mode: CaptureService.Mode = action == .captureScreen ? .screen : action == .captureWindow ? .window : .region
        var outputRecord: CaptureRecord?
        let outputHandler: CaptureSelectionOutputHandler = { [weak self] output, post, frame, target in
            guard let self,self.canUseFeatures(),self.captureGeneration == generation,!Task.isCancelled else { throw CancellationError() }
            let document = self.clipboardDocument(output.image)
            document.commit = { [weak self] image, encodedPNG in
                guard let self,self.canUseFeatures(),self.captureGeneration == generation else { throw CancellationError() }
                if let record=outputRecord {
                    try (encodedPNG ?? CaptureImage.png(image)).write(to: self.url(record), options: .atomic)
                    if let index=self.history.firstIndex(where:{ $0.id == record.id }) {
                        self.history[index].width=image.width;self.history[index].height=image.height;self.history[index].revision=UUID();try self.saveIndex()
                    }
                } else { outputRecord = try self.storeImage(image, encodedPNG: encodedPNG) }
                if let record=outputRecord { try CaptureEditableArchive.save(base:output.base,marks:output.marks,for:self.url(record)) }
            }
            switch post {
            case .copy:
                guard document.copy() else { throw PluginError.invalid(document.error ?? "复制失败，请重试。") }
            case .pin:
                try document.persist()
                let id=try self.pinManager.create(output.image,frame:frame)
                if let record=self.pinManager.record(id) { try CaptureEditableArchive.save(base:output.base,marks:output.marks,for:self.pinManager.url(record)) }
            case .save:
                guard let target else { return false };try document.persist();try CaptureImage.write(output.image,to:target)
            case .quickSave:
                guard document.quickSave() else { throw PluginError.invalid(document.error ?? "保存失败，请重试。") }
            case .ocr:
                let result=try await CaptureRecognition.recognize(output.image)
                try Task.checkCancellation()
                guard self.canUseFeatures(),self.captureGeneration == generation else { throw CancellationError() }
                guard !result.text.isEmpty else { throw PluginError.invalid("未识别到文字。") }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(result.text,forType:.string) else { throw PluginError.invalid("无法写入系统剪贴板。") }
                try document.persist()
            case .edit: return false
            }
            return true
        }
        let chosen: CaptureSelection?
        if action == .captureLastRegion {
            guard let data = UserDefaults.standard.data(forKey: "capture.lastRegion"),
                  let memory = try? JSONDecoder().decode(CaptureRegionMemory.self, from: data) else {
                throw PluginError.invalid("还没有上次截图区域，请先框选一次。")
            }
            chosen = try await service.repeatRegion(memory, permissions: permissions)
        } else {
            let canSwitch = [.captureRegion, .captureWindow, .captureDelayed].contains(action)
            chosen = try await service.choose(mode, permissions: permissions,
                allowComplexSelection: action != .captureScrolling && action != .captureRecording,
                automaticallyCopiesSelection: action == .captureAndCopy,
                liveActions: canSwitch ? liveActions : [], outputHandler: outputHandler, pinShortcutMatches: pinShortcutMatches)
        }
        guard let selection = chosen else { return }
        // Keep the frozen selection visible through history persistence and editor
        // layout; dismiss only once the destination is ready, including error exits.
        defer { selection.completePresentation() }
        guard generation == captureGeneration else { return }
        let destination = selection.liveAction?.action ?? action
        if let handoff = selection.liveAction {
            try Task.checkCancellation()
            guard handoff.isSupported, liveActions.contains(handoff), !selection.isComposite,
                  allowsLiveAction(destination) else { throw PluginError.invalid("当前选区无法执行该操作。") }
            do { try permissions.require(CapturePermissionRequirements.permissions(for: destination)) }
            catch { selection.dismissPresentation(); throw error }
        }
        let memory = CaptureRegionMemory(displayID: selection.display.displayID, rect: selection.rect)
        if !selection.isComposite {
            UserDefaults.standard.set(try JSONEncoder().encode(memory), forKey: "capture.lastRegion")
            var recent = UserDefaults.standard.data(forKey: "capture.regionHistory").flatMap { try? JSONDecoder().decode([CaptureRegionMemory].self, from: $0) } ?? []
            recent.removeAll { $0.displayID == memory.displayID && $0.rect == memory.rect }; recent.insert(memory, at: 0)
            UserDefaults.standard.set(try JSONEncoder().encode(Array(recent.prefix(100))), forKey: "capture.regionHistory")
        }
        if selection.outputHandled { return }
        guard canUseFeatures() else { throw PluginError.invalid("截图插件已停用。") }
        if selection.liveAction == nil, action != .captureScrolling && action != .captureRecording, let post = selection.postAction {
            if post != .copy { _ = try storeImage(selection.image) }
            switch post {
            case .copy: try copyAndStore(selection.image)
            case .pin: _ = try pinManager.create(selection.image, frame: selection.presentationFrame)
            case .save: CaptureDocument(image: selection.image).save()
            case .quickSave: _ = CaptureDocument(image:selection.image).quickSave()
            case .ocr, .edit: break
            }
            return
        }
        switch destination {
        case .captureScrolling:
            let switched = selection.liveAction != nil
            try startScrolling(selection, permissions: permissions, outputHandler: outputHandler, generation: generation,
                               isAllowed: { !switched || allowsLiveAction(.captureScrolling) })
        case .captureRecording:
            guard #available(macOS 15, *) else { throw PluginError.invalid("录屏需要 macOS 15 或更高版本。") }
            try await startRecording(selection, permissions: permissions) { [self] in
                generation == captureGeneration && canUseFeatures() &&
                    (selection.liveAction == nil || allowsLiveAction(destination))
            }
        case .captureAndCopy:
            try copyAndStore(selection.image)
            notice = "截图已复制并保存到历史。"
        default:
            accept(selection.image, at: selection.presentationFrame, presentation: selection.presentation,editableExport:selection.editableExport)
            if let tool = selection.initialTool { editors.last?.tool = tool }
            if let initialAction=selection.initialAction { editors.last?.perform(initialAction) }
        }
    }

    private func startScrolling(_ selection: CaptureSelection, permissions: PluginPermissionClient,
                                outputHandler: @escaping CaptureSelectionOutputHandler, generation: Int,
                                isAllowed: @escaping @MainActor () -> Bool) throws {
        let displayID = selection.display.displayID
        guard let rect = selection.presentationFrame, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }), screen.frame.contains(rect) else {
            throw PluginError.invalid("长截图所在的显示器已变化，请重新框选。")
        }

        let filter = selection.filter, crop = selection.rect, scale = selection.scale
        let displayOrigin = selection.display.frame.origin, screenFrame = screen.frame
        let axis = StitchAxis(rawValue: UserDefaults.standard.string(forKey: "capture.scrollAxis") ?? "") ?? .vertical
        let wheel = ScrollCaptureWheelDriver(selection: rect, pointer: { [weak self] in
            guard let self, self.captureGeneration == generation, self.canUseFeatures(), isAllowed() else {
                throw CancellationError()
            }
            return NSEvent.mouseLocation
        }, authorize: {
            try permissions.require([.accessibility])
        }, post: { axis, step, mouse in
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: axis == .vertical ? -Int32(step) : 0,
                                      wheel2: axis == .horizontal ? -Int32(step) : 0, wheel3: 0)
            else { return false }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.location = CGPoint(x: displayOrigin.x + mouse.x - screenFrame.minX,
                                     y: displayOrigin.y + screenFrame.maxY - mouse.y)
            event.post(tap: .cghidEventTap)
            return true
        })
        let session = ScrollCaptureSession(image: selection.image, axis: axis, sampleFrame: { [weak self] in
            guard let self, self.captureGeneration == generation, self.canUseFeatures(), isAllowed() else {
                throw CancellationError()
            }
            return try await self.service.capture(filter: filter, rect: crop, scale: scale, permissions: permissions)
        }, wheel: wheel) { [weak self] image, action, target in
            guard let self, self.captureGeneration == generation, self.canUseFeatures(), isAllowed() else {
                throw CancellationError()
            }
            if action == .edit {
                let record = try self.storeImage(image)
                self.openEditor(image, record: record, frame: rect)
                return
            }
            let frame = action == .pin ? Self.scrollPinFrame(for: image, within: rect, visibleFrame: screen.visibleFrame) : rect
            let result = CaptureSelectionExport(image: image, base: image, marks: [])
            guard try await outputHandler(result, action, frame, target) else { throw CancellationError() }
        }
        session.finished = { [weak self, weak session] in
            guard let self, self.scrollSession === session else { return }
            self.scrollSession = nil
        }
        scrollSession = session
        session.start(selection: rect, screen: screen, presentation: selection.presentation)
    }

    static func scrollPinFrame(for image: CGImage, within rect: CGRect, visibleFrame: CGRect) -> CGRect {
        CapturePinPlacement.fit(CGSize(width: image.width, height: image.height),
                                at: CGPoint(x: rect.minX, y: rect.maxY), limit: rect.size, on: visibleFrame)
    }

    @available(macOS 15, *)
    private func startRecording(_ selection: CaptureSelection, permissions: PluginPermissionClient,
                                isAllowed: @escaping @MainActor () -> Bool) async throws {
        let displayID = selection.display.displayID
        guard let region = selection.presentationFrame, let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }), !region.isEmpty, screen.frame.contains(region) else {
            throw PluginError.invalid("录屏所在的显示器已变化，请重新框选。")
        }
        let center = CGPoint(x: region.midX, y: region.midY)
        let layout = CaptureRecordingLayout(region: region, screen: screen.frame, visible: screen.visibleFrame,
                                            previousToolbar: selection.presentation?.toolbarFrame(at: center))
        closeRecordingWindows()
        let presentation = CaptureRecordingPresentation(layout: layout)
        recordingPresentation = presentation
        var started = false
        defer {
            if !started {
                presentation.close()
                if recordingPresentation === presentation { recordingPresentation = nil }
                clearRecordingOverlays()
            }
        }
        presentation.watchDisplay(displayID, frame: screen.frame) { [weak self, weak presentation] in
            guard let self, let presentation, self.recordingPresentation === presentation else { return }
            presentation.close()
            if self.isRecording {
                Task { [weak self] in
                    do { try await self?.stopRecording(showReview: false) }
                    catch { self?.errorMessage = error.localizedDescription }
                }
            }
        }
        presentation.showPreparing(seconds: UserDefaults.standard.integer(forKey: "capture.recordingDelay"))
        selection.dismissPresentation()
        let canStart = { !presentation.isClosed && isAllowed() && !Task.isCancelled }
        guard await presentation.waitForStart(isAllowed: canStart) else { return }
        if UserDefaults.standard.bool(forKey: "capture.camera") {
            let overlay = CaptureCameraPair()
            camera = overlay
            try await overlay.start(in: selection, permissions: permissions)
        }
        guard canStart() else { return }
        let annotations = CaptureRecordingAnnotations()
        annotations.start(in: selection); recordingAnnotations = annotations
        let recordingSelection = try await service.recordingSelection(selection, excluding: presentation.streamControlWindows)
        guard canStart() else { return }
        presentation.hideRecordingPopover()
        let recorder = CaptureRecorder()
        recorder.failed = { [weak self, weak recorder] message in
            guard let self, let recorder, self.recorder === recorder else { return }
            self.errorMessage = message
            Task { [weak self, weak recorder] in
                guard let self, let recorder, self.recorder === recorder else { return }
                try? await self.stopRecording()
            }
        }
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try await recorder.start(selection: recordingSelection, url: url, permissions: permissions,
                                 audio: UserDefaults.standard.bool(forKey: "capture.systemAudio"),
                                 microphone: UserDefaults.standard.bool(forKey: "capture.microphone"),
                                 cursor: UserDefaults.standard.object(forKey: "capture.cursor") as? Bool ?? true)
        guard canStart() else {
            let url = try await recorder.stop()
            try completeRecording(url, warning: recorder.errorMessage, in: nil)
            return
        }
        self.recorder = recorder; recordingStarted = Date()
        started = true
        presentation.showToolbar(RecordingControls(recorder: recorder, annotations: annotations, showAnnotations: { [weak presentation] in
            presentation?.showRecordingPopover(RecordingAnnotationTools(annotations: annotations, close: { [weak presentation] in
                presentation?.hideRecordingPopover()
            }), size: CGSize(width: 322, height: 148))
        }, confirmRestart: { [weak self, weak presentation, weak recorder] in
            presentation?.showRecordingPopover(RecordingRestartConfirmation(close: { [weak presentation] in
                presentation?.hideRecordingPopover()
            }, restart: { [weak self, weak presentation, weak recorder] in
                presentation?.hideRecordingPopover()
                Task {
                    guard let self, let recorder, self.recorder === recorder else { return }
                    annotations.clear()
                    do { try await recorder.restart() }
                    catch { self.errorMessage = error.localizedDescription }
                }
            }), size: CGSize(width: 280, height: 84))
        }, stop: { [weak self] in
            do { try await self?.stopRecording() }
            catch { self?.errorMessage = error.localizedDescription }
        }, reportError: { [weak self] error in
            self?.errorMessage = error.localizedDescription
        }, pauseChanged: { [weak presentation] paused in
            presentation?.setOutlineColor(paused ? .systemOrange : .systemRed)
        }))
    }

    private func clearRecordingOverlays() {
        camera?.stop(); camera = nil
        recordingAnnotations?.stop(); recordingAnnotations = nil
    }

    func stopRecording(showReview: Bool = true) async throws {
        guard #available(macOS 15, *), let recorder = recorder as? CaptureRecorder, !stoppingRecording else { return }
        stoppingRecording = true
        let presentation = recordingPresentation
        let generation = captureGeneration
        if showReview { presentation?.showSaving() } else { presentation?.close() }
        defer {
            self.recorder = nil; recordingStarted = nil; stoppingRecording = false
            if presentation?.playback == nil {
                presentation?.close()
                if recordingPresentation === presentation { recordingPresentation = nil }
            }
            clearRecordingOverlays()
        }
        let url = try await recorder.stop()
        try completeRecording(url, warning: recorder.errorMessage,
                              in: showReview && generation == captureGeneration ? presentation : nil)
    }

    /// Index the movie before presenting it. No review or export UI is created on
    /// teardown, and a failed stop leaves no orphaned on-screen chrome.
    func completeRecording(_ url: URL, warning: String?, in presentation: CaptureRecordingPresentation?) throws {
        guard Self.safeFilename(url.lastPathComponent), url.pathExtension == "mp4",
              let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
            throw PluginError.invalid("录屏文件名无效。")
        }
        let record = CaptureRecord(id: id, date: Date(), filename: url.lastPathComponent, width: 0, height: 0)
        try saveIndex([record] + history)
        history.insert(record, at: 0)
        notice = warning ?? "录屏已保存，可在历史中编辑或导出。"
        guard canUseFeatures(), let presentation, !presentation.isClosed else { return }
        presentRecording(record, in: presentation)
    }

    func accept(_ image: CGImage, at frame: CGRect? = nil, presentation: CaptureSelectionPresentation? = nil, editableExport:CaptureSelectionExport? = nil) {
        guard canUseFeatures() else { presentation?.dismiss(); return }
        do {
            let record = try storeImage(image)
            if let editableExport { try CaptureEditableArchive.save(base:editableExport.base,marks:editableExport.marks,for:url(record)) }
            let editor = openEditor(image, record: record, frame: frame)
            if let presentation {
                let previousClose = editor.onClose
                editor.onClose = { [weak presentation] in presentation?.dismiss(); previousClose?() }
                presentation.beginHandoff(above: [editor.canvasPanel, editor.toolsPanel,editor.stylesPanel])
            }
        } catch { presentation?.dismiss(); errorMessage = error.localizedDescription }
    }
    private func clipboardDocument(_ image: CGImage) -> CaptureDocument {
        CaptureDocument(image: image, writeClipboard: { [weak self] data in
            guard let self, let count = self.writePNGToPasteboard(data) else { return false }
            self.didCopyPNG(data, count)
            return true
        })
    }
    func copyAndStore(_ image: CGImage) throws {
        let document = clipboardDocument(image)
        document.commit = { [weak self] image, encodedPNG in
            guard let self else { throw CancellationError() }
            try self.storeImage(image, encodedPNG: encodedPNG)
        }
        guard document.copy() else { throw PluginError.invalid(document.error ?? "无法复制截图。") }
    }
    @discardableResult func storeImage(_ image: CGImage, encodedPNG: Data? = nil) throws -> CaptureRecord {
        let id = UUID()
        let record = CaptureRecord(id: id, date: Date(), filename: id.uuidString + ".png", width: image.width, height: image.height)
        try (encodedPNG ?? CaptureImage.png(image)).write(to: directory.appendingPathComponent(record.filename), options: .atomic)
        history.insert(record, at: 0)
        try saveIndex()
        return record
    }
    func open(_ record: CaptureRecord) {
        guard canUseFeatures() else { return }
        if record.isVideo { openRecording(record); return }
        do { openEditor(try CaptureImage.load(url(record)), record: record) }
        catch { errorMessage = error.localizedDescription }
    }
    func url(_ record: CaptureRecord) -> URL { directory.appendingPathComponent(record.filename) }
    func importImage() {
        guard canUseFeatures() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { self?.accept(try CaptureImage.load(url)) }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }
    static func textCard(_ text: String, file: URL? = nil) throws -> CGImage {
        let size = CGSize(width: 480, height: file == nil ? 320 : 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.textBackgroundColor.setFill(); CGRect(origin: .zero, size: size).fill()
        if let file { NSWorkspace.shared.icon(forFile: file.path).draw(in: CGRect(x: 20, y: 86, width: 48, height: 48)) }
        (String(text.prefix(10000)) as NSString).draw(in: CGRect(x: 20, y: 20, width: 440, height: file == nil ? 280 : 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PluginError.invalid("无法创建贴图。") }
        return cg
    }
    func pinFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try pinManager.createFile(url)
    }
    func pinFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "选择要贴到桌面的图片或文件"; panel.prompt = "贴图"
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            do { for url in panel.urls { try self.pinFile(url) } }
            catch { self.errorMessage = error.localizedDescription }
        }
    }
    func pin(_ image: CGImage) {
        do { try pinManager.create(image) } catch { errorMessage = error.localizedDescription }
    }
    func togglePins() { pinManager.toggleAll() }
    private func waitForDelay() async throws -> Bool {
        let alert = NSAlert(); alert.messageText = "延时截图"
        let field = NSTextField(string: String(UserDefaults.standard.object(forKey: "capture.delaySeconds") as? Int ?? 5))
        field.frame = CGRect(x: 0, y: 0, width: 160, height: 24)
        alert.informativeText = "输入等待秒数（1–60），倒计时结束后框选截图。"
        alert.accessoryView = field; alert.addButton(withTitle: "开始"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard let seconds = Int(field.stringValue), (1...60).contains(seconds) else { throw PluginError.invalid("请输入 1–60 秒。") }
        UserDefaults.standard.set(seconds, forKey: "capture.delaySeconds")
        delayCancelled = false
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 220, height: 88), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureWindowPolicy.markControl(panel, name: "delay")
        panel.isReleasedWhenClosed = false; panel.level = .floating
        delayPanel = panel; panel.center()
        defer { panel.close(); delayPanel = nil }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            panel.contentView = NSHostingView(rootView: HStack(spacing: 16) {
                Text("\(remaining) 秒后截图").monospacedDigit()
                Button("取消") { [weak self] in self?.delayCancelled = true }
            }.padding(20))
            panel.orderFrontRegardless()
            try await Task.sleep(for: .seconds(1))
            if delayCancelled || !canUseFeatures() { return false }
        }
        return true
    }
    func remove(_ record: CaptureRecord) {
        guard history.contains(where: { $0.id == record.id && $0.filename == record.filename }) else { return }
        guard openHistoryRecords[record.id] == nil else {
            errorMessage = "请先关闭这条记录的编辑或录屏预览窗口。"
            return
        }
        do { try trashHistory([record]) }
        catch { errorMessage = error.localizedDescription }
    }

    var historyRetentionGraceEnds: Date? {
        guard historyRetentionDays > 0,
              let date = historyDefaults.object(forKey: CaptureHistoryRetention.rolloutKey) as? Date,
              history.contains(where: { $0.date < date }) else { return nil }
        return date.addingTimeInterval(Double(CaptureHistoryRetention.defaultDays) * CaptureHistoryRetention.secondsPerDay)
    }

    func setHistoryRetentionDays(_ days: Int) {
        guard days == 0 || CaptureHistoryRetention.customDays.contains(days),
              days != historyRetentionDays else { return }
        historyDefaults.set(days, forKey: CaptureHistoryRetention.daysKey)
        historyRetentionDays = days
        historyCleanupWarning = nil
        scheduleHistoryCleanup()
    }

    func setHistoryCleanupActive(_ active: Bool) {
        guard active != historyCleanupActive else { return }
        if active, historyDefaults.object(forKey: CaptureHistoryRetention.rolloutKey) as? Date == nil {
            historyDefaults.set(Date(), forKey: CaptureHistoryRetention.rolloutKey)
        }
        historyCleanupActive = active
        scheduleHistoryCleanup()
    }

    deinit { historyCleanupTask?.cancel() }

    private func scheduleHistoryCleanup(retryDelay: TimeInterval = 0) {
        historyCleanupTask?.cancel()
        historyCleanupTask = nil
        guard historyCleanupActive, canUseFeatures(), historyRetentionDays > 0,
              let rollout = historyDefaults.object(forKey: CaptureHistoryRetention.rolloutKey) as? Date else { return }
        let next = history.lazy
            .filter { self.openHistoryRecords[$0.id] == nil }
            .compactMap { CaptureHistoryRetention.deadline(for: $0, days: self.historyRetentionDays, rollout: rollout) }
            .min()
        guard let next else { return }
        // One cancellable check; consult the wall clock after wake or a date change.
        let delay = max(1, retryDelay, min(next.timeIntervalSinceNow, CaptureHistoryRetention.secondsPerDay))
        historyCleanupTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.historyCleanupTask = nil
            self.runScheduledHistoryCleanup()
        }
    }

    private func runScheduledHistoryCleanup() {
        guard historyCleanupActive, canUseFeatures() else { return }
        // Moving a small batch is synchronous on the owner so that editing
        // cannot reopen or change a record between moving it and saving the index.
        guard !shouldIgnoreCaptureRequest(.captureRegion), !stoppingRecording else {
            scheduleHistoryCleanup(retryDelay: 60)
            return
        }
        do {
            try pruneExpiredHistory(at: Date())
            historyCleanupWarning = nil
            scheduleHistoryCleanup()
        } catch {
            historyCleanupWarning = "历史记录清理未完成。请检查废纸篓及磁盘空间；应用稍后会重试。"
            scheduleHistoryCleanup(retryDelay: 3600)
        }
    }

    func pruneExpiredHistory(at now: Date) throws {
        guard historyCleanupActive, canUseFeatures(), historyRetentionDays > 0,
              let rollout = historyDefaults.object(forKey: CaptureHistoryRetention.rolloutKey) as? Date else { return }
        let expired = history.reversed().lazy.filter { record in
            self.openHistoryRecords[record.id] == nil &&
                CaptureHistoryRetention.deadline(for: record, days: self.historyRetentionDays, rollout: rollout)
                    .map { $0 <= now } == true
        }.prefix(CaptureHistoryRetention.batchSize)
        if !expired.isEmpty { try trashHistory(Array(expired)) }
    }

    private func trashHistory(_ records: [CaptureRecord]) throws {
        let ids = Set(records.map(\.id))
        let kept = history.filter { !ids.contains($0.id) }
        guard history.count - kept.count == records.count,
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw PluginError.invalid("历史索引或文件夹不匹配，未移动文件。")
        }
        let files = try records.flatMap { record in
            guard record.filename == record.id.uuidString + (record.isVideo ? ".mp4" : ".png") else {
                throw PluginError.invalid("历史文件名不匹配，未移动文件。")
            }
            let file = url(record)
            return record.isVideo ? [file] + recordingSidecars(for: file) : [file, CaptureEditableArchive.url(for: file)]
        }
        try CaptureHistoryRetention.moveToTrash(files, move: trashHistoryFile) { try saveIndex(kept) }
        history = kept
    }

    private func beginUsingHistory(_ id: UUID) {
        openHistoryRecords[id, default: 0] += 1
        scheduleHistoryCleanup()
    }

    private func endUsingHistory(_ id: UUID) {
        if let count = openHistoryRecords[id], count > 1 { openHistoryRecords[id] = count - 1 }
        else { openHistoryRecords[id] = nil }
        scheduleHistoryCleanup()
    }

    private func recordingSidecars(for movie: URL) -> [URL] {
        ["events.json", "system.m4a", "microphone.m4a", "audio.json"].map { movie.deletingPathExtension().appendingPathExtension($0) }
    }

    func importRecoveredRecording(_ recovered: URL) {
        do {
            var movie = recovered
            if !Self.safeFilename(movie.lastPathComponent) {
                movie = directory.appendingPathComponent(UUID().uuidString + ".mp4")
                try FileManager.default.moveItem(at: recovered, to: movie)
                for (source, target) in zip(recordingSidecars(for: recovered), recordingSidecars(for: movie)) where FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: target)
                }
            }
            guard !history.contains(where: { $0.filename == movie.lastPathComponent }),
                  let id = UUID(uuidString: movie.deletingPathExtension().lastPathComponent) else { return }
            history.insert(CaptureRecord(id: id, date: Date(), filename: movie.lastPathComponent, width: 0, height: 0), at: 0)
            try saveIndex()
            notice = "中断的录屏已恢复到历史记录。"
        } catch { errorMessage = error.localizedDescription }
    }
    func deactivate() {
        setHistoryCleanupActive(false)
        globalMouse.stop()
        objectWillChange.send()
        service.cancel()
        captureGeneration += 1; delayCancelled = true; delayPanel?.orderOut(nil)
        if let scrolling = scrollSession {
            scrolling.suspendPresentation()
            Task { [weak self] in
                if !(await scrolling.preserveAndClose()) {
                    self?.errorMessage = "长截图暂存失败，结果仍在内存中。请检查磁盘空间后再退出。"
                }
            }
        }
        Array(editors).forEach { $0.close() }
        closeRecordingWindows()
        pinManager.deactivate()
        if isRecording { Task { try? await stopRecording(showReview: false) } }
    }
    @discardableResult func prepareForQuit() async -> Bool {
        setHistoryCleanupActive(false)
        if let scrolling = scrollSession {
            guard await scrolling.preserveAndClose() else {
                errorMessage = "长截图尚未保存，已取消退出。请先导出或检查磁盘空间后重试。"
                return false
            }
            scrollSession = nil
        }
        globalMouse.stop()
        Array(editors).forEach { $0.close() }
        pinManager.saveNow(); captureGeneration += 1; delayCancelled = true
        service.cancel(); closeRecordingWindows()
        if isRecording {
            do { try await stopRecording(showReview: false) }
            catch { errorMessage = error.localizedDescription; return false }
        }
        while stoppingRecording {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
    @discardableResult private func openEditor(_ image: CGImage, record: CaptureRecord?, pinID: UUID? = nil, recognition: RecognitionTab? = nil, frame: CGRect? = nil) -> CaptureFloatingEditor {
        if let pinID, let existing = editors.first(where: { $0.canvasPanel.identifier?.rawValue == pinID.uuidString }) {
            existing.show(recognition: recognition); return existing
        }
        let preferred = pinID.flatMap { pinManager.beginEditing($0) } ?? frame
        let document = clipboardDocument(image)
        let archiveURL=record.map(url) ?? pinID.flatMap { pinManager.record($0).map(pinManager.url) }
        let transformedPin = pinID.flatMap { pinManager.record($0)?.adjustments }.map { $0 != CapturePinAdjustments() } ?? false
        if let archiveURL, !transformedPin {
            do { try CaptureEditableArchive.restore(document,for:archiveURL) }
            catch { document.error="无法恢复可编辑标注，已打开导出的图片："+error.localizedDescription }
        }
        let editor = CaptureFloatingEditor(document: document, controller: self, preferredFrame: preferred,
                                           preservesPresentationFrame: frame != nil)
        if let pinID { editor.canvasPanel.identifier = NSUserInterfaceItemIdentifier(pinID.uuidString) }
        document.commit = { [weak self, weak editor, weak document] image, encodedPNG in
            guard let self else { return }
            if let pinID { try self.pinManager.updateImage(image, id: pinID, frame: editor?.imageFrame) }
            if let archiveURL,let document { try CaptureEditableArchive.save(document,for:archiveURL) }
            guard let record else { return }
            try (encodedPNG ?? CaptureImage.png(image)).write(to: self.url(record), options: .atomic)
            if let index = self.history.firstIndex(where: { $0.id == record.id }) {
                self.history[index].width = image.width; self.history[index].height = image.height
                self.history[index].revision = UUID()
                try self.saveIndex()
            }
        }
        editor.pinImage = { [weak self, weak document] image, frame in
            guard let self, self.canUseFeatures() else { throw PluginError.invalid("截图插件已停用。") }
            if let pinID { try self.pinManager.updateImage(image, id: pinID, frame: frame) }
            else {
                let id=try self.pinManager.create(image,frame:frame)
                if let document,let pin=self.pinManager.record(id) { try CaptureEditableArchive.save(document,for:self.pinManager.url(pin)) }
            }
        }
        editors.append(editor)
        if let record { beginUsingHistory(record.id) }
        editor.onClose = { [weak self, weak editor] in
            if let pinID { self?.pinManager.endEditing(pinID) }
            if let record { self?.endUsingHistory(record.id) }
            self?.editors.removeAll { $0 === editor }
        }
        editor.show(recognition: recognition)
        return editor
    }
    private func closeRecordingWindows() {
        historyReviewTask?.cancel(); historyReviewTask = nil
        recordingPresentation?.close(); recordingPresentation = nil
    }

    private func presentRecording(_ record: CaptureRecord, in presentation: CaptureRecordingPresentation) {
        guard !presentation.isClosed else { return }
        if recordingPresentation !== presentation { recordingPresentation?.close(); recordingPresentation = presentation }
        recordingReviewID = record.id
        beginUsingHistory(record.id)
        presentation.onClose = { [weak self, weak presentation] in
            guard let self else { return }
            self.endUsingHistory(record.id)
            if self.recordingPresentation === presentation {
                self.recordingPresentation = nil
                self.recordingReviewID = nil
            }
        }
        presentation.showReview(url: url(record))
    }

    private func openRecording(_ record: CaptureRecord) {
        if recordingReviewID == record.id, let presentation = recordingPresentation, !presentation.isClosed {
            presentation.focusReview()
            return
        }
        guard !busy, !isRecording else { return }
        historyReviewTask?.cancel()
        let url = url(record)
        historyReviewTask = Task { [weak self] in
            do {
                let media = try await CaptureRecordingPlayback.Media.read(AVURLAsset(url: url))
                try Task.checkCancellation()
                guard let self, self.canUseFeatures(), !self.busy, !self.isRecording,
                      self.history.contains(where: { $0.id == record.id && $0.filename == record.filename }),
                      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                let safe = visible.insetBy(dx: 18, dy: 62)
                let native = CGSize(width: media.size.width / screen.backingScaleFactor,
                                    height: media.size.height / screen.backingScaleFactor)
                let factor = min(1, safe.width / native.width, safe.height / native.height, 900 / native.width)
                let size = CGSize(width: native.width * factor, height: native.height * factor)
                let region = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                    width: size.width, height: size.height)
                let layout = CaptureRecordingLayout(region: region, screen: screen.frame, visible: visible, previousToolbar: nil)
                let presentation = CaptureRecordingPresentation(layout: layout)
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    presentation.watchDisplay(id, frame: screen.frame) { [weak presentation] in presentation?.close() }
                }
                self.presentRecording(record, in: presentation)
            } catch {
                if !Task.isCancelled { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    private func saveIndex(_ records: [CaptureRecord]? = nil) throws {
        try JSONEncoder().encode(records ?? history)
            .write(to: directory.appendingPathComponent("history.json"), options: .atomic)
    }
}

@available(macOS 15, *)
private struct RecordingControls: View {
    @ObservedObject var recorder: CaptureRecorder
    @ObservedObject var annotations: CaptureRecordingAnnotations
    let showAnnotations: () -> Void
    let confirmRestart: () -> Void
    let stop: () async -> Void
    let reportError: (Error) -> Void
    let pauseChanged: (Bool) -> Void
    @ViewState private var hint: String?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .foregroundStyle(recorder.isPaused ? .orange : .red)
                .accessibilityLabel(recorder.isPaused ? "录制已暂停" : "正在录制")
            if recorder.isPaused { elapsedTime }
            else { TimelineView(.periodic(from: .now, by: 1)) { _ in elapsedTime } }
            if let hint {
                Text(hint).foregroundStyle(.secondary).lineLimit(1).accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            let annotationTitle = annotations.tool?.title ?? "录屏标注"
            Button(action: showAnnotations) {
                Image(systemName: annotations.tool?.symbol ?? "pencil.tip").frame(width: 28, height: 28)
            }
            .modifier(CaptureToolbarControl(hint: annotationTitle, selected: annotations.tool != nil, inlineHint: setHint))
            .accessibilityLabel(annotationTitle)
            let pauseTitle = recorder.isPaused ? "继续录制" : "暂停录制"
            Button {
                Task {
                    do { if recorder.isPaused { try await recorder.resume() } else { try await recorder.pause() } }
                    catch { reportError(error) }
                }
            } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .modifier(CaptureToolbarControl(hint: pauseTitle, inlineHint: setHint))
            .accessibilityLabel(pauseTitle).disabled(recorder.isTransitioning)
            Button(action: confirmRestart) {
                Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .modifier(CaptureToolbarControl(hint: "重新录制…", inlineHint: setHint))
            .accessibilityLabel("重新录制…").disabled(recorder.isTransitioning)
            Button {
                Task { await stop() }
            } label: {
                Label("停止录制", systemImage: "stop.fill")
                    .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
            }
            .modifier(CaptureToolbarControl(hint: "停止录制，在原位预览", prominent: true, inlineHint: setHint))
            .disabled(recorder.isTransitioning)
        }
        .modifier(CaptureRecordingBarStyle())
        .onChange(of: recorder.isPaused) { _, paused in pauseChanged(paused) }
    }

    private func setHint(_ text: String?) { hint = text }

    private var elapsedTime: some View {
        Text(Duration.seconds(recorder.elapsedTime).formatted(.time(pattern: .minuteSecond)))
            .monospacedDigit().fixedSize()
    }
}

private struct RecordingRestartConfirmation: View {
    let close: () -> Void
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text("舍弃本次录制并重新开始？").frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("重新录制", role: .destructive, action: restart).buttonStyle(.bordered)
            }
        }
        .font(.system(size: 12)).padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(CaptureToolbarSurface())
    }
}
