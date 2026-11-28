import AppKit
import UntitledPluginSDK
@testable import UntitledPluginSpeech
import Carbon
import Security
#if SWIFT_PACKAGE
import DictationIMEKit
#endif

@MainActor enum DictationInputSourceSetup {
    static let instructions = "请在「系统设置 → 键盘 → 文字输入 → 编辑 → ＋」中添加“Untitled 实时听写”，然后回到原输入框。"
    static let setupRequired = "请先到「语音输入设置 → 实时输入法」安装组件，再由你在系统设置中添加输入法。尚未开始录音。"
    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent(DictationIME.bundleName, isDirectory: true)
    }
    static func source(_ id: String, all: Bool = false) -> TISInputSource? {
        let props = [kTISPropertyInputSourceID as String: id] as CFDictionary
        return (TISCreateInputSourceList(props, all)?.takeRetainedValue() as? [TISInputSource])?.first
    }
    static func current() -> String? {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    private static func flag(_ s: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(s, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }
    static func selectable(_ id: String) -> TISInputSource? {
        guard let s = source(id), flag(s, kTISPropertyInputSourceIsEnabled), flag(s, kTISPropertyInputSourceIsSelectCapable) else { return nil }
        return s
    }
    static func select(_ id: String) -> Bool {
        guard let s = selectable(id) else { return false }
        return TISSelectInputSource(s) == noErr
    }
    static var status: String {
        if selectable(DictationIME.sourceID) != nil { return "系统已启用；实际连接在听写时核对。" }
        return source(DictationIME.sourceID, all: true) == nil ? "尚未注册输入法组件。" : "组件已注册，尚未在系统键盘设置中添加。"
    }
    /// Never called by capture, plugin installation, opening settings or a shortcut.
    /// Registration makes a source discoverable; only the user enables it in Keyboard Settings.
    static func install() throws {
        let fm = FileManager.default
        guard let bundled = Bundle.main.builtInPlugInsURL?.appendingPathComponent(DictationIME.bundleName),
              let requirement = DictationIMESocket.requirement(for: DictationIME.sourceID) else {
            throw PluginError.invalid("请使用带开发者签名的完整 Untitled 应用安装输入法。")
        }
        func signed(_ url: URL) -> Bool {
            var code: SecStaticCode?
            return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess && code.map {
                SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
            } == true
        }
        guard signed(bundled) else { throw PluginError.invalid("输入法组件签名无效，请重新安装完整的 Untitled。") }
        let dest = destination, dir = dest.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let exists = fm.fileExists(atPath: dest.path)
        guard !exists || signed(dest) else { throw PluginError.invalid("输入法目录中已有同名的其他组件，未覆盖。请先手动核对该组件。") }
        // Stage on the same volume. If anything fails, never remove the old component first.
        let tmp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent(DictationIME.bundleName)
        try fm.copyItem(at: bundled, to: copy)
        guard signed(copy) else { throw PluginError.invalid("输入法副本校验失败，未替换原组件。") }
        if exists { _ = try fm.replaceItemAt(dest, withItemAt: copy) } else { try fm.moveItem(at: copy, to: dest) }
        let status = TISRegisterInputSource(dest as CFURL)
        guard status == noErr else { throw PluginError.invalid("组件已复制，macOS 尚未注册（\(status)）。请稍后注销并重新登录，再检查键盘设置。") }
    }
}

/// We own a switch, not an input source. Never disable sources or move a user back from a manual selection.
@MainActor final class DictationInputSourceLease {
    private let current: @MainActor () -> String?, select: @MainActor (String) -> Bool
    private let original: String?
    private var previous: String?
    private var acquired = false, lost = false
    init(current: @escaping @MainActor () -> String? = DictationInputSourceSetup.current,
         select: @escaping @MainActor (String) -> Bool = DictationInputSourceSetup.select) {
        self.current = current; self.select = select; original = current()
    }
    func acquire() throws {
        guard !acquired, let old = current(), old == original else { throw DictationTargetError.changed }
        if old != DictationIME.sourceID {
            guard select(DictationIME.sourceID) else { throw PluginError.invalid("未能切换到听写输入法。" + DictationInputSourceSetup.instructions) }
            previous = old
        }
        acquired = true
        try check()
    }
    func check() throws {
        if acquired && current() != DictationIME.sourceID { lost = true }
        guard acquired, !lost else { throw DictationTargetError.changed }
    }
    func restore() {
        defer { previous = nil; acquired = false }
        if acquired, !lost, let previous, current() == DictationIME.sourceID { _ = select(previous) }
    }
}

@MainActor protocol DictationMarkedBridge: AnyObject {
    func begin(session: UUID, focus: DictationIMEFocus, proof: DictationIMEProof) async throws
    func send(_ request: DictationIMERequest) async throws
    func validate() throws
    func close()
}

@MainActor final class DictationMarkedTextBridge: DictationMarkedBridge {
    private let source = DictationInputSourceLease()
    private var channel: DictationIMEChannel?
    private var observer: (any NSObjectProtocol)?
    private var closed = false
    isolated deinit { close() }
    private func check() throws {
        try Task.checkCancellation()
        guard !closed, !IsSecureEventInputEnabled() else { throw DictationTargetError.changed }; try source.check()
    }
    func validate() throws {
        try check()
        guard channel?.peerIsOpen == true else { throw DictationTargetError.changed }
    }
    func begin(session: UUID, focus: DictationIMEFocus, proof: DictationIMEProof) async throws {
        guard !closed, channel == nil, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.pid else { throw DictationTargetError.changed }
        try source.acquire()
        observer = DistributedNotificationCenter.default().addObserver(forName: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, !self.closed else { return }; do { try self.source.check() } catch { self.close() } }
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
        repeat {
            try check()
            if channel == nil {
                let processes = NSRunningApplication.runningApplications(withBundleIdentifier: DictationIME.sourceID)
                if processes.count == 1, let pid = processes.first?.processIdentifier, let fd = try? DictationIMESocket.connect(to: pid) {
                    channel = try DictationIMEChannel(taking: fd)
                }
            }
            if let channel {
                let req = DictationIMERequest(session: session, operation: .begin, focus: focus, proof: proof)
                let reply = try await exchange(req, on: channel)
                if reply == .ok { return }
                if reply != .waitingForClient { throw DictationTargetError.changed }
            }
            try await Task.sleep(for: .milliseconds(25)) // Only a read-only begin is retryable, never a mutation.
        } while ContinuousClock.now < deadline
        throw PluginError.invalid("系统已选择听写输入法，但目标编辑器未建立可验证的输入会话；已停止写入。")
    }
    func send(_ request: DictationIMERequest) async throws {
        try validate()
        guard let channel else { throw DictationTargetError.unavailable }
        switch try await exchange(request, on: channel) {
        case .ok: return
        case .changed: throw DictationTargetError.changed
        default: throw DictationTargetError.unconfirmed
        }
    }
    private func exchange(_ req: DictationIMERequest, on channel: DictationIMEChannel) async throws -> DictationIMEReply.Status {
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }; channel.close()
        }; defer { timer.cancel() }
        do {
            try check(); try await channel.send(req)
            let reply = try await channel.receive(DictationIMEReply.self); try check()
            guard reply.id == req.id else { throw DictationTargetError.unconfirmed }; return reply.status
        } catch is CancellationError { throw CancellationError() }
        catch { throw DictationTargetError.unconfirmed }
    }
    func close() {
        guard !closed else { return }; closed = true
        channel?.close(); channel = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer); self.observer = nil }
        source.restore()
    }
}
