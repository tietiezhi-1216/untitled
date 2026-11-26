import Combine
import Foundation

struct DictationPreferences: Codable, Equatable, Sendable {
    var maximumSeconds: Int
    var inputDeviceUID: String?
    init(maximumSeconds: Int = 180, inputDeviceUID: String? = nil) {
        self.maximumSeconds = maximumSeconds; self.inputDeviceUID = inputDeviceUID
    }
    // Ignore obsolete input-mode switches in older preferences.
    private enum CodingKeys: String, CodingKey { case maximumSeconds, inputDeviceUID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maximumSeconds = try values.decodeIfPresent(Int.self, forKey: .maximumSeconds) ?? 180
        inputDeviceUID = try values.decodeIfPresent(String.self, forKey: .inputDeviceUID)
    }
    func validate() throws {
        guard (30...DoubaoASRLimits.maximumSeconds).contains(maximumSeconds) else {
            throw PluginError.invalid("单次听写上限须为 30–300 秒。")
        }
        if let inputDeviceUID {
            guard !inputDeviceUID.isEmpty, inputDeviceUID.utf8.count <= 1024,
                  !inputDeviceUID.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw PluginError.invalid("麦克风选择无效，请重新选择输入设备。")
            }
        }
    }
}

enum DictationGesture: Equatable { case toggle, hold(UUID) }
enum DictationPhase: String { case idle, connecting, listening, finishing
    var title: String {
        switch self {
        case .idle: "准备就绪"
        case .connecting: "正在连接"
        case .listening: "正在聆听"
        case .finishing: "正在定稿"
        }
    }
}

@MainActor final class DoubaoDictationController: ObservableObject {
    static let pluginID = "com.untitled.doubao-speech-input"
    let history: DictationHistory
    private(set) var finalResultID: UUID?
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var captionSlice = DictationCaptionSlice("")
    var bubblePreview: String { captionSlice.summary }
    @Published private(set) var lastResult = ""
    @Published private(set) var notice = ""
    // Only the waveform observes this channel: audio packets must not re-layout the caption or panel.
    let waveReadings = CurrentValueSubject<DictationMeterReading, Never>(.quiet)
    private var meterReader: Task<Void, Never>?
    @Published private(set) var seconds = 0
    @Published private(set) var acknowledgedTextLength = 0
    @Published private(set) var audioDiagnostics: DictationAudioDiagnostics?
    @Published private(set) var recognitionUpdates = 0
    @Published private(set) var preferences = DictationPreferences()
    var isBusy: Bool { phase != .idle }
    var statusTitle: String { phase == .finishing && finalTextToWrite != nil ? "正在更新输入框" : phase.title }
    var resultText: String { transcript.isEmpty ? lastResult : transcript }
    var isAllowed: () -> Bool = { false }
    var requirePermissions: (Set<HostPermissionID>) throws -> Void = { _ in throw PluginError.invalid("听写权限客户端尚未绑定。") }
    var hasInsertionAccess: () -> Bool = { false }
    var registerEscape: (DictationGesture, @escaping () -> Void) -> (() -> Void)? = { _, _ in nil }
    private var removeEscape: (() -> Void)?
    private let preferencesURL: URL?
    private let makeSession: () -> any DoubaoSpeechSession
    private let makeMicrophone: () -> any DictationAudioSource
    private let makeTarget: () throws -> any DictationFinalInserting
    private let copyFinal: (String) throws -> Void
    private let showsHUD: Bool
    private var session: (any DoubaoSpeechSession)?
    private var microphone: (any DictationAudioSource)?
    private var target: (any DictationFinalInserting)?
    private var hud: DictationHUD?, receipt: DictationHUD?
    private var receiptTimer: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var textWriter: Task<Void, Never>?
    private var generation: UUID?
    private var gesture: DictationGesture?
    private var finalTextToWrite: String?
    private var finalDeliveryWaiter: CheckedContinuation<Void, Never>?
    private var finishTimer: Task<Void, Never>?
    private let recognitionBudget: Duration, deliveryBudget: Duration
    isolated deinit { dismissReceipt(); releaseResources() }

