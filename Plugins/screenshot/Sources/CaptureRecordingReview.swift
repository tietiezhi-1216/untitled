import AppKit
import UntitledPluginSDK
import UntitledHost
@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct RecordingPreferencesView: View {
    @AppStorage("capture.recordingFPS") private var fps = 30
    @AppStorage("capture.recordingMaximumEdge") private var edge = 4096
    @AppStorage("capture.cameraDevice") private var device = ""
    @AppStorage("capture.cameraCircle") private var circle = false
    @AppStorage("capture.cameraMirror") private var mirror = true
    @AppStorage("capture.recordingDelay") private var delay = 0
    @AppStorage("capture.secondCamera") private var secondCamera = false
    @AppStorage("capture.secondCameraDevice") private var secondDevice = ""
    @ViewState private var devices: [AVCaptureDevice] = []
    var body: some View {
        Picker("录制帧率", selection: $fps) { ForEach([5, 16, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) } }
        Picker("录制倒计时", selection: $delay) {
            Text("无延时").tag(0)
            ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) 秒").tag($0) }
        }
        Picker("最长边", selection: $edge) { ForEach([1280, 1920, 2560, 4096], id: \.self) { Text("\($0) px").tag($0) } }
        Picker("摄像头设备", selection: $device) {
            Text("系统默认").tag("")
            ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }.task { devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices }
        Toggle("圆形画中画", isOn: $circle)
        Toggle("镜像摄像头画面", isOn: $mirror)
        Toggle("第二个摄像头", isOn: $secondCamera)
        if secondCamera {
            Picker("第二摄像头设备", selection: $secondDevice) {
                Text("请选择").tag("")
                ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
        }
    }
}

struct CaptureRecordingPlaybackBar: View {
    @ObservedObject var playback: CaptureRecordingPlayback
    let copy: () -> Void
    let export: () -> Void
    let close: () -> Void
    @ViewState private var seekPosition: Double?
    @ViewState private var trim = false
    @ViewState private var adjustments = false

    var body: some View {
        HStack(spacing: 4) {
            let playing = playback.isPlaying
            button(playing ? "pause.fill" : "play.fill", title: playing ? "暂停播放" : "播放录屏") { playback.toggle() }
                .disabled(!playback.canEdit)
            progress
                .frame(maxWidth: .infinity)
            Divider().frame(height: 18).padding(.horizontal, 2)
            button("scissors", title: "裁剪时间…", active: trim) { trim.toggle() }
                .disabled(!playback.canEdit)
                .popover(isPresented: $trim, arrowEdge: .bottom) { trimControls }
            button(playback.cropping ? "checkmark" : "crop", title: playback.cropping ? "确认画面裁剪" : "裁剪画面",
                   active: playback.cropping) { playback.toggleCrop() }
                .contextMenu {
                    Button("恢复完整画面") { playback.resetCrop() }.disabled(!playback.canEdit)
                    if playback.cropping { Button("取消裁剪") { playback.cancelCrop() } }
                }
                .disabled(!playback.canEdit)
            button("slider.horizontal.3", title: "倍速、声音与导出设置…", active: adjustments) { adjustments.toggle() }
                .disabled(!playback.canEdit)
                .popover(isPresented: $adjustments, arrowEdge: .bottom) { adjustmentControls }
            button("doc.on.doc", title: "复制视频并关闭（⌃C／⌘C）", prominent: true, perform: copy)
                .disabled(!playback.canEdit)
            button("square.and.arrow.down", title: "导出 \(playback.format.label)…", perform: export)
                .disabled(!playback.canEdit)
            button("xmark", title: "关闭预览（原片已保存）", perform: close)
        }
        .modifier(CaptureRecordingBarStyle())
        .panelRegion("capture.recording.review.toolbar")
        .task(id: playback.feedback) {
            guard let message = playback.feedback, message.hasPrefix("已") else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if playback.feedback == message { playback.clearFeedback() }
        }
    }

