import CryptoKit
#if SWIFT_PACKAGE
import UntitledPluginSDK
#endif
import Foundation
import Network
import Security

/// OS TLS authenticates both peers using a user-transferred 256-bit secret.
/// Nothing listens or browses until the user explicitly starts sharing.
@MainActor final class SharingTransport {
    static let serviceType = "_untitled-share._tcp"
    nonisolated static let defaultPort: UInt16 = 48479
    struct Peer: Identifiable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }
    var peersChanged: ([Peer]) -> Void = { _ in }
    var connected: () -> Void = {}
    var listening: (UInt16) -> Void = { _ in }
    var received: (SharingMessage) -> Void = { _ in }
    var disconnected: (String?) -> Void = { _ in }
    var diagnostics: (String) -> Void = { _ in }
    var tlsHandshakeFailed: (OSStatus) -> Void = { _ in }
    var failed: (String) -> Void = { _ in }
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var candidates: [UUID: NWConnection] = [:]
    private var activeID: UUID?
    private var outgoingID: UUID?
    private var collisionDetected = false
    private var framer = SharingFramer()
    private var pairingKey: Data?
    private var localOnly = false
    private var listenerReady = false
    private var generation = 0
    private var inFlightBytes = 0
    private var clipboardTextSending = false
    private var clipboardImages: SharingClipboardImageLink?
    var beginClipboardImage: (UInt64) -> SharingClipboardImageLink.Delivery? = { _ in nil }
    var clipboardImageStatusChanged: (SharingClipboardImageStatus) -> Void = { _ in }
    var port: NWEndpoint.Port? { listenerReady ? listener?.port : nil }
    var isConnected: Bool { activeID != nil }
    var canDial: Bool { listenerReady && pairingKey != nil && activeID == nil && candidates.isEmpty }
    var canSendClipboardText: Bool { isConnected && !clipboardTextSending && inFlightBytes <= 4096 }

    private static func pskMetadata(_ connection: NWConnection) -> sec_protocol_metadata_t? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let security = metadata.securityProtocolMetadata
        guard sec_protocol_metadata_get_negotiated_tls_protocol_version(security) == .TLSv12,
              sec_protocol_metadata_get_negotiated_tls_ciphersuite(security).rawValue == UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256) else { return nil }
        return security
    }
    static func exporter(_ connection: NWConnection, label: String) -> Data? {
        guard let metadata = pskMetadata(connection) else { return nil }
        return label.withCString { pointer in
            guard let secret = sec_protocol_metadata_create_secret(metadata, label.utf8.count, pointer, 32) else { return nil }
            return Data(secret as DispatchData)
        }
    }
    func setClipboardImageGrants(_ grants: SharingClipboardGrants?) {
        clipboardImages?.stop(); clipboardImages = nil
        guard let grants else { clipboardImageStatusChanged(.inactive); return }
        guard let id = activeID, let primary = candidates[id],
              let key = Self.exporter(primary, label: "Untitled clipboard primary v1") else {
            clipboardImageStatusChanged(.unavailable); return
        }
        let initiator = id == outgoingID
        let link = SharingClipboardImageLink(grants: grants, primaryKey: SymmetricKey(data: key), initiator: initiator,
            beginImage: { [weak self] revision in self?.beginClipboardImage(revision) })
        link.stateChanged = { [weak self, weak link] status in
            guard let self, let link, self.clipboardImages === link else { return }
            self.clipboardImageStatusChanged(status)
        }
        clipboardImages = link
        link.startHandshakeDeadline()
        clipboardImageStatusChanged(.preparing)
        // The independent stream may arrive before a delayed primary packet.
        // Dial only after the acceptor confirms this exact pair of grants.
        if !initiator { _ = send(.init(kind: .clipboardImageReady, imageGrants: grants)) }
    }
    func acceptClipboardImageReady(_ grants: SharingClipboardGrants) {
        guard let id = activeID, id == outgoingID, let primary = candidates[id], let pairingKey,
              let link = clipboardImages, link.grants == grants.reversed else { return }
        let parameters = Self.parameters(key: pairingKey)
        if localOnly { parameters.includePeerToPeer = false }
        link.open(to: primary.endpoint, parameters: parameters)
    }
    func offerClipboardImage(_ png: Data, revision: UInt64) { clipboardImages?.offer(png, revision: revision) }
    func discardPendingClipboardImage() { clipboardImages?.discardPending() }

    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // Network.framework's external PSK suite is TLS 1.2 (Apple's peer-to-peer pattern).
        // TLS 1.3 + add_pre_shared_key alone failed in our macOS 27 test configuration.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("UntitledSharing-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        // Reject certificate authentication if requested. The ready handler also verifies
        // the negotiated PSK ciphersuite; successful PSK handshakes do not invoke this block.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(false) }, .main)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
    func start(key: Data, name: String, localOnly: Bool = false, listenPort: UInt16? = nil) throws {
        stop()
        guard key.count == 32 else { throw PluginError.invalid("共享需要 256 位随机配对密钥。") }
        let parameters = Self.parameters(key: key)
        if localOnly {
            parameters.includePeerToPeer = false
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }
        self.pairingKey = key; self.localOnly = localOnly
        let generation = self.generation
        guard listenPort == nil || (localOnly && listenPort != 0) else { throw PluginError.invalid("自定义监听端口仅供本机回环验证。") }
        let listener = try NWListener(using: parameters, on: localOnly ? (listenPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any) : NWEndpoint.Port(rawValue: Self.defaultPort)!)
        if !localOnly { listener.service = NWListener.Service(name: name, type: Self.serviceType) }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { connection.cancel(); return }
                if self.activeID != nil {
                    if let link = self.clipboardImages { link.accept(connection) }
                    else { connection.cancel() }
                    return
                }
                guard self.candidates.count < 4 else { connection.cancel(); return }
                // Refuse a cross-dial without cancelling our legitimate outgoing attempt.
                if self.outgoingID != nil { self.collisionDetected = true; connection.cancel(); return }
                self.attach(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                if case .ready = state {
                    self.listenerReady = true
                    if let port = self.port { self.listening(port.rawValue) }
                } else { self.listenerReady = false }
                self.diagnostics("listener: \(state)")
                if case .failed(let error) = state { self.stop(); self.failed("局域网监听失败：\(error.localizedDescription)") }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
        if localOnly { return } // Loopback transport tests never browse the user's network.
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                let peers = results.compactMap { result -> Peer? in
                    guard case .service(let peerName, _, _, _) = result.endpoint, peerName != name else { return nil }
                    return Peer(id: String(describing: result.endpoint), name: peerName, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
                self.peersChanged(peers)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                if case .failed(let error) = state {
                    // Bonjour is optional. Don't dismantle a healthy explicit
                    // IP/VPN link, or its listener, because browsing failed.
                    self.browser?.cancel(); self.browser = nil
                    self.peersChanged([])
                    self.diagnostics("discovery failed: \(error.localizedDescription)")
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }
    func connect(_ endpoint: NWEndpoint) throws {
        guard canDial, let pairingKey else { throw PluginError.invalid("请先断开当前连接，或等待配对完成。") }
        // Keep outgoing connection options separate from the listener's local binding.
        // Listener readiness (including a nonzero port) is checked independently.
        let outgoing = Self.parameters(key: pairingKey)
        if localOnly { outgoing.includePeerToPeer = false }
        collisionDetected = false
        attach(NWConnection(to: endpoint, using: outgoing), outgoing: true)
    }
    private func attach(_ connection: NWConnection, outgoing: Bool = false) {
        let id = UUID(), generation = self.generation
        candidates[id] = connection
        if outgoing { outgoingID = id }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.candidates[id] != nil else { return }
                self.diagnostics("connection: \(state)")
                switch state {
                case .ready:
                    guard Self.pskMetadata(connection) != nil else {
                        self.fail(id, reason: "对端未协商指定的 TLS-PSK 认证套件，已拒绝连接。"); return
                    }
                    guard self.activeID == nil else { self.remove(id); return }
                    self.collisionDetected = false
                    self.activeID = id; self.framer = SharingFramer(); self.inFlightBytes = 0; self.clipboardTextSending = false
                    for other in Array(self.candidates.keys) where other != id { self.remove(other) }
                    self.connected(); self.receive(id)
                case .failed(let error):
                    if self.activeID != id, case .tls(let status) = error { self.tlsHandshakeFailed(status) }
                    self.fail(id, reason: self.connectionError(error))
                case .waiting(let error):
                    guard self.activeID != id else { break } // An established path uses the session heartbeat.
                    if case .tls(let status) = error {
                        self.tlsHandshakeFailed(status)
                        self.fail(id, reason: self.connectionError(error))
                    } else if outgoing {
                        // NWConnection can wait for a network-path change even
                        // after ECONNREFUSED. A restarted listener is not a path
                        // change; return this failed dial to the retry owner now.
                        self.fail(id, reason: self.connectionError(error))
                    }
                case .cancelled: self.fail(id, reason: nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == generation, self.candidates[id] != nil, self.activeID != id else { return }
            self.fail(id, reason: self.collisionDetected ? "两端同时发起了连接，请只在其中一台 Mac 点击连接后重试。" : "配对超时，请检查网络与配对密钥。")
        }
    }
    private func connectionError(_ error: NWError) -> String {
        if collisionDetected { return "两端同时发起了连接，请只在其中一台 Mac 点击连接后重试。" }
        if case .tls = error { return "TLS 认证失败，请核对两端的配对密钥。" }
        return "连接失败：\(error.localizedDescription)"
    }
    private func receive(_ id: UUID) {
        guard let connection = candidates[id], activeID == id else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.activeID == id else { return }
                do {
                    if let data {
                        for message in try self.framer.append(data) {
                            guard self.activeID == id else { return }
                            self.received(message)
                        }
                    }
                    if complete || error != nil { self.fail(id, reason: error?.localizedDescription); return }
                    self.receive(id)
                } catch { self.fail(id, reason: "共享协议错误：\(error.localizedDescription)") }
            }
        }
    }
    @discardableResult func send(_ message: SharingMessage, ifAllowed: (() -> Bool)? = nil) -> Bool {
        guard let id = activeID, let connection = candidates[id] else { return false }
        let isClipboard = message.kind == .clipboardText
        // At most one text send pending. Input and control frames never wait
        // for clipboard acknowledgement or a separate transfer queue.
        guard !isClipboard || canSendClipboardText else { return false }
        do {
            let data = try SharingFramer.encode(message)
            // Drop live audio under congestion. Never build an unbounded queue or drop a key-up.
            if message.kind == .audio, inFlightBytes > 32768 { return false }
            guard inFlightBytes + data.count <= 512 * 1024 else { fail(id, reason: "网络拥塞，已安全返回本机。"); return false }
            // Revalidate after encoding, just before committing a new input frame.
            if let ifAllowed, !ifAllowed() { return false }
            inFlightBytes += data.count
            if isClipboard { clipboardTextSending = true }
            let size = data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self, self.activeID == id else { return }
                    self.inFlightBytes = max(0, self.inFlightBytes - size)
                    if isClipboard { self.clipboardTextSending = false }
                    if let error { self.fail(id, reason: error.localizedDescription) }
                }
            })
            return true
        } catch {
            if !isClipboard { fail(id, reason: error.localizedDescription) }
            return false
        }
    }
    func disconnect() {
        guard !candidates.isEmpty else { return }
        for id in Array(candidates.keys) { remove(id) }
        activeID = nil; framer = SharingFramer(); inFlightBytes = 0; clipboardTextSending = false
        disconnected(nil)
    }
    private func fail(_ id: UUID, reason: String?) {
        let wasActive = activeID == id
        remove(id)
        if wasActive || candidates.isEmpty { disconnected(reason) }
    }
    private func remove(_ id: UUID) {
        if activeID == id { setClipboardImageGrants(nil); activeID = nil }
        if outgoingID == id { outgoingID = nil }
        if let connection = candidates.removeValue(forKey: id) { connection.stateUpdateHandler = nil; connection.cancel() }
    }
    func stop() {
        generation += 1
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        for id in Array(candidates.keys) { remove(id) }
        pairingKey = nil; listenerReady = false; collisionDetected = false; framer = SharingFramer(); inFlightBytes = 0; clipboardTextSending = false
        peersChanged([])
    }
}