    init(preferencesURL: URL? = nil, showsHUD: Bool = true,
         recognitionBudget: Duration = .seconds(18), deliveryBudget: Duration = .seconds(4),
         makeSession: @escaping () -> any DoubaoSpeechSession = { DoubaoASRClient() },
         makeMicrophone: @escaping () -> any DictationAudioSource = { DictationMicrophone() },
         makeTarget: @escaping () throws -> any DictationFinalInserting = { try DictationTextTarget.capture() },
         copyFinal: @escaping (String) throws -> Void = { try DictationClipboard.putFinal($0) }) {
        self.preferencesURL = preferencesURL; self.showsHUD = showsHUD
        self.recognitionBudget = recognitionBudget; self.deliveryBudget = deliveryBudget
        history = DictationHistory(preferencesURL: preferencesURL)
        self.makeSession = makeSession; self.makeMicrophone = makeMicrophone; self.makeTarget = makeTarget; self.copyFinal = copyFinal
        if let preferencesURL, FileManager.default.fileExists(atPath: preferencesURL.path) {
            do {
                let data = try Data(contentsOf: preferencesURL)
                guard data.count <= 4096 else { throw PluginError.invalid("听写设置文件过大。") }
                let value = try JSONDecoder().decode(DictationPreferences.self, from: data)
                try value.validate(); preferences = value
            } catch { notice = "听写设置无法读取，原文件已保留；可重新保存设置。" }
        }
    }

