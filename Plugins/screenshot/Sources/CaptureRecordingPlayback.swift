import AppKit
import UntitledPluginSDK
@preconcurrency import AVFoundation
import Combine
import UniformTypeIdentifiers

enum RecordingReviewFormat: String, CaseIterable, Identifiable {
    case mp4, gif, webp
    var id: Self { self }
    var label: String { self == .webp ? "WebP" : rawValue.uppercased() }
    var contentType: UTType {
        switch self {
        case .mp4: .mpeg4Movie
        case .gif: .gif
        case .webp: UTType(filenameExtension: rawValue) ?? .image
        }
    }
}

struct RecordingReviewEdit: Equatable {
    var start = 0.0
    var end = 0.0
    var options: RecordingEditOptions = {
        var options = RecordingEditOptions()
        options.quality = 90
        options.effects = RecordingEffectOptions(cursor: false, clicks: false, keys: false)
        return options
    }()

    func needsRendering(duration: Double) -> Bool {
        start > 0 || end < duration || options.crop != CGRect(x: 0, y: 0, width: 1, height: 1) || options.speed != 1 ||
            options.volume != 1 || options.systemVolume != 1 || options.microphoneVolume != 1 || options.effects.isEnabled
    }
}

/// One player and one in-flight preview or output. Edits are non-destructive;
/// the same snapshot of the settings is used for edited playback, copy and export.
@MainActor final class CaptureRecordingPlayback: ObservableObject {
    struct Media {
        let duration: Double
        let size: CGSize
        static func read(_ asset: AVAsset) async throws -> Self {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw PluginError.invalid("没有可播放的录屏片段。")
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let pixels = CGRect(origin: .zero, size: size).applying(transform).size
            guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0 else {
                throw PluginError.invalid("录屏尺寸无效。")
            }
            return Self(duration: duration, size: pixels)
        }
    }
    enum Work: Equatable { case preview, choosingDestination, exporting, copying }

    let url: URL
    let player = AVPlayer()
    @Published private(set) var duration = 0.0
    @Published private(set) var sourcePixels = CGSize.zero
    @Published private(set) var videoPixels = CGSize.zero
    @Published private(set) var position = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?
    @Published private(set) var feedback: String?
    @Published private(set) var work: Work?
    @Published private(set) var audioStems: [String] = []
    @Published private(set) var hasEvents = false
    @Published private(set) var cropping = false
    @Published var edit = RecordingReviewEdit()
    @Published var format = RecordingReviewFormat.mp4

    private var applied: RecordingReviewEdit?
    private var previousCrop: CGRect?
    private var timeObserver: Any?
    private var itemObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var loading: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private(set) var savePanel: NSSavePanel?
    private var closed = false

    var canEdit: Bool { !closed && duration > 0 && error == nil && work == nil }
    var timeline: ClosedRange<Double> { (applied?.start ?? 0)...(applied?.end ?? max(0.01, duration)) }
    var dimensions: String {
        guard sourcePixels.width > 0 else { return "" }
        return "\(Int(sourcePixels.width.rounded())) × \(Int(sourcePixels.height.rounded())) px"
    }

