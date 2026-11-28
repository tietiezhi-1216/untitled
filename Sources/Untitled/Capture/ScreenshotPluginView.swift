import AppKit
import ImageIO
import SwiftUI

struct CaptureHistorySection: Identifiable {
    let day: Date
    let records: [CaptureRecord]
    var id: Date { day }

    static func group(_ records: [CaptureRecord], calendar: Calendar) -> [Self] {
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        return byDay.map { Self(day: $0.key, records: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

struct CaptureHistoryView: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.pluginContentHasInsets) private var hasInsets
    @Environment(\.pluginTrailingScrollGutter) private var scrollGutter
    @Environment(\.calendar) private var calendar
    let pluginID: String
    @ObservedObject var capture: ScreenshotController
    let showSummary: Bool

    private let columns = [GridItem(.adaptive(minimum: 182), spacing: 14, alignment: .top)]
    private var enabled: Bool { store.installed.first { $0.id == pluginID }?.isEnabled == true }
    private var inset: CGFloat { hasInsets ? 0 : PanelLayout.contentInset }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showSummary {
                HStack {
                    Text("历史记录").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !capture.history.isEmpty {
                        CaptureStatusView(capture: capture)
                    }
                }
                .panelRegion("capture.history.summary")
                .padding(.leading, inset)
                .padding(.trailing, inset + scrollGutter)
            }
            if let notice = capture.notice {
                HStack(spacing: 10) {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        capture.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("关闭提示")
                    .accessibilityLabel("关闭提示")
                }
                .padding(.leading, inset)
                .padding(.trailing, inset + scrollGutter)
            }
            if capture.history.isEmpty {
                ContentUnavailableView(
                    "还没有截图", systemImage: "photo.on.rectangle",
                    description: Text("从右上角的截图菜单开始截图，或导入一张图片。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, scrollGutter)
            } else {
                PanelGalleryScroll(leadingInset: inset, trailingInset: inset + scrollGutter) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(CaptureHistorySection.group(capture.history, calendar: calendar)) { group in
                            Section {
                                ForEach(group.records) { record in historyCard(record) }
                            } header: {
                                dayHeading(group.day)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .panelRegion("capture.history.gallery")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelRegion("capture.history")
    }

    private func dayHeading(_ date: Date) -> some View {
        Group {
            if calendar.isDateInToday(date) { Text("今天") }
            else if calendar.isDateInYesterday(date) { Text("昨天") }
            else { Text(date, format: .dateTime.year().month().day()) }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityAddTraits(.isHeader)
    }

    private func historyCard(_ record: CaptureRecord) -> some View {
        let description = record.isVideo ? "录屏" : "\(record.width) × \(record.height)"
        return Button {
            capture.open(record)
        } label: {
            VStack(spacing: 0) {
                // The preview takes the space left by the metadata row.
                Color.primary.opacity(0.04)
                    .overlay {
                        CaptureThumbnail(url: capture.url(record), video: record.isVideo, revision: record.revision ?? record.id)
                    }
                    .clipped()
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Image(systemName: record.isVideo ? "video" : "photo")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(description).fontWeight(.medium).monospacedDigit()
                    Spacer(minLength: 4)
                    Text(record.date, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
                .panelRegion("capture.history.metadata.\(record.id.uuidString)")
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
        }
        .buttonStyle(CaptureHistoryCardStyle())
        .disabled(!enabled)
        .accessibilityLabel(Text(record.isVideo ? "打开录屏" : "打开截图，\(description)"))
        .accessibilityValue(Text(record.date, format: .dateTime.year().month().day().hour().minute()))
        .contextMenu {
            Button("打开") { capture.open(record) }.disabled(!enabled)
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([capture.url(record)]) }
            Divider()
            Button("移到废纸篓", role: .destructive) { capture.remove(record) }
        }
        .panelRegion("capture.history.card.\(record.id.uuidString)")
    }
}

private struct CaptureHistoryCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast
        @ViewState private var hover = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10)
            configuration.label
                .foregroundStyle(.primary)
                .background(configuration.isPressed ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.025))
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(
                        hover && enabled ? Color.accentColor.opacity(0.60) : Color.primary.opacity(contrast == .increased ? 0.23 : 0.09)
                    ).allowsHitTesting(false)
                }
                .contentShape(shape)
                .onHover { hover = $0 }
        }
    }
}

struct CaptureStatusView: View {
    @ObservedObject var capture: ScreenshotController
    var body: some View {
        Text("\(capture.history.count) 项 · 仅保存在本机")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// One ImageIO decode at a time; views retain only their own downsampled image.
actor CaptureThumbnailLoader {
    static let shared = CaptureThumbnailLoader()
    static let maximumPixelSize = 480

    func image(at url: URL) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
    }
}

struct CaptureThumbnail: View {
    let url: URL
    let video: Bool
    let revision: UUID
    @ViewState private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: video ? "play.rectangle" : "photo")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: revision) {
            image = nil
            guard !video else { return }
            let thumbnail = await CaptureThumbnailLoader.shared.image(at: url)
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
        .onDisappear { image = nil }
    }
}

private struct CaptureHistoryRetentionSettings: View {
    @ObservedObject var capture: ScreenshotController
    @ViewState private var customDays = ""
    @ViewState private var showingCustom = false

