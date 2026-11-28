import Darwin
import Foundation
import Security
import os

/// Private AF_UNIX connection to the *system-launched* IME. Knowing the socket path is not
/// authorization: both ends check uid and the kernel peer audit token against a signing requirement.
public enum DictationIMESocket {
    enum Failure: Error { case unavailable, signature, frame }
    public static func endpoint(pid: pid_t) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("untitled-im-\(pid).sock").path
    }
    private static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.unavailable }
        addr.sun_family = sa_family_t(AF_UNIX); addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let length = socklen_t(addr.sun_len)
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) } }
    }
    private static func fresh() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        configure(fd); return fd
    }
    public static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    public static func listen(at path: String) throws -> Int32 {
        let fd = try fresh()
        do {
            // PID-specific in Darwin's user-private temporary directory. Only unlink a stale socket.
            var s = stat()
            if lstat(path, &s) == 0 {
                guard s.st_uid == geteuid(), s.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else { throw Failure.unavailable }
            }
            guard try address(path, { bind(fd, $0, $1) }) == 0 else { throw Failure.unavailable }
            guard chmod(path, 0o600) == 0, Darwin.listen(fd, 2) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                unlink(path); throw Failure.unavailable
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    public static func connect(to pid: pid_t) throws -> Int32 {
        let fd = try fresh()
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                  try address(endpoint(pid: pid), { Darwin.connect(fd, $0, $1) }) == 0 else { throw Failure.unavailable }
            try verify(fd, id: DictationIME.sourceID, pid: pid)
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    public static func verify(_ fd: Int32, id: String, pid: pid_t? = nil) throws {
        var uid: uid_t = 0, gid: gid_t = 0, token = audit_token_t(), size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0, Int(size) == MemoryLayout<audit_token_t>.size,
              let requirement = requirement(for: id) else { throw Failure.signature }
        if let pid {
            var actual: pid_t = 0, count = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &actual, &count) == 0, actual == pid else { throw Failure.signature }
        }
        let audit = withUnsafeBytes(of: token) { Data($0) }
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &peer) == errSecSuccess,
              let peer, SecCodeCheckValidity(peer, [], requirement) == errSecSuccess else { throw Failure.signature }
    }
    private static let team: String? = {
        var me: SecCode?, code: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }()
    public static func requirement(for id: String) -> SecRequirement? {
        guard let team, [DictationIME.sourceID, DictationIME.hostID].contains(id) else { return nil }
        let rule = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
        var req: SecRequirement?
        return SecRequirementCreateWithString(rule as CFString, [], &req) == errSecSuccess ? req : nil
    }
}

/// One in-flight request/response, binary length prefix. No line reader, unbounded message queue,
/// blocking pipe write on the main actor, public notification payload or on-disk transcript.
@MainActor public final class DictationIMEChannel {
    private let stream: DispatchIO
    private let fd: Int32
    private var closed = false
    private static let queue = DispatchQueue(label: "com.untitled.app.ime-io")
    public init(taking fd: Int32) throws {
        // DispatchIO may relinquish its descriptor asynchronously. Own a distinct descriptor for
        // revocation/peer checks, so a cleanup callback cannot race a reused descriptor number.
        let control = dup(fd)
        guard control >= 0 else { Darwin.close(fd); throw DictationIMESocket.Failure.unavailable }
        DictationIMESocket.configure(control); self.fd = control
        stream = DispatchIO(type: .stream, fileDescriptor: fd, queue: Self.queue) { @Sendable _ in Darwin.close(fd) }
    }
    public func close() {
        guard !closed else { return }; closed = true
        _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd); stream.close(flags: .stop)
    }
    public var peerIsOpen: Bool {
        guard !closed else { return false }
        var byte: UInt8 = 0
        let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result > 0 || (result < 0 && (errno == EWOULDBLOCK || errno == EAGAIN))
    }
    isolated deinit { close() }

    public func send<T: Encodable>(_ value: T) async throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count > 0, payload.count <= DictationIME.frameLimit else { throw DictationIMESocket.Failure.frame }
        var count = UInt32(payload.count).bigEndian
        var bytes = withUnsafeBytes(of: &count) { Data($0) }; bytes.append(payload)
        let packet = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            stream.write(offset: 0, data: packet, queue: Self.queue) { @Sendable done, _, error in
                if done { if error == 0 { reply.resume() } else { reply.resume(throwing: DictationIMESocket.Failure.unavailable) } }
            }
        }
    }
    private func read(_ count: Int) async throws -> Data {
        // DispatchIO calls this block serially on queue. Keep the accumulator scoped to THIS read.
        let buffer = OSAllocatedUnfairLock(initialState: Data())
        return try await withCheckedThrowingContinuation { reply in
            stream.read(offset: 0, length: count, queue: Self.queue) { @Sendable done, chunk, error in
                if let chunk { buffer.withLock { $0.append(contentsOf: chunk) } }
                guard done else { return }
                let data = buffer.withLock { $0 }
                if error == 0, data.count == count { reply.resume(returning: data) }
                else { reply.resume(throwing: DictationIMESocket.Failure.unavailable) }
            }
        }
    }
    public func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let header = try await read(4)
        let count = Int(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard (1...DictationIME.frameLimit).contains(count) else { throw DictationIMESocket.Failure.frame }
        return try await JSONDecoder().decode(type, from: read(count))
    }
}
