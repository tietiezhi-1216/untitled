import CryptoKit
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

enum SharingClipboardImageStatus: String {
    case inactive, preparing, ready, unavailable
}

struct SharingClipboardImageHeader: Equatable, Sendable {
    static let bytes = 12
    private static let minimumPayload = 57 // Signature, IHDR, IDAT overhead and IEND.
    static let maximumPayload = 32 * 1024 * 1024
    static let maximumPixels = 24_000_000
    let revision: UInt64
    let length: Int

    init?(revision: UInt64, length: Int) {
        // Zero length acknowledges a consumed image on this same bound stream.
        guard revision > 0, length == 0 || (Self.minimumPayload...Self.maximumPayload).contains(length) else { return nil }
        self.revision = revision; self.length = length
    }
    var isAcknowledgement: Bool { length == 0 }
    init?(data: Data) {
        guard data.count == Self.bytes else { return nil }
        let rev = data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let len = data.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        self.init(revision: rev, length: len)
    }
    var encoded: Data {
        var rev = revision.bigEndian, len = UInt32(length).bigEndian
        var data = withUnsafeBytes(of: &rev) { Data($0) }
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        return data
    }
    static func fitsPNG(_ data: Data) -> Bool {
        guard (minimumPayload...maximumPayload).contains(data.count),
              data.prefix(16).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]),
              data.suffix(12).elementsEqual([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]) else { return false }
        // Check dimensions before asking a framework to inspect foreign data.
        let dimensions = data.dropFirst(16).prefix(8)
        let width = dimensions.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let height = dimensions.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        return width > 0 && height > 0 && width <= maximumPixels / height
    }
    static func validPNG(_ data: Data) -> Bool {
        guard fitsPNG(data), let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1 else { return false }
        return true
    }
}

/// A second stream on the existing listening port, only while both peers have granted
/// clipboard access. Proof binds this TLS connection to the primary TLS session and
/// both current grants. No PNG bytes use the input socket or depend on a paste event.
@MainActor final class SharingClipboardImageLink {
    typealias Delivery = @MainActor (Data) -> Void
    let grants: SharingClipboardGrants
    private let primaryKey: SymmetricKey
    private let initiator: Bool
    private let beginImage: (UInt64) -> Delivery?
    private var connection: NWConnection?
    private var ready = false
    private var sendingRevision: UInt64?
    private var scheduledSend = false
    private var pending: (SharingClipboardImageHeader, Data)?
    private var handshakeDeadline: Task<Void, Never>?
    private var sendDeadline: Task<Void, Never>?
    private var readDeadline: Task<Void, Never>?
    private var validation: Task<Void, Never>?
    private var finished = false
    var stateChanged: (SharingClipboardImageStatus) -> Void = { _ in }

    init(grants: SharingClipboardGrants, primaryKey: SymmetricKey, initiator: Bool,
         beginImage: @escaping (UInt64) -> Delivery?) {
        self.grants = grants; self.primaryKey = primaryKey; self.initiator = initiator; self.beginImage = beginImage
    }
    isolated deinit { stop() }

