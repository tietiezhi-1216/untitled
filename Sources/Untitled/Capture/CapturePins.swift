import AppKit
import Combine
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct CapturePinRecord: Codable, Identifiable {
    var id = UUID()
    let filename: String
    // v1 disk field retained for compatibility with earlier local builds.
    var groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var date = Date()
    var isOpen = true
    var closedAt: Date?
    var frame: CGRect?
    var opacity = 1.0
    var locked = false
    var floating = true
    var shadow = true
    var clickThrough = false
    var revision = UUID()
    var text: String?
    var sourceFile: URL?
    var payload: CapturePinPayload?
    var viewport: CGRect?
    var adjustments: CapturePinAdjustments?
}

enum CapturePinPlacement {
    static func fit(_ pixels: CGSize, at topLeft: CGPoint, limit: CGSize, on visibleFrame: CGRect) -> CGRect {
        let safe = visibleFrame.insetBy(dx: min(24, visibleFrame.width / 4), dy: min(24, visibleFrame.height / 4))
        let scale = min(limit.width / pixels.width, limit.height / pixels.height,
                        safe.width / pixels.width, safe.height / pixels.height)
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let x = min(max(safe.minX, topLeft.x), safe.maxX - size.width)
        let y = min(max(safe.minY, topLeft.y - size.height), safe.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor final class CapturePinManager: ObservableObject {
    private struct Archive: Codable {
        private struct LegacyGroup: Codable {
            let id: UUID
            let name: String
        }
        private static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var version = 1
        private var groups = [LegacyGroup(id: Archive.defaultID, name: "默认分组")]
        var records: [CapturePinRecord] = []
        private var activeGroupID = Archive.defaultID

        init() {}
    }
    // Keep the original v1 metadata for rollback, but never select or filter by it.
    private var archive = Archive()
    @Published private(set) var records: [CapturePinRecord] = []
    @Published private(set) var hidden = false
    var isAllowed: () -> Bool = { true }
    var edit: ((CGImage, UUID, RecognitionTab?) -> Void)?
    var reportError: ((String) -> Void)?
    let directory: URL
    private let displaysWindows: Bool
    private let automaticExports: Bool
    private(set) var loadError: String?
    fileprivate var panels: [UUID: CapturePinWindow] = [:]
    var images: [UUID: CGImage] = [:]
    private var focusedID: UUID?
    @Published var selectedIDs = Set<UUID>()
    var renderedImages: [UUID: CGImage] = [:]
    var recognized: [UUID: CaptureText] = [:]
    var recognitionTasks: [UUID: Task<Void, Never>] = [:]
    var selectedTexts: [UUID: String] = [:]
    var animations: [UUID: CapturePinAnimation] = [:]
    private var keepOnly: UUID?
    private var editingIDs = Set<UUID>()
    private var active = false
    private var closingForLifecycle = false
    private var saveTask: Task<Void, Never>?

    init(directory: URL, displaysWindows: Bool = true, automaticExports: Bool? = nil) {
        self.directory = directory; self.displaysWindows = displaysWindows; self.automaticExports = automaticExports ?? displaysWindows
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("pins.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 32 * 1024 * 1024 else { throw PluginError.invalid("贴图索引过大。") }
                var stored = try JSONDecoder().decode(Archive.self, from: data)
                guard stored.version == 1, Set(stored.records.map(\.id)).count == stored.records.count else {
                    throw PluginError.invalid("贴图索引格式无效。")
                }
                records = stored.records.filter {
                    ScreenshotController.safeFilename($0.filename) && $0.filename.hasSuffix(".png")
                    && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
                }
                stored.records = []
                archive = stored
            }
        } catch { loadError = "无法读取贴图历史：\(error.localizedDescription)" }
    }
    func url(_ record: CapturePinRecord) -> URL { directory.appendingPathComponent(record.filename) }
    func record(_ id: UUID) -> CapturePinRecord? { records.first { $0.id == id } }
    func image(_ id: UUID) -> CGImage? { renderedImages[id] ?? images[id] }
    func activate() {
        guard !active, isAllowed() else { return }
        active = true
        if let loadError { reportError?(loadError); self.loadError = nil }
        for item in records where item.isOpen { show(item) }
        refreshVisibility()
    }
    func deactivate() {
        saveNow(); active = false; closingForLifecycle = true
        Array(panels.values).forEach { $0.close() }
        panels = [:]; images = [:]; renderedImages = [:]; animations.values.forEach { $0.stop() }; animations = [:]; recognitionTasks.values.forEach { $0.cancel() }; recognitionTasks = [:]; closingForLifecycle = false
    }
    @discardableResult func create(_ image: CGImage, text: String? = nil, sourceFile: URL? = nil, frame: CGRect? = nil, payload: CapturePinPayload? = nil) throws -> UUID {
        guard isAllowed() else { throw PluginError.invalid("截图插件已停用。") }
        let id = UUID()
        let record = CapturePinRecord(id: id, filename: id.uuidString + ".png", frame: frame, text: text, sourceFile: sourceFile, payload: payload)
        try CaptureImage.png(image).write(to: url(record), options: .atomic)
        records.append(record); images[id] = image
        selectedIDs = [id]
        hidden = false; keepOnly = nil; active = true
        show(record); saveNow()
        if automaticExports,UserDefaults.standard.bool(forKey:"capture.autoSavePin") {
            let imageFile=sourceFile.flatMap { try? $0.resourceValues(forKeys:[.contentTypeKey]).contentType }?.conforms(to:.image) == true
            let isImage=payload?.kind == .image || (payload==nil && text==nil && (sourceFile==nil || imageFile))
            if isImage {
                do { _ = try CaptureOutputPreferences.save(image) }
                catch { reportError?("贴图已创建，自动保存失败："+error.localizedDescription) }
            }
        }
        return id
    }
    func updateImage(_ image: CGImage, id: UUID, frame: CGRect? = nil) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        try CaptureImage.png(image).write(to: url(records[index]), options: .atomic)
        recognitionTasks[id]?.cancel();recognitionTasks[id]=nil;selectedTexts[id]=nil
        images[id] = image; renderedImages[id] = nil; recognized[id] = nil; records[index].revision = UUID()
        records[index].adjustments = nil; records[index].viewport = nil
        if records[index].payload?.kind != .image { records[index].payload = nil; records[index].text = nil; animations[id]?.stop(); animations[id] = nil }
        if let frame { records[index].frame = frame }
        if let panel = panels[id] {
            panel.aspectRatio = CGSize(width: image.width, height: image.height)
            panel.contentView = content(id)
            if let frame { panel.positionPin(frame) }
        }
        saveNow()
        if displaysWindows { recognizeText(id) }
    }
    func restoreLastClosed() {
        let item = records.lazy.filter { !$0.isOpen }.max { lhs, rhs in
            (lhs.closedAt ?? lhs.date, lhs.date) < (rhs.closedAt ?? rhs.date, rhs.date)
        }
        if let item { restore(item.id) }
    }
    func restore(_ id: UUID) {
        guard isAllowed(), let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isOpen = true; records[index].closedAt = nil
        hidden = false; keepOnly = nil; show(records[index]); refreshVisibility()
        focusedID = id; selectedIDs = [id]
        if let panel = panels[id] {
            // “定位 / 恢复” is an explicit request to find the pin. Normal dragging,
            // visibility changes, and startup never pull an offscreen pin back.
            if !NSScreen.screens.contains(where: { !$0.visibleFrame.intersection(panel.frame).isEmpty }) {
                panel.center()
            }
            panel.makeKeyAndOrderFront(nil)
        }
        saveNow()
    }
    func close(_ id: UUID) {
        if let panel = panels[id] { panel.close() } else { didClose(id) }
    }
    func closeAll() { records.filter(\.isOpen).forEach { close($0.id) } }
    fileprivate func didClose(_ id: UUID) {
        panels.removeValue(forKey: id); images.removeValue(forKey: id); renderedImages[id] = nil
        animations[id]?.stop(); animations[id] = nil; recognitionTasks[id]?.cancel(); recognitionTasks[id] = nil; selectedIDs.remove(id);selectedTexts[id]=nil
        guard !closingForLifecycle, let index = records.firstIndex(where: { $0.id == id }),
              records[index].isOpen else { return }
        records[index].isOpen = false; records[index].closedAt = Date()
        if keepOnly == id { keepOnly = nil; refreshVisibility() }
        saveNow()
    }
    func toggleAll() { hidden.toggle(); refreshVisibility() }
    func toggleOthers() {
        guard let id = focusedPin() else { return }
        keepOnly = keepOnly == nil ? id : nil
        hidden = false; refreshVisibility()
    }
    func toggleClickThrough() {
        if let id = pinUnderMouse(), let index = records.firstIndex(where: { $0.id == id }) {
            records[index].clickThrough.toggle(); apply(records[index])
        } else {
            for index in records.indices { records[index].clickThrough = false; apply(records[index]) }
        }
        saveNow()
    }
    func remove(_ id: UUID) {
        guard let item = record(id) else { return }
        do {
            if let file = item.payload?.assetFilename, CapturePinMedia.safeAssetFilename(file) {
                let asset = directory.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath:asset.path) { try FileManager.default.trashItem(at:asset,resultingItemURL:nil) }
            }
            try CaptureEditableArchive.trash(for:url(item))
            try FileManager.default.trashItem(at: url(item), resultingItemURL: nil)
            close(id); records.removeAll { $0.id == id }; saveNow()
        } catch { reportError?(error.localizedDescription) }
    }
    func beginEditing(_ id: UUID) -> CGRect? {
        guard let item = record(id) else { return nil }
        editingIDs.insert(id); panels[id]?.orderOut(nil)
        return panels[id]?.frame ?? item.frame
    }
    func endEditing(_ id: UUID) {
        editingIDs.remove(id)
        if isAllowed() { refreshVisibility() }
    }
    func editPin(_ id: UUID, tab: RecognitionTab? = nil) {
        guard isAllowed(), let image = image(id) else { return }
        edit?(image, id, tab)
    }
    func copy(_ id: UUID) {
        if selection(id).count>1 { copySelection(id);return }
        if let text = selectedTexts[id], !text.isEmpty {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); return
        }
        guard let image = visibleImage(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try? CaptureImage.png(image), forType: .png)
        if let text = record(id)?.text { NSPasteboard.general.setString(text, forType: .string) }
        if let file = assetURL(id) { NSPasteboard.general.setString(file.absoluteString,forType:.fileURL) }
    }
    func toggle(_ id: UUID, _ key: WritableKeyPath<CapturePinRecord, Bool>) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index][keyPath: key].toggle(); apply(records[index]); saveNow()
    }
    func resetSize(_ id: UUID) {
        guard let panel = panels[id], let pixels = viewportSize(id) else { return }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.positionPin(CapturePinPlacement.fit(pixels, at: topLeft, limit: pixels, on: screen))
        if let index = records.firstIndex(where: { $0.id == id }) { records[index].opacity = 1; apply(records[index]) }
        saveNow()
    }
    func scroll(_ id: UUID, delta: CGFloat, opacity: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].locked, let panel = panels[id] else { return }
        if opacity {
            records[index].opacity = min(1, max(0.1, records[index].opacity + Double(delta) * 0.015)); apply(records[index])
        } else {
            let ratio = panel.aspectRatio.height / panel.aspectRatio.width
            guard ratio.isFinite, ratio > 0, delta.isFinite, delta != 0 else { return }
            // Use the long side: rounding the short side to a point must not
            // change the pin's scale. A 60 pt width floor can also stop tall pins from shrinking.
            let frame = panel.frame
            let tall = ratio > 1
            let current = tall ? frame.height : frame.width
            let minimum = min(current, 300, 60 * max(1, ratio))
            let maximum = max(current, 3000)
            let length = min(maximum, max(minimum, current * (1 + delta * 0.015)))
            let size = tall ? CGSize(width: length / ratio, height: length)
                            : CGSize(width: length, height: length * ratio)
            panel.positionPin(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                    width: size.width, height: size.height))
        }
        saveSoon()
    }
    private func document(_ image: CGImage) -> CaptureDocument {
        let document = CaptureDocument(image: image)
        document.reportError = { [weak self] in self?.reportError?($0) }
        return document
    }
    func perform(_ action: CaptureShortcutAction, id: UUID) {
        guard isAllowed(), let image = visibleImage(id) else { return }
        if let animation = animations[id] {
            switch action {
            case .pinAnnotate: animation.toggle(); return
            case .moveLeft: animation.step(-1); return
            case .moveRight: animation.step(1); return
            case .moveUp: animation.changeSpeed(1.5); return
            case .moveDown: animation.changeSpeed(1/1.5); return
            default: break
            }
        }
        switch action {
        case .close: closeSelection(id)
        case .copy: copy(id)
        case .save: document(image).save()
        case .quickSave: document(image).quickSave()
        case .printImage: document(image).printImage()
        case .ocr:
            Task {
                do {
                    let result = try await CaptureRecognition.recognize(image)
                    guard !result.text.isEmpty else { throw PluginError.invalid("未识别到文字。") }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
                } catch { reportError?(error.localizedDescription) }
            }
        case .translation: editPin(id, tab: .translation)
        case .document: editPin(id, tab: .document)
        case .table: editPin(id, tab: .table)
        case .formula: editPin(id, tab: .formula)
        case .pinAnnotate: editPin(id)
        case .pinLock: toggle(id, \.locked)
        case .pinTop: toggle(id, \.floating)
        case .pinShadow: toggle(id, \.shadow)
        case .pinOthers: focusedID = id; toggleOthers()
        case .pinNext:
            let items = records.filter { $0.isOpen && !$0.clickThrough }
            if let index = items.firstIndex(where: { $0.id == id }), !items.isEmpty {
                let next = items[(index + 1) % items.count].id
                focusedID = next; panels[next]?.makeKeyAndOrderFront(nil)
            }
        case .moveUp, .moveDown, .moveLeft, .moveRight:
            guard let panel = panels[id], record(id)?.locked == false else { return }
            let dx: CGFloat = action == .moveLeft ? -1 : action == .moveRight ? 1 : 0
            let dy: CGFloat = action == .moveDown ? -1 : action == .moveUp ? 1 : 0
            panel.positionPin(panel.frame.offsetBy(dx: dx, dy: dy))
        default: break
        }
    }
    fileprivate func frameChanged(_ id: UUID, frame: CGRect) {
        guard !closingForLifecycle, let index = records.firstIndex(where: { $0.id == id }),
              records[index].frame != frame else { return }
        records[index].frame = frame; saveSoon()
    }
    fileprivate func focus(_ id: UUID) { focusedID = id }
    func setRecord(_ value: CapturePinRecord) {
        guard let index = records.firstIndex(where: { $0.id == value.id }) else { return }; records[index] = value; saveSoon()
    }
    func select(_ id: UUID, extending: Bool = false) {
        focusedID = id
        if extending { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) } }
        else if !selectedIDs.contains(id) { selectedIDs = [id] }
    }
    func selection(_ id: UUID) -> Set<UUID> { selectedIDs.contains(id) ? selectedIDs : [id] }
    func closeSelection(_ id: UUID) {
        let prevent=UserDefaults.standard.object(forKey:"capture.pin.lockPreventsClose") as? Bool ?? true
        selection(id).filter { !prevent || record($0)?.locked != true }.forEach { close($0) }
    }
    func dragSelection(_ id:UUID,delta:CGSize) {
        for key in selection(id) where record(key)?.locked == false {
            if let panel = panels[key] { panel.positionPin(panel.frame.offsetBy(dx: delta.width, dy: delta.height)) }
        }
    }
    func refreshContent(_ id:UUID) { panels[id]?.contentView = content(id) }
    private func viewportSize(_ id: UUID) -> CGSize? {
        guard let image = image(id) else { return nil }
        let fraction = record(id)?.viewport?.size ?? CGSize(width: 1, height: 1)
        let size = CGSize(width: CGFloat(image.width) * fraction.width, height: CGFloat(image.height) * fraction.height)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size
    }
    func sizeForViewport(_ id: UUID) {
        guard let panel = panels[id], let pixels = viewportSize(id) else { return }
        panel.aspectRatio = pixels
        let frame = panel.frame
        let ratio = pixels.height / pixels.width
        let height = frame.width * ratio
        // AppKit rounds window sizes. For very tall/narrow images, one point
        // of width rounding must not resize the pin every time it is reopened.
        let shortSideError = ratio > 1 ? abs(frame.width - frame.height / ratio) : abs(frame.height - height)
        guard shortSideError > 1 else { return }
        panel.positionPin(CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height))
    }
    private func pinUnderMouse() -> UUID? {
        NSApp.orderedWindows.compactMap { $0 as? CapturePinWindow }
            .first { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }?.pinID
    }
    private func focusedPin() -> UUID? {
        let id = pinUnderMouse() ?? (NSApp.keyWindow as? CapturePinWindow)?.pinID ?? focusedID
        if let id, record(id)?.isOpen == true { return id }
        return records.first { $0.isOpen }?.id
    }
    private func refreshVisibility() {
        for (id, panel) in panels {
            if let item = record(id), !editingIDs.contains(id), item.isOpen, !hidden, keepOnly == nil || keepOnly == id {
                panel.orderFrontRegardless()
            } else { panel.orderOut(nil) }
        }
    }
    private func show(_ item: CapturePinRecord) {
        guard displaysWindows, isAllowed() else { return }
        if let existing = panels[item.id] { existing.orderFrontRegardless(); return }
        do {
            let image = try images[item.id] ?? CaptureImage.load(url(item))
            images[item.id] = image
            rebuildImage(item.id)
            let factor = min(1, 640 / CGFloat(max(image.width, image.height)))
            let initial = CGRect(x: 100, y: 100, width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
            let panel = CapturePinWindow(id: item.id, frame: item.frame ?? initial, manager: self)
            panel.aspectRatio = CGSize(width: image.width, height: image.height)
            panel.contentView = content(item.id)
            panels[item.id] = panel
            if let frame = item.frame {
                panel.positionPin(frame, display: false)
            } else { panel.center() }
            apply(item); sizeForViewport(item.id)
            panel.orderFrontRegardless(); focusedID = item.id
            startAnimation(item.id); recognizeText(item.id)
        } catch { reportError?(error.localizedDescription) }
    }
    private func content(_ id: UUID) -> NSView { NSHostingView(rootView: CapturePinnedContent(manager: self, id: id)) }
    private func apply(_ item: CapturePinRecord) {
        guard let panel = panels[item.id] else { return }
        panel.alphaValue = min(1, max(0.1, item.opacity)); panel.level = item.floating ? .floating : .normal
        panel.hasShadow = item.shadow; panel.ignoresMouseEvents = item.clickThrough
        if item.locked { panel.styleMask.remove(.resizable) } else { panel.styleMask.insert(.resizable) }
    }
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        do {
            var output = archive
            output.records = records
            try JSONEncoder().encode(output).write(to: directory.appendingPathComponent("pins.json"), options: .atomic)
        } catch { reportError?(error.localizedDescription) }
    }
}