    init(url: URL) {
        self.url = url
        let asset = AVURLAsset(url: url)
        install(AVPlayerItem(asset: asset), edit: nil)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.isPlaying, time.seconds.isFinite else { return }
                let seconds = self.applied.map { $0.start + time.seconds * $0.options.speed } ?? time.seconds
                self.position = min(self.timeline.upperBound, max(self.timeline.lowerBound, seconds))
            }
        }
        loading = Task { [weak self] in
            do {
                let media = try await Media.read(asset)
                guard !Task.isCancelled, self?.closed == false else { return }
                self?.sourcePixels = media.size
                self?.videoPixels = media.size
                let stems = await RecordingAudioStems.validatedNames(for: url)
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.audioStems = stems
                self.hasEvents = RecordingEventArchive.read(for: url)?.events.isEmpty == false
                self.edit.end = media.duration
                self.duration = media.duration
            } catch {
                if !Task.isCancelled { self?.error = error.localizedDescription }
            }
        }
    }

    func toggle() {
        if isPlaying { pause(); return }
        guard canEdit else { return }
        preview(autoplay: true)
    }

    func pause() { player.pause(); isPlaying = false }

    func seek(_ seconds: Double) {
        guard !closed, seconds.isFinite, duration > 0 else { return }
        position = min(timeline.upperBound, max(timeline.lowerBound, seconds))
        let time = applied.map { (position - $0.start) / $0.options.speed } ?? position
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStart(_ seconds: Double) {
        guard canEdit, seconds.isFinite else { return }
        edit.start = max(0, min(edit.end - min(duration, 0.01), seconds))
        showSource(at: edit.start)
    }

    func setEnd(_ seconds: Double) {
        guard canEdit, seconds.isFinite else { return }
        edit.end = min(duration, max(edit.start + min(duration, 0.01), seconds))
        showSource(at: edit.end)
    }

    func toggleCrop() {
        guard canEdit else { return }
        if cropping { preview(autoplay: false) }
        else {
            previousCrop = edit.options.crop
            showSource(at: position)
            cropping = true
        }
    }

    func cancelCrop() {
        if let previousCrop { edit.options.crop = previousCrop }
        previousCrop = nil; cropping = false
        preview(autoplay: false)
    }

    func resetCrop() {
        guard canEdit else { return }
        edit.options.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if !cropping { preview(autoplay: false) }
    }

    func resetTrim() {
        guard canEdit else { return }
        edit.start = 0; edit.end = duration
        showSource(at: position)
    }

    func clearFeedback() { feedback = nil }

    func resetEdits() {
        guard canEdit else { return }
        previousCrop = nil; cropping = false
        edit = RecordingReviewEdit(end: duration)
        showSource(at: position)
    }

    func preview(autoplay: Bool) {
        guard canEdit else { return }
        previousCrop = nil; cropping = false
        let snapshot = edit
        let seekTo = position >= snapshot.end ? snapshot.start : max(snapshot.start, position)
        if !snapshot.needsRendering(duration: duration) {
            if applied != nil { showSource(at: seekTo) }
            else if position >= duration { seek(0) }
            if autoplay { player.play(); isPlaying = true }
        } else if applied == snapshot {
            if position >= snapshot.end { seek(snapshot.start) }
            if autoplay { player.play(); isPlaying = true }
        } else {
            pause()
            let url = url
            begin(.preview) { [weak self] in
                let result = try await RecordingExporter.prepare(from: url, start: snapshot.start, end: snapshot.end, options: snapshot.options)
                try Task.checkCancellation()
                guard let self, !closed else { return }
                let item = AVPlayerItem(asset: result.asset)
                item.videoComposition = result.video; item.audioMix = result.audio
                item.audioTimePitchAlgorithm = .timeDomain
                videoPixels = result.video.renderSize
                install(item, edit: snapshot)
                seek(seekTo)
                if autoplay { player.play(); isPlaying = true }
            }
        }
    }

    private func showSource(at position: Double) {
        pause()
        if applied != nil {
            videoPixels = sourcePixels
            install(AVPlayerItem(url: url), edit: nil)
        }
        seek(position)
    }

    private func install(_ item: AVPlayerItem, edit: RecordingReviewEdit?) {
        if let itemObserver { NotificationCenter.default.removeObserver(itemObserver) }
        statusObservation?.invalidate()
        player.currentItem?.cancelPendingSeeks()
        applied = edit
        player.replaceCurrentItem(with: item)
        let identifier = ObjectIdentifier(item)
        itemObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                               object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.player.currentItem.map(ObjectIdentifier.init) == identifier else { return }
                self.isPlaying = false
                self.position = self.timeline.upperBound
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, change in
            guard change.newValue == .failed else { return }
            let id = ObjectIdentifier(item)
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.player.currentItem.map(ObjectIdentifier.init) == id else { return }
                self.pause()
                if self.applied != nil {
                    self.feedback = "调整后的画面无法预览，已返回原片。"
                    self.showSource(at: self.position)
                } else { self.error = "无法播放录屏。" }
            }
        }
    }

    func copy(to pasteboard: NSPasteboard = .general, cache: URL = RecordingClipboard.directory,
              onCopied: @escaping @MainActor () -> Void) {
        guard canEdit else { return }
        feedback = nil
        let snapshot = edit, source = url
        if !snapshot.needsRendering(duration: duration) {
            guard RecordingClipboard.writeFile(source, to: pasteboard) else {
                feedback = "复制失败，请重试。"
                return
            }
            onCopied()
            return
        }
        let generation = pasteboard.changeCount
        begin(.copying) { [weak self] in
            let folder = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var published = false
            defer { if !published { try? FileManager.default.removeItem(at: folder) } }
            let target = folder.appendingPathComponent("录屏.mp4")
            try await RecordingExporter.movie(from: source, to: target, start: snapshot.start, end: snapshot.end, options: snapshot.options)
            try Task.checkCancellation()
            guard let self, !closed else { return }
            guard pasteboard.changeCount == generation else {
                feedback = "剪贴板已变化，未覆盖较新的内容。"
                return
            }
            guard RecordingClipboard.writeFile(target, to: pasteboard) else { throw PluginError.invalid("复制失败，请重试。") }
            published = true
            RecordingClipboard.prune(cache, keeping: folder)
            onCopied()
        }
    }

    func chooseExportDestination(above window: NSWindow,
                                 present: (NSSavePanel, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void = { panel, complete in
                                     panel.begin { result in MainActor.assumeIsolated { complete(result) } }
                                 }) {
        guard canEdit, savePanel == nil else { return }
        pause()
        let panel = NSSavePanel()
        let format = format
        let snapshot = edit
        let raw = format == .mp4 && !snapshot.needsRendering(duration: duration) && snapshot.options.quality >= 80
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "录屏.\(format.rawValue)"
        panel.canCreateDirectories = true
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        CaptureWindowPolicy.markControl(panel, name: "recordingExportDestination")
        savePanel = panel; work = .choosingDestination
        present(panel) { [weak self, weak panel] result in
            guard let self, !closed else { return }
            let target = panel?.url
            savePanel = nil; work = nil
            guard result == .OK, let target else { return }
            export(to: target, format: format, edit: snapshot, original: raw)
        }
    }

    func export(to target: URL, format: RecordingReviewFormat) {
        let original = format == .mp4 && !edit.needsRendering(duration: duration) && edit.options.quality >= 80
        export(to: target, format: format, edit: edit, original: original)
    }

    private func export(to target: URL, format: RecordingReviewFormat, edit: RecordingReviewEdit, original: Bool) {
        guard canEdit else { return }
        guard target.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL else {
            feedback = "请选择其他位置，录屏原件不会被覆盖。"
            return
        }
        let source = url
        pause()
        begin(.exporting) { [weak self] in
            if original { try await RecordingExporter.publishFile(source, to: target) }
            else if format == .mp4 { try await RecordingExporter.movie(from: source, to: target, start: edit.start, end: edit.end, options: edit.options) }
            else { try await RecordingExporter.animation(from: source, to: target, start: edit.start, end: edit.end, options: edit.options, webP: format == .webp) }
            self?.feedback = "已导出 \(target.lastPathComponent)"
        }
    }

    private func begin(_ kind: Work, perform: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        feedback = nil; work = kind
        operation = Task { [weak self] in
            defer { self?.operation = nil; self?.work = nil }
            do { try await perform() }
            catch is CancellationError {}
            catch { if !Task.isCancelled { self?.feedback = error.localizedDescription } }
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        pause(); loading?.cancel(); loading = nil
        operation?.cancel(); savePanel?.cancel(nil); savePanel = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let itemObserver { NotificationCenter.default.removeObserver(itemObserver); self.itemObserver = nil }
        statusObservation?.invalidate(); statusObservation = nil
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }
}

/// Use the native file pasteboard type rather than buffering a movie as Data or
/// leaving a promise dependent on a window or encoder remaining alive.
@MainActor enum RecordingClipboard {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.untitled.app/RecordingClipboard", isDirectory: true)
    }

    static func writeFile(_ url: URL, to pasteboard: NSPasteboard) -> Bool {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return false }
        let file = url as NSURL
        pasteboard.clearContents()
        return pasteboard.writeObjects([file])
    }

    static func prune(_ directory: URL, keeping latest: URL) {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        let older = entries.compactMap { entry -> (URL, Date)? in
            guard entry != latest, UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]), values.isDirectory == true else { return nil }
            return (entry, values.creationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in older.enumerated() where index >= 7 || entry.1.timeIntervalSinceNow < -2 * 86400 {
            try? manager.removeItem(at: entry.0)
        }
    }
}
