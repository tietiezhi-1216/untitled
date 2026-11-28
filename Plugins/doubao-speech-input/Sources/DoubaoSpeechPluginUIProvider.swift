import AppKit
import UntitledPluginSDK
import UntitledHost
import Combine
import SwiftUI

struct DoubaoSpeechPluginUIProvider: PluginUIProvider {
    let runtime: DoubaoSpeechPluginRuntime
    @MainActor func migrateBindings(in plugin: inout InstalledPlugin, to manifest: PluginManifest, occupiedHotKeys: Set<String>) {
        // Adopt the new default only for the original, untouched hold template. A
        // cleared, deleted, disabled or custom binding (including a side button) wins.
        let template = "doubao.hold", stock = "49:6656"
        guard plugin.id == DoubaoDictationController.pluginID, manifest.id == plugin.id,
              let old = Version(plugin.manifest.version), old < Version("1.2.4")!,
              let new = Version(manifest.version), new >= Version("1.2.4")!,
              plugin.manifest.templates.contains(where: { $0.id == template && $0.action == .holdDoubaoDictation && $0.defaultHotKey?.identity == stock }),
              manifest.templates.contains(where: { $0.id == template && $0.action == .holdDoubaoDictation && $0.defaultHotKey?.isRightCommand == true }),
              let index = plugin.commands.firstIndex(where: { $0.templateID == template && $0.action == .holdDoubaoDictation }),
              plugin.commands[index].isEnabled, plugin.commands[index].hotKey?.identity == stock,
              !occupiedHotKeys.contains(HotKey.rightCommand.identity),
              !plugin.commands.contains(where: { $0.hotKey?.isRightCommand == true }) else { return }
        plugin.commands[index].hotKey = .rightCommand
    }

    @MainActor func register(in registry: PluginUIRegistry) {
        registry.component("doubao.dictation", requiredActions: [.toggleDoubaoDictation]) { context in
            AnyView(DoubaoDictationView(controller: runtime.controller(for: context.pluginID, in: context.store)))
        }
        registry.component("doubao.preferences", requiredActions: [.toggleDoubaoDictation]) { context in
            AnyView(DoubaoDictationPreferencesView(controller: runtime.controller(for: context.pluginID, in: context.store)))
        }
        registry.command("doubao.toggle", requiredActions: [.toggleDoubaoDictation], presentation: { context in
            let controller = runtime.controller(for: context.pluginID, in: context.store)
            return .init(title: controller.isBusy ? "结束听写" : "开始听写", symbol: controller.isBusy ? "stop.circle" : "mic",
                         isEnabled: controller.phase != .finishing)
        }, updates: { runtime.controller(for: $0.pluginID, in: $0.store).objectWillChange.eraseToAnyPublisher() }) { context in
            try runtime.perform(.toggleDoubaoDictation, for: context.pluginID, in: context.store)
        }
        registry.command("doubao.cancel", requiredActions: [.cancelDoubaoDictation], presentation: { context in
            .init(title: "取消听写", symbol: "xmark.circle", isEnabled: runtime.controller(for: context.pluginID, in: context.store).isBusy)
        }, updates: { runtime.controller(for: $0.pluginID, in: $0.store).objectWillChange.eraseToAnyPublisher() }) { context in
            try runtime.perform(.cancelDoubaoDictation, for: context.pluginID, in: context.store)
        }
    }
}

private struct DoubaoDictationView: View {
    let controller: DoubaoDictationController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DictationSessionView(controller: controller, history: controller.history).modifier(DictationCard())
            DictationHistoryList(history: controller.history).modifier(DictationCard())
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task { await controller.history.load() }
    }
}

private struct DictationCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        content.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.06)).allowsHitTesting(false) }
    }
}