private final class CapturePinWindow: NSPanel, NSWindowDelegate {
    let pinID: UUID
    private weak var manager: CapturePinManager?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(id: UUID, frame: CGRect, manager: CapturePinManager) {
        pinID = id; self.manager = manager
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear
        collectionBehavior = CaptureWindowPolicy.floatingBehavior
        delegate = self
    }
    override func constrainFrameRect(_ frameRect: CGRect, to screen: NSScreen?) -> CGRect {
        // Pins may extend beyond any display, even when AppKit reorders them.
        frameRect
    }

    func positionPin(_ frame: CGRect, display: Bool = true) {
        guard frame != self.frame else { return }
        if frame.size == self.frame.size { setFrameOrigin(frame.origin) }
        else { setFrame(frame, display: display) }
    }

    func windowWillClose(_ notification: Notification) { manager?.didClose(pinID) }
    func windowDidMove(_ notification: Notification) { manager?.frameChanged(pinID, frame: frame) }
    func windowDidResize(_ notification: Notification) { manager?.frameChanged(pinID, frame: frame) }
    func windowDidBecomeKey(_ notification: Notification) { manager?.focus(pinID) }
}

private struct CapturePinnedContent: View {
    @ObservedObject var manager: CapturePinManager
    let id: UUID
    var body: some View {
        Group {
            if let image = manager.image(id) {
                CapturePinSurface(image: image, manager: manager, id: id)
                    .contextMenu {
                        Button("复制") { manager.copy(id) }
                        Button("复制原始图像") { manager.copyOriginal(id) }
                        if manager.record(id)?.text != nil { Button("复制全部文本 / 源码") { manager.copyText(id) } }
                        Button("选择全部文字") { manager.selectAllText(id) }
                        Button(manager.record(id)?.viewport == nil ? "缩略图（右键拖动框选范围）" : "退出缩略图") { manager.toggleViewport(id) }
                        if ![CapturePinPayload.Kind.text,.richText,.formula].contains(manager.record(id)?.payload?.kind ?? .image) {
                        Menu("图像调整") {
                            Button("顺时针旋转 90°") { manager.adjust(id) { $0.quarterTurns += 1 } }
                            Button("水平翻转") { manager.adjust(id) { $0.flipX.toggle() } }
                            Button("垂直翻转") { manager.adjust(id) { $0.flipY.toggle() } }
                            Button("灰度") { manager.adjust(id) { $0.grayscale.toggle() } }
                            Button("反色") { manager.adjust(id) { $0.inverted.toggle() } }
                            Button("调亮") { manager.adjust(id) { $0.brightness=min(1,$0.brightness+0.1) } }
                            Button("调暗") { manager.adjust(id) { $0.brightness=max(-1,$0.brightness-0.1) } }
                            Button("恢复原图") { manager.adjust(id) { $0 = CapturePinAdjustments() } }
                        }
                        }
                        if let animation=manager.animations[id] {
                            Menu("动画") {
                                Button(animation.paused ? "播放" : "暂停") { animation.toggle() }
                                Button("上一帧") { animation.step(-1) }
                                Button("下一帧") { animation.step(1) }
                                Button("加快") { animation.changeSpeed(1.5) }
                                Button("减慢") { animation.changeSpeed(1/1.5) }
                                Button("原始速度") { animation.speed=1 }
                                Button("保存原始动图…") { manager.saveAnimation(id) }
                                Text("第 \(animation.index+1) / \(animation.count) 帧")
                            }
                        }
                        if manager.record(id)?.payload?.kind == .richText {
                            Button("忽略 / 恢复格式") { manager.toggleRichText(id) }
                        }
                        Divider()
                        if let file = manager.record(id)?.sourceFile {
                            Button("在访达中显示源文件") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        }
                        Button("编辑 / 标注") { manager.editPin(id) }
                        Button("识别文字") { manager.editPin(id, tab: .text) }
                        Button("翻译") { manager.editPin(id, tab: .translation) }
                        Button("保存…") { manager.perform(.save, id: id) }
                        Button("打印…") { manager.perform(.printImage, id: id) }
                        Divider()
                        Button(manager.record(id)?.locked == true ? "解锁" : "锁定") { manager.toggle(id, \.locked) }
                        Button(manager.record(id)?.floating == true ? "取消置顶" : "置顶") { manager.toggle(id, \.floating) }
                        Button("切换阴影") { manager.toggle(id, \.shadow) }
                        Button("恢复原始大小与透明度") { manager.resetSize(id) }
                        Button("鼠标穿透") { manager.toggle(id, \.clickThrough) }
                        Button("隐藏其他贴图") { manager.perform(.pinOthers, id: id) }
                        Divider()
                        Button("关闭所选贴图") { manager.closeSelection(id) }
                        Button("移到废纸篓", role: .destructive) { manager.selection(id).forEach { manager.remove($0) } }
                    }
            }
        }
        .overlay { if manager.selectedIDs.count > 1 && manager.selectedIDs.contains(id) { Rectangle().strokeBorder(.blue,lineWidth:3).allowsHitTesting(false) } }
        .background(CaptureShortcutMonitor(scope: .pin) { manager.perform($0, id: id) }.frame(width: 0, height: 0))
    }
}