    @ViewBuilder private var progress: some View {
        if let work = playback.work, work != .choosingDestination {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(work == .copying ? "正在复制…" : work == .exporting ? "正在导出…" : "准备预览…").lineLimit(1)
            }.foregroundStyle(.secondary)
        } else if let error = playback.error {
            Text(error).lineLimit(1).foregroundStyle(.secondary).help(error)
        } else if let feedback = playback.feedback {
            Button { playback.clearFeedback() } label: {
                Text(feedback).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary).help(feedback).accessibilityHint("点击返回播放进度")
        } else if playback.cropping {
            Text("拖动框选保留区域").lineLimit(1).foregroundStyle(.secondary)
        } else {
            let range = playback.timeline
            HStack(spacing: 4) {
                Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, seekPosition ?? playback.position)) },
                    set: { value in
                        if seekPosition != nil { seekPosition = value } else { playback.seek(value) }
                    }), in: range, onEditingChanged: { editing in
                        if editing { playback.pause(); seekPosition = playback.position }
                        else if let position = seekPosition { seekPosition = nil; playback.seek(position) }
                    })
                    .controlSize(.small).accessibilityLabel("播放进度").disabled(playback.duration <= 0)
                Text(Duration.seconds(seekPosition ?? playback.position).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    .help(playback.dimensions)
            }
        }
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("截取时间段").font(.headline)
            // Explicit setters avoid a Swift 6.3 IRGen crash when Binding
            // reabstracts an actor-isolated method reference.
            trimRow("起点", value: Binding(get: { playback.edit.start }, set: { playback.setStart($0) }))
            trimRow("终点", value: Binding(get: { playback.edit.end }, set: { playback.setEnd($0) }))
            HStack {
                Button("恢复完整时长") { playback.resetTrim() }
                Spacer()
                Button("预览选段") { trim = false; playback.preview(autoplay: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14).frame(width: 310)
    }

    private func trimRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).fixedSize()
            Slider(value: value, in: 0...max(0.01, playback.duration)).accessibilityLabel(title)
            Text("\(value.wrappedValue, specifier: "%.2f") s").monospacedDigit().frame(width: 62, alignment: .trailing)
        }
    }

    private var adjustmentControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("录屏调整").font(.headline)
                Spacer()
                Text(playback.dimensions).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("原片分辨率 \(playback.dimensions)")
            }
            Picker("播放倍速", selection: $playback.edit.options.speed) {
                ForEach([0.2, 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
            }
            if playback.audioStems.isEmpty {
                volume("音量", value: $playback.edit.options.volume)
            } else {
                if playback.audioStems.contains("system") { volume("系统音频", value: $playback.edit.options.systemVolume) }
                if playback.audioStems.contains("microphone") { volume("麦克风", value: $playback.edit.options.microphoneVolume) }
            }
            if playback.hasEvents { RecordingReviewEffects(options: $playback.edit.options.effects) }
            Divider()
            Picker("导出格式", selection: $playback.format) {
                ForEach(RecordingReviewFormat.allCases.filter { $0 != .webp || RecordingExporter.webPEncoder != nil }) {
                    Text($0.label).tag($0)
                }
            }
            if playback.format != .mp4 {
                Picker("动图帧率", selection: $playback.edit.options.fps) {
                    ForEach([5, 10, 15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("动图最长边", selection: $playback.edit.options.maximumEdge) {
                    ForEach([640, 960, 1280, 1920, 2560], id: \.self) { Text("\($0) px").tag($0) }
                }
            }
            if playback.format != .gif {
                Picker("导出画质", selection: $playback.edit.options.quality) {
                    Text("轻量").tag(30.0); Text("标准").tag(60.0); Text("高").tag(90.0)
                }
            }
            HStack {
                Button("重置调整") { playback.resetEdits() }
                Spacer()
                Button("应用到预览") { adjustments = false; playback.preview(autoplay: false) }
                    .buttonStyle(.borderedProminent)
            }
            Button("在访达中显示原片") { NSWorkspace.shared.activateFileViewerSelecting([playback.url]) }
                .buttonStyle(.link)
        }
        .padding(14).frame(width: 320)
    }

    private func volume(_ title: String, value: Binding<Float>) -> some View {
        HStack {
            Text(title).fixedSize()
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }), in: 0...2)
                .accessibilityLabel(title)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private func button(_ symbol: String, title: String, active: Bool = false, prominent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .modifier(CaptureToolbarControl(hint: title, selected: active, prominent: prominent))
        .accessibilityLabel(title)
    }
}

private struct RecordingReviewEffects: View {
    @Binding var options: RecordingEffectOptions
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup("光标、点击与按键效果", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("光标", isOn: $options.cursor)
                    Toggle("点击／滚轮", isOn: $options.clicks)
                    Toggle("按键", isOn: $options.keys)
                }
                if options.cursor { slider("光标大小", value: $options.cursorScale, in: 0.5...2) }
                if options.clicks { slider("点击大小", value: $options.clickScale, in: 0.5...2) }
                if options.keys || options.clicks {
                    slider("字号", value: $options.keySize, in: 16...48)
                    Picker("背景", selection: $options.background) {
                        Text("深色").tag("dark"); Text("浅色").tag("light"); Text("蓝色").tag("blue")
                    }
                }
                if options.keys { slider("持续秒数", value: $options.keyDuration, in: 0.5...4) }
            }.padding(.top, 6)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).fixedSize()
            Slider(value: value, in: range).accessibilityLabel(title)
            Text("\(value.wrappedValue, specifier: "%.1f")").monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
}

struct CaptureRecordingCropOverlay: View {
    @ObservedObject var playback: CaptureRecordingPlayback

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let crop = playback.edit.options.crop
            let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                              width: crop.width * size.width, height: crop.height * size.height)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(.black.opacity(0.28), style: FillStyle(eoFill: true))
            .overlay {
                Path { $0.addRect(rect) }.stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let a = value.startLocation, b = value.location
                let x = min(1, max(0, min(a.x, b.x) / size.width)), y = min(1, max(0, min(a.y, b.y) / size.height))
                let right = min(1, max(0, max(a.x, b.x) / size.width)), bottom = min(1, max(0, max(a.y, b.y) / size.height))
                if right - x >= 0.02, bottom - y >= 0.02 {
                    playback.edit.options.crop = CGRect(x: x, y: y, width: right - x, height: bottom - y)
                }
            })
        }
        .accessibilityLabel("拖动选择保留的画面")
    }
}
