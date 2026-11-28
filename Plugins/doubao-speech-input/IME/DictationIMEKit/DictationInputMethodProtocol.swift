import CoreGraphics
import CryptoKit
import Foundation

/// One authenticated local connection per utterance. Never send audio or surrounding text.
public enum DictationIME {
    public static let sourceID = "com.untitled.app.inputmethod.Dictation"
    public static let hostID = "com.untitled.app"
    public static let bundleName = "UntitledDictationInputMethod.app"
    public static let textLimit = 32_768
    public static let frameLimit = 256 * 1024
    public static func digest(_ string: String) -> Data { Data(SHA256.hash(data: Data(string.utf8))) }
    public static func literal(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
}

public struct DictationIMEFocus: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public let selection: NSRange
    public init(pid: Int32, bundleID: String, selection: NSRange) {
        self.pid = pid; self.bundleID = bundleID; self.selection = selection
    }
}

/// Distinguish even empty fields in the same app. AX and IMK must independently identify
/// the same caret on screen and the same document. A client that cannot attest these is refused.
public struct DictationIMEProof: Codable, Sendable {
    public let documentLength: Int
    public let digest: Data
    public let caret: CGRect // Global AppKit coordinates, zero-length range at original selection start.
    public init(value: String, caret: CGRect) {
        documentLength = value.utf16.count; digest = DictationIME.digest(value); self.caret = caret
    }
    public func accepts(_ rect: CGRect?) -> Bool {
        guard let rect, !rect.isNull, !caret.isNull, rect.height > 0, caret.height > 0 else { return false }
        return abs(rect.minX - caret.minX) <= 2 && abs(rect.midY - caret.midY) <= 2
    }
}

public struct DictationIMERequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case begin, mark, commit }
    public let id: UUID
    public let session: UUID
    public let operation: Operation
    public let focus: DictationIMEFocus?
    public let proof: DictationIMEProof
    public let text: String?
    public let expires: UInt64 // Same machine, monotonic. A stale queued request must never write.
    public init(session: UUID, operation: Operation, focus: DictationIMEFocus? = nil, proof: DictationIMEProof, text: String? = nil) {
        id = UUID(); self.session = session; self.operation = operation; self.focus = focus; self.proof = proof; self.text = text
        expires = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    }
}

public struct DictationIMEReply: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, waitingForClient, changed, unconfirmed }
    public let id: UUID
    public let status: Status
    public init(id: UUID, status: Status) { self.id = id; self.status = status }
}

/// Wraps exactly one activation of one IMK client, not just an app or the last controller created.
@MainActor public protocol DictationCompositionClient: AnyObject {
    func matches(_ focus: DictationIMEFocus) -> Bool
    var selection: NSRange { get }
    var marked: NSRange { get }
    var length: Int { get }
    func caret(at offset: Int) -> CGRect?
    func text(at range: NSRange) -> String?
    func mark(_ text: String)
    func insert(_ text: String)
}

@MainActor public final class DictationComposition {
    public let session: UUID
    public let focus: DictationIMEFocus
    private let client: any DictationCompositionClient
    private var draft: String?
    private var ended = false
    public init?(session: UUID, focus: DictationIMEFocus, proof: DictationIMEProof, client: any DictationCompositionClient) {
        self.session = session; self.focus = focus; self.client = client
        let range = focus.selection
        guard range.location >= 0, range.location <= 131_072, range.length >= 0,
              range.length <= 131_072 - range.location, NSMaxRange(range) <= proof.documentLength, owns(proof) else { return nil }
    }
    private func ownsMark() -> Bool {
        if let draft {
            let range = NSRange(location: focus.selection.location, length: draft.utf16.count)
            return client.marked == range && client.selection == NSRange(location: NSMaxRange(range), length: 0)
                && client.text(at: range).map { DictationIME.literal($0, draft) } == true
        }
        // NSTextView also reports {documentLength, 0} for no inline area, not just NSNotFound.
        let mark = client.marked
        return (mark.location == NSNotFound || mark == NSRange(location: client.length, length: 0)) && client.selection == focus.selection
    }
    private func owns(_ proof: DictationIMEProof) -> Bool {
        guard !ended, client.matches(focus), (0...196_608).contains(proof.documentLength),
              client.length == proof.documentLength, proof.accepts(client.caret(at: focus.selection.location)), ownsMark() else { return false }
        let value = proof.documentLength == 0 ? "" : client.text(at: NSRange(location: 0, length: proof.documentLength))
        return value.map(DictationIME.digest) == proof.digest && client.matches(focus) && !ended
    }
    public func apply(_ request: DictationIMERequest) -> DictationIMEReply.Status {
        guard request.session == session, request.operation != .begin, let text = request.text, !text.isEmpty,
              text.utf16.count <= DictationIME.textLimit, owns(request.proof),
              DispatchTime.now().uptimeNanoseconds < request.expires else { invalidate(); return .changed }
        if request.operation == .commit {
            // Reentrant commitComposition/deactivation or a lost reply must never issue a second insert.
            invalidate(); client.insert(text); return .ok // Host independently checks the complete value/caret.
        }
        if let draft, DictationIME.literal(draft, text) { return .ok }
        client.mark(text); draft = text
        guard !ended, client.matches(focus), ownsMark() else { invalidate(); return .unconfirmed }
        return .ok
    }
    /// Cancellation, lost connection and system-requested commit never insert, erase, or replay text.
    /// On a change of input source the client determines what to do with its existing mark.
    public func invalidate() { ended = true; draft = nil }
}