private struct DictationSessionView: View {
    @ObservedObject var controller: DoubaoDictationController
    @ObservedObject var history: DictationHistory
    @EnvironmentObject private var store: PluginStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("麦克风").font(.callout.weight(.medium))
                Spacer(minLength: 12)
                DictationMicrophonePicker(controller: controller)
            }
            if controller.isBusy {
                Divider()
                HStack(spacing: 8) {
                    Text(controller.statusTitle).font(.callout)
                    Spacer()
                    Button("取消") { controller.cancel() }
                        .help("定稿提交前也可按 Esc 取消本轮")
                    Button("结束听写") { controller.stopRecording() }
                        .buttonStyle(.borderedProminent).disabled(controller.phase == .finishing)
                }
            }
            let text = controller.resultText
            if !text.isEmpty && (controller.finalResultID == nil || controller.finalResultID != history.entries.first?.id) {
                Divider()
                HStack(alignment: .top) {
                    Text(text).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("复制") {
                        do { try DictationClipboard.write(text) } catch { store.handleExecutionError(error) }
                    }.controlSize(.small)
                }
            }
            if !controller.notice.isEmpty {
                Text(controller.notice).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DictationHistoryList: View {
    @ObservedObject var history: DictationHistory
    @EnvironmentObject private var store: PluginStore
    @ViewState private var copying: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别历史").font(.headline).accessibilityAddTraits(.isHeader)
            if let issue = history.issue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
            if !history.entries.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.entries) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(entry.preview).lineLimit(2).textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                                Button("复制") {
                                    guard copying == nil else { return }
                                    copying = entry.id
                                    Task {
                                        defer { copying = nil }
                                        do { try await DictationClipboard.copy(entry.id, from: history) }
                                        catch { store.handleExecutionError(error) }
                                    }
                                }
                                .controlSize(.small).disabled(copying != nil)
                                .accessibilityHint("复制这条记录的完整文字")
                            }.padding(.vertical, 8)
                            if entry.id != history.entries.last?.id { Divider() }
                        }
                    }
                }
            } else if history.isLoaded && history.issue == nil {
                Text(history.limit == 0 ? "不保留历史记录" : "暂无识别记录")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor enum DictationClipboard {
    static func copy(_ id: UUID, from history: DictationHistory, to board: NSPasteboard = .general) async throws {
        let text = try await history.text(for: id)
        try write(text, to: board)
    }

    /// Only an authoritative, undelivered result comes here. Prepare the plain-text item
    /// before claiming the board; do not read/save old data, synthesize Cmd-V, or retry.
    static func putFinal(_ text: String, on board: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= DoubaoASRLimits.textLength,
              item.setString(text, forType: .string),
              item.setData(Data(), forType: .init("org.nspasteboard.AutoGeneratedType")) else {
            throw PluginError.invalid("无法准备定稿剪贴板内容。")
        }
        let claim = board.prepareForNewContents(with: .currentHostOnly)
        guard board.changeCount == claim, board.writeObjects([item]) else { throw PluginError.invalid("剪贴板写入未确认。") }
    }
    static func write(_ text: String, to board: NSPasteboard = .general) throws {
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw PluginError.invalid("未能复制文字，请重试。") }
    }
}

private struct DoubaoDictationPreferencesView: View {
    @ObservedObject var controller: DoubaoDictationController
    @EnvironmentObject private var store: PluginStore

