import Foundation

@MainActor protocol DoubaoSpeechSession: AnyObject {
    var onTranscript: ((String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start() async throws
    func send(_ pcm: Data) async throws
    func finish() async throws -> String
    func cancel()
}

/// ASREnded is the recognition barrier. SessionFinished acknowledges cleanup, not text.
/// A segment final alongside an outstanding partial is not a complete transcript.
struct DoubaoASREnding {
    private(set) var asrEnded = false
    var cleanupSubmitted = false
    var sessionFinished = false
    mutating func endASR() -> Bool {
        guard !asrEnded else { return false }
        asrEnded = true; return true
    }
    func result(_ transcript: DoubaoTranscript, skipCleanup: Bool = false) -> String? {
        // Flat legacy segments have no whole-session final bit. Keep their original
        // terminal barrier; a single confirmed segment must not truncate the rest.
        guard asrEnded, cleanupSubmitted || sessionFinished || skipCleanup,
              transcript.hasWholeSessionFinal || sessionFinished,
              transcript.finalCount > 0, transcript.pending.isEmpty else { return nil }
        return transcript.confirmed
    }
}

/// One bounded session. No retries: reconnecting must never silently resend a recording.
@MainActor final class DoubaoASRClient: DoubaoSpeechSession {
    var onTranscript: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var waiter: (event: String, continuation: CheckedContinuation<DoubaoASRProtocol.Message, Error>)?
    private var operationStarted: TimeInterval?
    private var ending: DoubaoASREnding?
    private var endWaiter: CheckedContinuation<String, Error>?
    private var endSend: Task<Void, Never>?
    private var closed = false
    private var ready = false
    private var taskID = ""
    private var sequence = 0
    private var transcript = DoubaoTranscript()
    private var recentIDs: [String] = []
    isolated deinit { cancel() }

    func start() async throws {
        guard session == nil, !closed else { throw CancellationError() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = TimeInterval(DoubaoASRLimits.maximumSeconds + 60)
        let session = URLSession(configuration: configuration)
        self.session = session
        operationStarted = ProcessInfo.processInfo.systemUptime
        watchdog = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    // Even local flow-control on FinishSession must not hold sealed text
                    // past this tick. Without the recognition barrier this resolves nothing.
                    if self.resolveEnding(skipCleanup: true) { return }
                    if let start = self.operationStarted, ProcessInfo.processInfo.systemUptime - start > 15 {
                        let message = self.ending == nil ? "豆包语音响应超时，已停止录音；可重新开始。" : "等待豆包定稿超时，已停止；中间草稿保留在面板。"
                        self.transportFailed(PluginError.invalid(message))
                        return
                    }
                }
            } catch {}
        }
        do {
            let guest = try await DoubaoGuestContext.load(using: session)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let socket = session.webSocketTask(with: guest.request)
            socket.maximumMessageSize = DoubaoASRLimits.messageBytes
            self.socket = socket
            socket.resume()
            reader = Task { [weak self, socket] in
                do {
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        try Task.checkCancellation()
                        let message: DoubaoASRProtocol.Message
                        switch frame {
                        case .data(let data): message = try DoubaoASRProtocol.decode(data)
                        case .string(let text): message = try DoubaoASRProtocol.decode(text: text)
                        @unknown default: throw PluginError.invalid("豆包返回了未知语音消息。")
                        }
                        try self?.receive(message)
                        if self?.closed != false { break } // A cleanup ACK is not necessarily the final ASRResponse.
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if error is PluginError { self?.fail(error) }
                    else if error is DecodingError { self?.fail(PluginError.invalid("豆包语音响应无法解析，已停止听写。")) }
                    else { self?.transportFailed(PluginError.invalid("豆包语音连接中断；未定稿的草稿保留在面板。")) }
                }
            }
            let task = try await command("StartTask", expecting: "TaskStarted")
            guard !task.taskID.isEmpty else { throw PluginError.invalid("豆包未返回有效的语音任务。") }
            taskID = task.taskID
            _ = try await command("StartSession", payload: DoubaoASRProtocol.sessionPayload(), expecting: "SessionStarted")
            ready = true
        } catch {
            cancel()
            if error is CancellationError || error is PluginError { throw error }
            throw PluginError.invalid("无法连接豆包语音，请检查网络或稍后重试。")
        }
    }

    func send(_ pcm: Data) async throws {
        guard ready, !closed, let socket else { throw CancellationError() }
        guard !pcm.isEmpty, pcm.count <= DoubaoASRLimits.audioBufferBytes, pcm.count % 2 == 0 else {
            throw PluginError.invalid("麦克风音频格式无效。")
        }
        sequence += 1
        operationStarted = ProcessInfo.processInfo.systemUptime
        defer { operationStarted = nil }
        do { try await socket.send(.data(DoubaoASRProtocol.request("TaskRequest", taskID: taskID, audio: pcm, sequence: sequence))) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw PluginError.invalid("音频发送失败，已停止听写；请检查网络后重试。")
        }
    }