    func savePreferences(_ value: DictationPreferences) throws {
        guard !isBusy else { throw PluginError.invalid("请先结束听写，再修改设置。") }
        try value.validate()
        if let preferencesURL {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: preferencesURL, options: .atomic)
        }
        preferences = value
    }

    func toggle() throws {
        if isBusy { stopRecording() }
        else { try start(.toggle) }
    }
    func holdPressed(_ commandID: UUID) throws {
        guard !isBusy else { return }
        try start(.hold(commandID))
    }
    func holdReleased(_ commandID: UUID) {
        guard gesture == .hold(commandID) else { return }
        stopRecording()
    }

    func holdCancelled(_ commandID: UUID) {
        guard gesture == .hold(commandID) else { return }
        cancel(message: "按住说话已取消。")
    }

    private func start(_ gesture: DictationGesture) throws {
        guard isAllowed() else { throw PluginError.invalid("请先启用语音输入插件。") }
        dismissReceipt(); notice = ""
        // No editor/AX or clipboard access on start, during capture, or while waiting for ASR.
        do { try requirePermissions([.microphone]) }
        catch { notice = error.localizedDescription; throw error }
        let id = UUID(), session = makeSession(), microphone = makeMicrophone()
        // Capture immediately on the user's gesture, including a short utterance released
        // before networking is ready. Startup has its own strictly bounded PCM allowance.
        do {
            try microphone.configureInputDevice(preferences.inputDeviceUID)
            try microphone.start()
        } catch {
            audioDiagnostics = microphone.diagnostics
            microphone.stop(); session.cancel()
            notice = error.localizedDescription
            throw error
        }
        self.session = session; self.microphone = microphone
        audioDiagnostics = microphone.diagnostics; recognitionUpdates = 0
        generation = id; self.gesture = gesture
        transcript = ""; lastResult = ""; finalResultID = nil; captionSlice = DictationCaptionSlice("")
        seconds = 0; acknowledgedTextLength = 0; finalTextToWrite = nil
        phase = .connecting
        refreshEscapeShortcut()
        if let readings = microphone.meterReadings {
            meterReader = Task { [weak self] in
                for await reading in readings {
                    guard !Task.isCancelled, let self, self.generation == id,
                          self.phase == .connecting || self.phase == .listening else { return }
                    self.waveReadings.send(reading)
                }
            }
        }
        if showsHUD {
            let hud = DictationHUD()
            self.hud = hud; hud.show(controller: self)
        }
        session.onTranscript = { [weak self] text in
            guard let self, self.generation == id, self.finalTextToWrite == nil else { return }
            // Partials (also during EndASR) are display-only. Replace the prior hypothesis;
            // never enqueue a target write from a callback, a UI redraw or a microphone tick.
            self.display(text); self.recognitionUpdates += 1
        }
        session.onFailure = { [weak self] error in
            guard let self, self.generation == id, self.finalTextToWrite == nil else { return }
            self.cancel(message: error.localizedDescription)
        }
        let started = ProcessInfo.processInfo.systemUptime
        monitor = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, self.generation == id else { return }
                    if self.phase == .connecting || self.phase == .listening {
                        self.seconds = Int(ProcessInfo.processInfo.systemUptime - started)
                        try self.microphone?.validateBuffer()
                        if let microphone = self.microphone { self.refreshAudioDiagnostics(microphone) }
                        if self.seconds >= 5, let audio = self.audioDiagnostics, audio.capturedBytes == 0 {
                            throw PluginError.invalid(audio.emptyResultReason)
                        }
                        try self.requirePermissions([.microphone])
                    }
                    if self.seconds >= self.preferences.maximumSeconds { self.stopRecording() }
                }
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.cancel(message: error is HostPermissionError ? "权限已失效，听写已停止。" : error.localizedDescription)
            }
        }
        task = Task { [weak self] in await self?.run(id: id, session: session, microphone: microphone) }
    }

    private func run(id: UUID, session: any DoubaoSpeechSession, microphone: any DictationAudioSource) async {
        do {
            try await session.start()
            try Task.checkCancellation()
            guard generation == id, phase == .connecting || phase == .finishing, isAllowed() else { throw CancellationError() }
            let startup = try microphone.read()
            refreshAudioDiagnostics(microphone)
            microphone.setStreaming()
            try await transmit(startup.pcm, session: session)
            if phase == .connecting { phase = .listening }
            while phase == .listening {
                try Task.checkCancellation()
                guard generation == id, isAllowed() else { throw CancellationError() }
                let packet = try microphone.read()
                refreshAudioDiagnostics(microphone)
                try await transmit(packet.pcm, session: session)
                if phase == .listening { try await Task.sleep(for: .milliseconds(50)) }
            }
            try Task.checkCancellation()
            guard generation == id, phase == .finishing else { throw CancellationError() }
            // stopRecording() synchronously joined the input callback; flush bounded tail once.
            let tail = try microphone.read()
            refreshAudioDiagnostics(microphone)
            try await transmit(tail.pcm, session: session)
            let final = try await session.finish()
            try Task.checkCancellation()
            guard generation == id, isAllowed() else { throw CancellationError() }
            if final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if notice.isEmpty {
                    notice = transcript.isEmpty ? (audioDiagnostics?.emptyResultReason ?? "本次没有识别到语音。") : "最终结果为空，已保留中间草稿；请核对后使用。"
                }
            } else {
                finalTextToWrite = final
                disarmEscape()
                display(final)
                finishTimer?.cancel(); finishTimer = nil
                try await completeFinal(final, id: id)
                return
            }
            releaseResources()
        } catch {
            guard generation == id else { return }
            let message = error is CancellationError ? "听写已取消。" :
                (error is HostPermissionError ? "权限已失效，听写已停止；请到宿主权限管理中处理。" : error.localizedDescription)
            cancel(message: message)
        }
    }

    private func refreshAudioDiagnostics(_ microphone: any DictationAudioSource) {
        if let value = microphone.diagnostics { audioDiagnostics = value }
    }

    private func transmit(_ pcm: Data, session: any DoubaoSpeechSession) async throws {
        for offset in stride(from: 0, to: pcm.count, by: 3200) {
            try Task.checkCancellation()
            try await session.send(pcm.subdata(in: offset..<min(offset + 3200, pcm.count)))
        }
    }
    func refreshEscapeShortcut() {
        disarmEscape()
        guard let id = generation, let gesture, finalTextToWrite == nil else { return }
        removeEscape = registerEscape(gesture) { [weak self] in
            guard let self, self.generation == id, self.finalTextToWrite == nil, self.isAllowed() else { return }
            self.cancel()
        }
    }

    private func disarmEscape() {
        let remove = removeEscape; removeEscape = nil; remove?()
    }

    func stopRecording() {
        guard phase == .connecting || phase == .listening else { return }
        phase = .finishing; stopMeter()
        microphone?.stop(); monitor?.cancel(); monitor = nil
        if let id = generation { armFinishTimer(id: id, delivery: false) }
    }
    func cancel(message: String = "听写已取消。") {
        // Lifecycle events and the cancel shortcut can also arrive while idle.
        dismissReceipt(); guard isBusy else { return }
        notice = finalTextToWrite == nil ? message : message + " 本次定稿仍可在面板复制。"
        releaseResources()
    }
    func clearResult() {
        guard !isBusy else { return }
        transcript = ""; lastResult = ""; finalResultID = nil; notice = ""
    }

    private func display(_ text: String) {
        transcript = text
        if !text.isEmpty { lastResult = text }
        let slice = DictationCaptionSlice(text)
        if slice != captionSlice { captionSlice = slice }
    }

    /// Resolve the destination once, at the authoritative final (not key-up or the first draft).
    /// If focus changes after capture, never resolve a second field or synthesize a paste.
    private func completeFinal(_ text: String, id: UUID) async throws {
        try Task.checkCancellation()
        guard generation == id, isAllowed() else { throw CancellationError() }
        if hasInsertionAccess() {
            do { target = try makeTarget() }
            catch { notice = error.localizedDescription }
        } else { notice = "未获辅助功能授权，无法直接插入。" }
        let attempted = target != nil
        if let target { await deliverFinal(text, to: target, id: id) }
        try Task.checkCancellation()
        guard generation == id, isAllowed() else { throw CancellationError() }
        // Only the owning run completes the result, after the worker has acknowledged,
        // failed or been revoked. No suspension between fallback and closing this session.
        if target == nil { copyUndeliveredFinal(text, wasAttempted: attempted) }
        finalResultID = id
        releaseResources()
        await history.record(id: id, text: text)
    }
    private func copyUndeliveredFinal(_ text: String, wasAttempted: Bool) {
        let message: String
        do {
            try copyFinal(text) // Only this path writes the clipboard; timer/worker/cancel never do.
            message = wasAttempted ? "定稿已复制，粘贴前请核对输入框" : "定稿已复制到剪贴板"
        } catch { message = "未能复制定稿，可在语音输入面板手动复制" }
        notice += (notice.isEmpty ? "" : " ") + message + "。"
        if let hud {
            hud.showReceipt(message); receipt = hud; self.hud = nil
            receiptTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.dismissReceipt()
            }
        }
    }
    private func dismissReceipt() {
        receiptTimer?.cancel(); receiptTimer = nil; receipt?.close(); receipt = nil
    }

    /// Called only by the single finish() result. A stalled AX read/ACK must not stall
    /// resource cleanup; the timer revokes this specific target and never resends its text.
    private func deliverFinal(_ text: String, to target: any DictationFinalInserting, id: UUID) async {
        await withCheckedContinuation { continuation in
            finalDeliveryWaiter = continuation
            armFinishTimer(id: id, delivery: true)
            textWriter = Task { [weak self, target] in
                guard let self, self.generation == id else { return }
                defer { if self.generation == id { self.textWriter = nil; self.resolveDelivery() } }
                do {
                    try Task.checkCancellation()
                    guard self.isAllowed(), self.target === target else { throw CancellationError() }
                    guard self.hasInsertionAccess() else { throw PluginError.invalid("辅助功能授权已失效，无法直接插入。") }
                    try await target.commitFinal(text)
                    try Task.checkCancellation()
                    guard self.generation == id, self.target === target else { return }
                    self.acknowledgedTextLength = target.acknowledgedLength ?? text.utf16.count
                } catch {
                    guard self.generation == id, self.target === target else { return }
                    self.detachTarget(error)
                }
            }
        }
    }
    private func resolveDelivery() {
        let waiter = finalDeliveryWaiter; finalDeliveryWaiter = nil; waiter?.resume()
    }

    // Never await a stalled editor Task.value to leave finishing. Revoke the actual
    // target first; a late worker cannot post to the editor or complete a new session.
    private func armFinishTimer(id: UUID, delivery: Bool) {
        finishTimer?.cancel()
        let budget = delivery ? deliveryBudget : recognitionBudget
        finishTimer = Task { [weak self] in
            do { try await Task.sleep(for: budget) } catch { return }
            guard let self, self.generation == id, self.phase == .finishing else { return }
            if delivery, self.finalDeliveryWaiter != nil {
                self.detachTarget(PluginError.invalid("输入框未及时确认，已停止自动写入。"))
                self.textWriter?.cancel()
                self.resolveDelivery()
            } else if !delivery, self.finalTextToWrite == nil {
                self.cancel(message: "等待语音定稿超时，已停止；未定稿的文字可在面板核对。")
            }
        }
    }
    private func detachTarget(_ error: Error) {
        target?.cancel(); target = nil
        notice = error.localizedDescription
    }
    private func stopMeter() {
        meterReader?.cancel(); meterReader = nil
        if waveReadings.value != .quiet { waveReadings.send(.quiet) }
    }
    private func releaseResources() {
        generation = nil; gesture = nil; disarmEscape(); stopMeter()
        finishTimer?.cancel(); finishTimer = nil; resolveDelivery()
        if let microphone { microphone.stop(); refreshAudioDiagnostics(microphone) }
        microphone = nil
        session?.cancel(); session = nil
        task?.cancel(); task = nil; monitor?.cancel(); monitor = nil
        target?.cancel(); target = nil; finalTextToWrite = nil; captionSlice = DictationCaptionSlice("")
        textWriter?.cancel(); textWriter = nil
        hud?.close(); hud = nil
        phase = .idle
    }
}