    private var choices: [Int] {
        Set([1, 7, 14, 30, 90, 365, capture.historyRetentionDays]).filter { $0 > 0 }.sorted()
    }
    private var enteredDays: Int? {
        guard let days = Int(customDays.trimmingCharacters(in: .whitespacesAndNewlines)),
              CaptureHistoryRetention.customDays.contains(days) else { return nil }
        return days
    }

    var body: some View {
        Section("历史记录") {
            HStack {
                Picker("保留期限", selection: Binding(
                    get: { capture.historyRetentionDays },
                    set: { capture.setHistoryRetentionDays($0) }
                )) {
                    ForEach(choices, id: \.self) { Text("\($0) 天").tag($0) }
                    Text("不清理").tag(0)
                }
                Button("自定义…") {
                    customDays = String(capture.historyRetentionDays == 0 ? CaptureHistoryRetention.defaultDays : capture.historyRetentionDays)
                    showingCustom = true
                }
            }
            .panelRegion("capture.settings.historyRetention")
            Text("过期的截图和录屏会移到废纸篓，不影响贴图和已导出的文件。")
                .font(.caption).foregroundStyle(.secondary)
            if let date = capture.historyRetentionGraceEnds, date > Date() {
                Text("升级前的历史至少保留到 \(date.formatted(date: .abbreviated, time: .shortened))。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let warning = capture.historyCleanupWarning {
                Text(warning).font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("自定义历史保留期限", isPresented: $showingCustom) {
            TextField("天数", text: $customDays)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let days = enteredDays { capture.setHistoryRetentionDays(days) }
            }.disabled(enteredDays == nil)
        } message: {
            Text("输入 1–3650 天。应用运行时会按新期限清理历史。")
        }
    }
}

struct ScreenshotSettingsView: View {
    @ObservedObject var mouse: CaptureGlobalMouse
    let capture: ScreenshotController
    var showLocalShortcuts = true
    @AppStorage("capture.systemAudio") private var systemAudio = false
    @AppStorage("capture.microphone") private var microphone = false
    @AppStorage("capture.cursor") private var cursor = true
    @AppStorage("capture.camera") private var camera = false
    @AppStorage("capture.keystrokes") private var keystrokes = false
    @AppStorage("capture.scrollAxis") private var axis = StitchAxis.vertical.rawValue
    @ViewState private var ai = CaptureAISettings.current
    @ViewState private var key = ""
    @ViewState private var message: String?
    var body: some View {
        Form {
            CaptureHistoryRetentionSettings(capture: capture)
            if showLocalShortcuts {
                Section("快捷键") {
                    DisclosureGroup("编辑与贴图快捷键") { CaptureLocalShortcutSettingsView() }
                }
            }
            Section("滚动长截图") {
                Picker("快捷键默认方向", selection: $axis) {
                    ForEach(StitchAxis.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("选定区域后缓慢滚动；支持两个方向前进或回滚。自动滚动所需的辅助功能权限由主应用统一申请。")
                    .font(.caption).foregroundStyle(.secondary)

            }
            Section("录屏") {
                RecordingPreferencesView()
                Toggle("录制系统音频", isOn: $systemAudio)
                Toggle("录制麦克风", isOn: $microphone)
                Toggle("显示鼠标和点击效果", isOn: $cursor)
                Toggle("摄像头画中画", isOn: $camera)
                Toggle("显示键盘按键", isOn: $keystrokes)
                Text("所需的系统权限由主应用统一申请。画中画与按键显示仅在录屏期间启用，系统安全输入时暂停显示按键。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("录屏需要 macOS 15+；停止后可编辑画面、键鼠效果与声音，导出 MP4、GIF 或 WebP。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("恢复中断的录屏") {
                    RecordingRecoveryView(directory: capture.directory, recovered: capture.importRecoveredRecording)
                }
            }
            Section("贴图与鼠标") {
                DisclosureGroup("贴图偏好与鼠标操作") { CapturePinSettingsView() }
                DisclosureGroup("全局鼠标截图") { CaptureGlobalMouseSettingsView(mouse: mouse) }
            }
            CaptureOutputSettingsView()
            CaptureInpaintingSettingsView()
            Section("视觉模型（可选）") {
                TextField("HTTPS 接口", text: $ai.endpoint, prompt: Text("https://服务地址/v1/chat/completions"))
                TextField("视觉模型", text: $ai.model)
                SecureField("API 密钥", text: $key)
                Text("支持兼容 Chat Completions 的视觉模型。密钥存储在 macOS 钥匙串。只有你确认发送图片后才请求服务；本地 OCR、二维码和系统翻译不需要此配置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("保存服务配置") {
                        do {
                            if !ai.endpoint.isEmpty, ai.url == nil {
                                throw PluginError.invalid("请填写有效的 HTTPS 接口和模型名称。")
                            }
                            try CaptureKeychain.save(key)
                            CaptureAISettings.current = ai
                            message = "已保存"
                        } catch { message = error.localizedDescription }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = CaptureKeychain.read() }
    }
}
