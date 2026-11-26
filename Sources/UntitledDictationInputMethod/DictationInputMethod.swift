import AppKit
import Carbon
import InputMethodKit
#if SWIFT_PACKAGE
import DictationIMEKit
#endif

/// Lives in the normal system-launched IMK process. No host-launched duplicate, stdin/stdout
/// dependency, keystroke forwarding, or registration of controllers merely because they exist.
@MainActor private final class DictationIMEServer {
    static let shared = DictationIMEServer()
    let active = NSHashTable<DictationInputController>.weakObjects()
    private var listener: (any DispatchSourceRead)?
    private var connection: DictationIMEChannel?
    private var composition: DictationComposition?
    private weak var owner: DictationInputController?

    func activate(_ controller: DictationInputController) {
        if owner != nil { retire() }; active.add(controller)
        guard listener == nil else { return }
        let path = DictationIMESocket.endpoint(pid: getpid())
        guard let fd = try? DictationIMESocket.listen(at: path) else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptConnection(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source; source.resume()
    }
    func deactivate(_ controller: DictationInputController) {
        if owner === controller { retire() }
        active.remove(controller)
        if active.allObjects.isEmpty { stop() }
    }
    func interrupt(_ controller: DictationInputController) {
        if owner === controller { retire() }
    }
    func stop() {
        retire()
        if let listener {
            unlink(DictationIMESocket.endpoint(pid: getpid())); listener.cancel(); self.listener = nil
        }
    }
    private func retire() {
        composition?.invalidate(); composition = nil; owner = nil
        connection?.close(); connection = nil
    }
    private func acceptConnection(_ listenerFD: Int32) {
        let fd = Darwin.accept(listenerFD, nil, nil)
        guard fd >= 0 else { return }; DictationIMESocket.configure(fd)
        guard (try? DictationIMESocket.verify(fd, id: DictationIME.hostID)) != nil else { Darwin.close(fd); return }
        if connection?.peerIsOpen == false { retire() }
        guard connection == nil else { Darwin.close(fd); return }
        guard let channel = try? DictationIMEChannel(taking: fd) else { return }; connection = channel
        Task { [weak self] in
            defer { channel.close(); if self?.connection === channel { self?.retire() } }
            do {
                while true {
                    let request = try await channel.receive(DictationIMERequest.self)
                    guard let self, self.connection === channel, channel.peerIsOpen,
                          DispatchTime.now().uptimeNanoseconds < request.expires else { break }
                    let status = self.handle(request)
                    try await channel.send(DictationIMEReply(id: request.id, status: status))
                    if request.operation == .commit || !(status == .ok || status == .waitingForClient) { break }
                }
            } catch { /* EOF / failed ACK revokes this connection. Never replay any text. */ }
        }
    }
    func isCurrent(_ controller: DictationInputController) -> Bool {
        let clients = active.allObjects
        return connection?.peerIsOpen == true && clients.count == 1 && clients[0] === controller
    }
    private func handle(_ request: DictationIMERequest) -> DictationIMEReply.Status {
        if request.operation == .begin {
            guard composition == nil, let focus = request.focus else { return .changed }
            let clients = active.allObjects
            guard clients.count == 1, let controller = clients.first else { return .waitingForClient }
            guard let client = IMKCompositionClient(controller),
                  let new = DictationComposition(session: request.session, focus: focus, proof: request.proof, client: client) else { return .changed }
            composition = new; owner = controller; return .ok
        }
        guard let composition else { return .changed }
        return composition.apply(request)
    }
}

@MainActor private final class IMKCompositionClient: DictationCompositionClient {
    private weak var controller: DictationInputController?
    private let input: any IMKTextInput
    private let identifier: String
    private let activation: UUID
    init?(_ controller: DictationInputController) {
        guard let c = controller.client(), let id = c.uniqueClientIdentifierString(), !id.isEmpty else { return nil }
        input = c; identifier = id; self.controller = controller; activation = controller.generation
    }
    func matches(_ focus: DictationIMEFocus) -> Bool {
        guard !IsSecureEventInputEnabled(), let c = controller, c.generation == activation,
              DictationIMEServer.shared.isCurrent(c),
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == focus.pid,
              front.bundleIdentifier == focus.bundleID, input.bundleIdentifier() == focus.bundleID,
              c.client()?.uniqueClientIdentifierString() == identifier,
              let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String == DictationIME.sourceID
            && !IsSecureEventInputEnabled() && DictationIMEServer.shared.isCurrent(c)
    }
    var marked: NSRange { input.markedRange() }
    var selection: NSRange { input.selectedRange() }
    var length: Int { input.length() }
    func text(at range: NSRange) -> String? {
        var actual = NSRange(location: NSNotFound, length: 0)
        let value = input.string(from: range, actualRange: &actual)
        return actual == range ? value : nil
    }
    func caret(at offset: Int) -> CGRect? {
        var actual = NSRange(location: NSNotFound, length: 0)
        let rect = input.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: &actual)
        return actual.location == offset ? rect : nil
    }
    func mark(_ text: String) {
        // IMK applies the native default underline for an NSString, without manufactured underline characters.
        input.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func insert(_ text: String) { input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
}

@objc(UntitledDictationInputController)
// IMK invokes these Objective-C callbacks on its NSApplication run loop. The superclass has
// no Sendable annotation; the only added mutable state and all client access are main-actor-bound.
@MainActor final class DictationInputController: IMKInputController, @unchecked Sendable {
    @MainActor fileprivate var generation = UUID()
    override func activateServer(_ sender: Any!) {
        MainActor.assumeIsolated { generation = UUID(); DictationIMEServer.shared.activate(self) }
    }
    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated { generation = UUID(); DictationIMEServer.shared.deactivate(self) }
    }
    override func inputControllerWillClose() {
        MainActor.assumeIsolated { generation = UUID(); DictationIMEServer.shared.deactivate(self) }
        super.inputControllerWillClose()
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // Do not inspect key characters or consume normal typing. Revoke the dictation lease.
        MainActor.assumeIsolated { DictationIMEServer.shared.interrupt(self) }; return false
    }
    override func commitComposition(_ sender: Any!) { MainActor.assumeIsolated { DictationIMEServer.shared.interrupt(self) } }
    override func cancelComposition() { MainActor.assumeIsolated { DictationIMEServer.shared.interrupt(self) } }
}

@main private struct DictationInputMethodMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        guard let name = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
              let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        withExtendedLifetime(server) { app.run() }; DictationIMEServer.shared.stop()
    }
}