    var body: some View {
        Form {
            Section("听写") {
                Picker("单次最长", selection: Binding(get: { controller.preferences.maximumSeconds }, set: { value in
                    var settings = controller.preferences; settings.maximumSeconds = value; save(settings)
                })) {
                    Text("30 秒").tag(30); Text("1 分钟").tag(60)
                    Text("3 分钟").tag(180); Text("5 分钟").tag(300)
                }
            }.disabled(controller.isBusy)
            DictationHistorySettings(history: controller.history, clearCurrent: controller.clearResult)
                .disabled(controller.isBusy)
            Section("麦克风") {
                LabeledContent("输入设备") { DictationMicrophonePicker(controller: controller) }
                if let audio = controller.audioDiagnostics {
                    DisclosureGroup("采集诊断") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("实际输入：\(audio.inputName)")
                            Text("采集 \(audio.capturedBytes) 字节 · 回调 \(audio.callbacks) 次 · ASR 更新 \(controller.recognitionUpdates) 次")
                            Text(audio.peakDBFS.map { String(format: "音量峰值 %.1f dBFS · 发送格式 %.0f Hz 单声道 PCM16", $0, audio.sampleRate) } ?? "尚无非零音量信号")
                            Text("无需先点输入框。结束时可安全插入就写入，否则复制定稿。")
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private func save(_ settings: DictationPreferences) {
        do { try controller.savePreferences(settings) } catch { store.handleExecutionError(error) }
    }
}

private struct DictationHistorySettings: View {
    @ObservedObject var history: DictationHistory
    let clearCurrent: () -> Void
    @EnvironmentObject private var store: PluginStore
    @ViewState private var draft = ""
    @ViewState private var saving = false
    @ViewState private var confirmClear = false

    private var proposed: Int? {
        guard let count = Int(draft), DictationHistory.limits.contains(count) else { return nil }
        return count
    }

    var body: some View {
        Section("识别历史") {
            LabeledContent("保留最近") {
                HStack(spacing: 6) {
                    TextField("历史保留条数", text: $draft).labelsHidden().textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 58)
                        .accessibilityLabel("历史保留条数").onSubmit { save() }
                    Text("条")
                    Button("保存") { save() }.disabled(proposed == nil || proposed == history.limit)
                }
            }
            HStack {
                Text("仅保存在本机。可设 0–500 条，调低会删除较早记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空历史…") { confirmClear = true }.disabled(history.entries.isEmpty)
            }
            if let issue = history.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(saving || !history.isLoaded)
        .onChange(of: history.limit, initial: true) { _, value in draft = String(value) }
        .task { await history.load() }
        .confirmationDialog("清空全部识别历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空历史", role: .destructive) {
                saving = true
                Task {
                    defer { saving = false }
                    do { try await history.clear(); clearCurrent() } catch { store.handleExecutionError(error) }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func save() {
        guard !saving, let count = proposed, count != history.limit else { return }
        saving = true
        Task {
            defer { saving = false; draft = String(history.limit) }
            do { try await history.setLimit(count) } catch { store.handleExecutionError(error) }
        }
    }
}

private struct DictationMicrophonePicker: View {
    @ObservedObject var controller: DoubaoDictationController
    @EnvironmentObject private var store: PluginStore
    @ViewState private var devices: [DictationInputDevice] = []
    @ViewState private var defaultName = "未发现输入设备"
    var body: some View {
        Menu {
            Picker("麦克风", selection: selection) {
                Text("系统默认 · " + defaultName).tag("")
                ForEach(devices) { device in
                    Text(device.name + (device.isVirtual ? "（虚拟/聚合）" : "")).tag(device.id)
                }
                if let uid = controller.preferences.inputDeviceUID, !devices.contains(where: { $0.id == uid }) {
                    Text("设备已断开").tag(uid)
                }
            }.pickerStyle(.inline).labelsHidden()
            Divider()
            Button("刷新设备列表", action: refresh)
        } label: {
            Text(selectedName).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 168, alignment: .trailing).disabled(controller.isBusy)
        .accessibilityLabel("麦克风").accessibilityValue(selectedName)
        .help(selectedName)
        .onAppear { refresh() }
        .onChange(of: controller.preferences.inputDeviceUID) { _, uid in
            if let uid, !devices.contains(where: { $0.id == uid }) { refresh() }
        }
    }

    private var selection: Binding<String> {
        Binding(get: { controller.preferences.inputDeviceUID ?? "" }, set: { uid in
            var settings = controller.preferences
            settings.inputDeviceUID = uid.isEmpty ? nil : uid
            do { try controller.savePreferences(settings) } catch { store.handleExecutionError(error) }
        })
    }

    private var selectedName: String {
        guard let uid = controller.preferences.inputDeviceUID else { return "系统默认 · " + defaultName }
        return devices.first(where: { $0.id == uid })?.name ?? "设备已断开"
    }

    private func refresh() {
        let value = DictationInputDevices.snapshot()
        devices = value.devices
        defaultName = value.devices.first(where: { $0.id == value.defaultUID })?.name ?? "不可用，请选择其他设备"
    }
}