struct CapturePinsView: View {
    @Environment(\.pluginContentHasInsets) private var hasInsets
    @ObservedObject var manager: CapturePinManager
    var body: some View {
        let records = manager.records
        let selected = records.filter { manager.selectedIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(selected.isEmpty ? "\(records.count) 项" : "已选 \(selected.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !selected.isEmpty {
                    Menu("所选贴图") {
                        Button("恢复所选") {
                            for record in selected where !record.isOpen { manager.restore(record.id) }
                        }
                        .disabled(!manager.isAllowed() || selected.allSatisfy(\.isOpen))
                        if let open = selected.first(where: \.isOpen) {
                            Button("关闭所选") { manager.closeSelection(open.id) }
                        }
                        Divider()
                        Button("取消选择") { manager.selectedIDs.removeAll() }
                    }
                }
            }
            .panelRegion("capture.pins.toolbar")
            if records.isEmpty {
                ContentUnavailableView("还没有贴图", systemImage: "pin",
                    description: Text("截图框选后，在工具栏点「贴图」。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records.reversed()) { record in
                            pinRow(record)
                            if record.id != records.first?.id { Divider().opacity(0.65) }
                        }
                    }
                    .padding(.trailing, 12)
                }
            }
        }
        .padding(.horizontal, hasInsets ? 0 : PanelLayout.contentInset)
        .panelRegion("capture.pins")
    }

    private func pinRow(_ record: CapturePinRecord) -> some View {
        let title = record.sourceFile?.lastPathComponent ?? record.text.map { String($0.prefix(30)) } ?? "图像贴图"
        let action = record.isOpen ? "定位" : "恢复"
        return HStack(spacing: 10) {
            Toggle("选择 \(title)", isOn: Binding(
                get: { manager.selectedIDs.contains(record.id) },
                set: { _ in manager.select(record.id, extending: true) }
            ))
            .labelsHidden()
            Button {
                manager.restore(record.id)
            } label: {
                HStack(spacing: 10) {
                    CaptureThumbnail(url: manager.url(record), video: false, revision: record.revision)
                        .frame(width: 52, height: 36)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(record.isOpen ? "未关闭" : "已关闭 · 可恢复").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(record.date, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!manager.isAllowed())
            .help("\(action) \(title)")
            .accessibilityHint("\(action)这条贴图")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action) { manager.restore(record.id) }.disabled(!manager.isAllowed())
            if record.isOpen {
                Button("关闭") { manager.close(record.id) }
            }
            Divider()
            Button("移到废纸篓", role: .destructive) { manager.remove(record.id) }
        }
    }
}