    func startHandshakeDeadline() {
        guard handshakeDeadline == nil, !finished else { return }
        handshakeDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.fail()
        }
    }

    func open(to endpoint: NWEndpoint, parameters: NWParameters) {
        guard initiator, !finished, connection == nil else { return }
        attach(NWConnection(to: endpoint, using: parameters))
    }
    func accept(_ candidate: NWConnection) {
        guard !initiator, !finished, connection == nil else { candidate.cancel(); return }
        attach(candidate)
    }
    private func attach(_ candidate: NWConnection) {
        connection = candidate
        // Do not capture the connection in its own state handler.
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate else { return }
                switch state {
                case .ready: self.authenticate(candidate)
                case .failed, .cancelled: self.connectionEnded()
                default: break
                }
            }
        }
        candidate.start(queue: .main)
    }
    private func authenticate(_ candidate: NWConnection) {
        guard let bulk = SharingTransport.exporter(candidate, label: "Untitled clipboard bulk v1") else { connectionEnded(); return }
        var context = Data("Untitled clipboard channel binding v1".utf8)
        context.append(bulk)
        context.append(contentsOf: (initiator ? grants.local : grants.peer).uuidString.utf8)
        context.append(contentsOf: (initiator ? grants.peer : grants.local).uuidString.utf8)
        let mine = context + Data([initiator ? 1 : 2])
        let theirs = context + Data([initiator ? 2 : 1])
        candidate.send(content: Data(HMAC<SHA256>.authenticationCode(for: mine, using: primaryKey)), completion: .contentProcessed { [weak self, weak candidate] error in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate, error != nil else { return }
                self.connectionEnded()
            }
        })
        candidate.receive(minimumIncompleteLength: 32, maximumLength: 32) { [weak self, weak candidate] proof, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate else { return }
                guard !complete, error == nil, let proof, proof.count == 32,
                      HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: theirs, using: self.primaryKey) else {
                    self.connectionEnded(); return
                }
                self.handshakeDeadline?.cancel(); self.handshakeDeadline = nil
                self.ready = true
                self.stateChanged(.ready)
                self.receiveHeader(candidate)
                self.sendPending()
            }
        }
    }
    @discardableResult func offer(_ data: Data, revision: UInt64) -> Bool {
        guard !finished, let header = SharingClipboardImageHeader(revision: revision, length: data.count), !header.isAcknowledgement else { return false }
        pending = (header, data) // One latest copy behind the active transfer or handshake.
        if ready, sendingRevision == nil, !scheduledSend {
            scheduledSend = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduledSend = false; self.sendPending()
            }
        }
        return true
    }
    func discardPending() { pending = nil }
    private func sendPending() {
        guard ready, sendingRevision == nil, let connection, let (header, data) = pending else { return }
        pending = nil; sendingRevision = header.revision
        sendDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail()
        }
        connection.batch {
            connection.send(content: header.encoded, completion: .idempotent)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    if error != nil { self?.fail() }
                    // Local TCP acceptance is not delivery. Keep the sending slot
                    // occupied until the peer consumes or discards the frame.
                }
            })
        }
    }
    private func receiveHeader(_ candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: SharingClipboardImageHeader.bytes, maximumLength: SharingClipboardImageHeader.bytes) { [weak self, weak candidate] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate else { return }
                guard !complete, error == nil, let data, let header = SharingClipboardImageHeader(data: data) else { self.fail(); return }
                if header.isAcknowledgement {
                    guard self.sendingRevision == header.revision else { self.fail(); return }
                    self.sendingRevision = nil
                    self.sendDeadline?.cancel(); self.sendDeadline = nil
                    self.receiveHeader(candidate)
                    self.sendPending()
                } else {
                    self.receiveBody(header, from: candidate)
                }
            }
        }
    }
    private func receiveBody(_ header: SharingClipboardImageHeader, from candidate: NWConnection) {
        let deliver = beginImage(header.revision)
        guard connection === candidate else { return }
        readDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail()
        }
        candidate.receive(minimumIncompleteLength: header.length, maximumLength: header.length) { [weak self, weak candidate] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let candidate, self.connection === candidate else { return }
                self.readDeadline?.cancel(); self.readDeadline = nil
                guard !complete, error == nil, let data, data.count == header.length else { self.fail(); return }
                guard let deliver else { self.acknowledge(header, on: candidate); return }
                // Do not decompress pixels or let validation monopolize the input run loop.
                self.validation = Task { @MainActor [weak self, weak candidate] in
                    let check = Task.detached(priority: .utility) { !Task.isCancelled && SharingClipboardImageHeader.validPNG(data) }
                    let valid = await withTaskCancellationHandler { await check.value } onCancel: { check.cancel() }
                    guard let self, let candidate, self.connection === candidate, !Task.isCancelled else { return }
                    self.validation = nil
                    if valid { deliver(data) }
                    if self.connection === candidate { self.acknowledge(header, on: candidate) }
                }
            }
        }
    }
    private func acknowledge(_ header: SharingClipboardImageHeader, on candidate: NWConnection) {
        // The revision was validated when the header was parsed. An ACK
        // releases bulk backpressure, not a promise that the clipboard changed.
        guard let ack = SharingClipboardImageHeader(revision: header.revision, length: 0) else { return }
        candidate.send(content: ack.encoded, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated { if error != nil { self?.fail() } }
        })
        receiveHeader(candidate)
    }
    private func connectionEnded() {
        if initiator || ready { fail(); return }
        // A refused TLS/app proof must not consume the acceptor's grant. An
        // unrelated connection (or a closing previous grant) may arrive first.
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
    }
    private func fail() {
        guard !finished else { return }
        stop(); stateChanged(.unavailable)
    }
    func stop() {
        finished = true; ready = false; sendingRevision = nil; pending = nil
        handshakeDeadline?.cancel(); handshakeDeadline = nil
        sendDeadline?.cancel(); sendDeadline = nil
        readDeadline?.cancel(); readDeadline = nil
        validation?.cancel(); validation = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
    }
}