    func finish() async throws -> String {
        try Task.checkCancellation()
        guard ready, !closed, socket != nil else { throw CancellationError() }
        ready = false; ending = DoubaoASREnding(); operationStarted = ProcessInfo.processInfo.systemUptime
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                endWaiter = continuation
                sendEnding("EndASR")
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    private func sendEnding(_ event: String) {
        guard let socket else { return }
        let packet = DoubaoASRProtocol.request(event, taskID: taskID)
        endSend = Task { [weak self, socket] in
            do {
                try Task.checkCancellation()
                try await socket.send(.data(packet))
                guard !Task.isCancelled, let self, !self.closed else { return }
                if event == "FinishSession" {
                    self.ending?.cleanupSubmitted = true
                    self.resolveEnding()
                }
            } catch {
                guard !Task.isCancelled, let self, !self.closed else { return }
                if event == "EndASR", self.ending?.asrEnded == true { return } // Already acknowledged.
                self.transportFailed(PluginError.invalid("豆包语音结束请求未能送达；请在面板核对已保留的文字。"))
            }
        }
    }

    @discardableResult private func resolveEnding(skipCleanup: Bool = false) -> Bool {
        guard let value = ending?.result(transcript, skipCleanup: skipCleanup), let endWaiter else { return false }
        self.endWaiter = nil
        close(code: .normalClosure)
        endWaiter.resume(returning: value)
        return true
    }

    private func transportFailed(_ error: Error) {
        // A failure to close a connection cannot invalidate an already sealed result.
        guard !resolveEnding(skipCleanup: true) else { return }
        if ending?.asrEnded == true {
            fail(PluginError.invalid("豆包已结束识别，但没有返回完整定稿；中间草稿保留在面板。"))
        } else { fail(error) }
    }

    func cancel() { close(code: .goingAway) }

    private func command(_ event: String, payload: Data? = nil, expecting: String) async throws -> DoubaoASRProtocol.Message {
        guard !closed, waiter == nil, let socket else { throw CancellationError() }
        operationStarted = ProcessInfo.processInfo.systemUptime
        defer { operationStarted = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = (expecting, continuation)
                let packet = DoubaoASRProtocol.request(event, taskID: taskID, payload: payload)
                Task { [weak self, socket] in
                    do { try await socket.send(.data(packet)) }
                    catch { self?.fail(PluginError.invalid("无法发送豆包语音请求，请检查网络。")) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    private func receive(_ message: DoubaoASRProtocol.Message) throws {
        guard !closed else { return }
        guard message.statusCode == nil || message.statusCode == 20_000_000,
              message.event != "TaskFailed", message.event != "SessionFailed" else {
            // Do not surface raw service text/URLs, which can contain visitor identifiers.
            throw PluginError.invalid("豆包语音拒绝了本次请求（状态 \(message.statusCode.map(String.init) ?? "未知")），请稍后重试。")
        }
        if !message.taskID.isEmpty, !taskID.isEmpty, message.taskID != taskID {
            throw PluginError.invalid("豆包语音会话标识不匹配。")
        }
        if message.event == "ASRResponse" {
            if !message.messageID.isEmpty {
                guard !recentIDs.contains(message.messageID) else { return }
                recentIDs.append(message.messageID)
                if recentIDs.count > 64 { recentIDs.removeFirst() }
            }
            try transcript.consume(message.payload)
            onTranscript?(transcript.text)
        }
        if ending != nil {
            if message.event == "ASREnded", ending?.endASR() == true { sendEnding("FinishSession") }
            if message.event == "SessionFinished", ending?.asrEnded == true { ending?.sessionFinished = true }
            resolveEnding()
        }
        if let waiter, waiter.event == message.event {
            self.waiter = nil
            waiter.continuation.resume(returning: message)
        }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        let callback = onFailure
        close(code: .goingAway, error: error)
        callback?(error)
    }

    private func close(code: URLSessionWebSocketTask.CloseCode, error: Error = CancellationError()) {
        guard !closed else { return }
        closed = true; ready = false
        reader?.cancel(); reader = nil; watchdog?.cancel(); watchdog = nil
        socket?.cancel(with: code, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        let pending = waiter; waiter = nil; pending?.continuation.resume(throwing: error)
        endSend?.cancel(); endSend = nil; ending = nil
        let completion = endWaiter; endWaiter = nil; completion?.resume(throwing: error)
        operationStarted = nil; recentIDs.removeAll(); taskID = ""; transcript = DoubaoTranscript()
        onTranscript = nil; onFailure = nil
    }
}
