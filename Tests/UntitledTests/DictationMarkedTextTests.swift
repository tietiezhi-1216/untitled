import AppKit
import DictationIMEKit
import Testing
import UntitledPluginSDK
@testable import UntitledHost
@testable import UntitledPluginCapture
@testable import UntitledPluginSharing
@testable import UntitledPluginSpeech
@testable import UntitledComposition

/// Real NSTextInputClient composition in an offscreen, test-owned NSTextView. No user editor,
/// TIS selection, physical keyboard/mouse events, microphone, editor automation, or clipboard.
@MainActor struct DictationMarkedTextTests {
    final class Fixture: DictationCompositionClient, DictationEditor, DictationMarkedBridge {
        let view = NSTextView(frame: .init(x: 0, y: 0, width: 320, height: 100))
        var rect = CGRect(x: 90, y: 80, width: 0, height: 18)
        var expectedRect: CGRect?, active = true, failReply = false, switchAfterBegin = false
        var marks = 0, commits = 0, requests = 0, ordinaryWrites = 0
        var composition: DictationComposition?
        var selection: NSRange { view.selectedRange() }
        var marked: NSRange { view.markedRange() }
        var length: Int { view.string.utf16.count }
        func matches(_ focus: DictationIMEFocus) -> Bool { active && focus.pid == 42 && focus.bundleID == "example.test" }
        func caret(at offset: Int) -> CGRect? { rect }
        func text(at range: NSRange) -> String? { (view.string as NSString).substring(with: range) }
        func mark(_ text: String) {
            marks += 1
            view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        }
        func insert(_ text: String) { commits += 1; view.insertText(text, replacementRange: .init(location: NSNotFound, length: 0)) }
        init(_ text: String = "左原文右", selection: NSRange = .init(location: 1, length: 2)) {
            view.isRichText = false; view.string = text; view.setSelectedRange(selection)
        }
        func validateFocus() async throws { if !active { throw DictationTargetError.changed } }
        func snapshot() async throws -> DictationEditorSnapshot {
            try await validateFocus(); return .init(value: view.string, selection: selection)
        }
        func compositionCaret(at offset: Int) async throws -> CGRect { expectedRect ?? rect }
        func select(_ range: NSRange) async throws -> Bool { ordinaryWrites += 1; return false }
        func selectBackward(_ characters: Int) async throws { ordinaryWrites += 1 }
        func insert(_ text: String, replacing snapshot: DictationEditorSnapshot) async throws { ordinaryWrites += 1 }
        func deleteSelection(matching snapshot: DictationEditorSnapshot) async throws { ordinaryWrites += 1 }
        func begin(session: UUID, focus: DictationIMEFocus, proof: DictationIMEProof) async throws {
            composition = try #require(DictationComposition(session: session, focus: focus, proof: proof, client: self))
            if switchAfterBegin { active = false }
        }
        func send(_ request: DictationIMERequest) async throws {
            requests += 1
            guard composition?.apply(request) == .ok, !failReply else { throw DictationTargetError.unconfirmed }
        }
        func validate() throws { guard active else { throw DictationTargetError.changed } }
        func close() { composition?.invalidate(); composition = nil }
        func target() async throws -> DictationMarkedTextTarget {
            try await .init(editor: self, snapshot: snapshot(), pid: 42, bundleID: "example.test", bridge: self)
        }
    }

    @Test func twoRevisionsReplaceOneAppKitMarkAndFinalCommitsExactlyOnce() async throws {
        let f = Fixture(), target = try await f.target()
        try await target.update("你"); #expect(f.view.hasMarkedText() && f.marked == NSRange(location: 1, length: 1))
        try await target.update("你好👩🏽‍💻"); try await target.update("你好👩🏽‍💻")
        #expect(f.marked == NSRange(location: 1, length: "你好👩🏽‍💻".utf16.count))
        #expect(f.view.string == "左你好👩🏽‍💻右" && f.marks == 2 && f.commits == 0)
        target.prepareForFinal(); try await target.update("过期草稿")
        try await target.commitFinal("你好，你好。")
        #expect(!f.view.hasMarkedText() && f.view.string == "左你好，你好。右" && f.commits == 1)
        await #expect(throws: CancellationError.self) { try await target.commitFinal("你好，你好。") }
        target.cancel(); #expect(f.commits == 1 && f.ordinaryWrites == 0)
    }
    @Test func identicalFinalStillUnmarksAndFinalWithoutDraftReplacesOnlySelection() async throws {
        for draft in [false, true] {
            let f = Fixture(), t = try await f.target()
            if draft { try await t.update("你好") }; try await t.commitFinal("你好")
            #expect(f.view.string == "左你好右" && !f.view.hasMarkedText() && f.commits == 1 && f.ordinaryWrites == 0)
        }
    }
    @Test func cancellationBeforeAndAfterMarkDoesNotInsertTheSelectionOrLastDraft() async throws {
        for draft in [false, true] {
            let f = Fixture(), t = try await f.target()
            if draft { try await t.update("拟稿") }; t.cancel(); t.cancel()
            #expect(f.view.string == (draft ? "左拟稿右" : "左原文右") && f.commits == 0 && f.ordinaryWrites == 0)
        }
    }
    @Test func lostFinalAcknowledgementDoesNotReplayUnderEitherWriter() async throws {
        let f = Fixture(), t = try await f.target(); try await t.update("草稿"); f.failReply = true
        await #expect(throws: DictationTargetError.self) { try await t.commitFinal("定稿。") }
        await #expect(throws: CancellationError.self) { try await t.commitFinal("定稿。") }
        #expect(f.view.string == "左定稿。右" && f.requests == 2 && f.commits == 1 && f.ordinaryWrites == 0)
    }
    @Test func originalFieldIsRecheckedAfterActivationAndBeforeEveryWrite() async throws {
        let f = Fixture(), t = try await f.target(); f.switchAfterBegin = true
        await #expect(throws: DictationTargetError.self) { try await t.update("不应写入") }
        #expect(f.requests == 0 && f.view.string == "左原文右")
        for change in 0..<4 {
            let f = Fixture(), t = try await f.target(); try await t.update("草稿")
            switch change {
            case 0: f.active = false // Secure input, different activation or focus loss.
            case 1: f.view.setSelectedRange(.init(location: 0, length: 0))
            case 2: f.view.unmarkText() // Same value AND caret, but the mark belongs to no one now.
            default: f.view.string = "同草稿右" // External edit outside of our span.
            }
            let before = f.view.string
            await #expect(throws: DictationTargetError.self) { try await t.commitFinal("不应写入") }
            #expect(f.commits == 0 && f.view.string == before && f.ordinaryWrites == 0)
        }
    }
    @Test func twoIdenticalEmptyFieldsAndForeignMarksCannotBeAdopted() throws {
        let a = Fixture("", selection: .init(location: 0, length: 0)), b = Fixture("", selection: .init(location: 0, length: 0))
        b.rect.origin.y -= 24
        let focus = DictationIMEFocus(pid: 42, bundleID: "example.test", selection: a.selection)
        let proof = DictationIMEProof(value: a.view.string, caret: a.rect)
        #expect(DictationComposition(session: UUID(), focus: focus, proof: proof, client: b) == nil)
        let id = UUID(), session = try #require(DictationComposition(session: id, focus: focus, proof: proof, client: a))
        a.mark("别的输入法")
        #expect(session.apply(.init(session: id, operation: .mark, proof: proof, text: "不覆盖")) == .changed)
        #expect(a.view.string == "别的输入法" && a.commits == 0 && b.marks == 0)
    }
    @Test func inputSourceRestoreRespectsManualSwitchAndPreexistingSelection() throws {
        let ime = DictationIME.sourceID
        for scenario in 0..<5 {
            var selected = scenario == 0 ? ime : "previous", actions: [String] = []
            let lease = DictationInputSourceLease(current: { selected }, select: { selected = $0; actions.append($0); return true })
            if scenario == 4 { selected = "changed before first draft"; #expect(throws: DictationTargetError.self) { try lease.acquire() }; #expect(actions.isEmpty); continue }
            try lease.acquire()
            if scenario >= 2 { selected = "manual"; #expect(throws: DictationTargetError.self) { try lease.check() } }
            if scenario == 3 { selected = ime } // Do not regain ownership if the user switches back.
            lease.restore(); lease.restore()
            #expect(actions == (scenario == 0 ? [] : scenario == 1 ? [ime, "previous"] : [ime]))
        }
    }
    @Test func boundedLocalFrameAndRevocationUseRealPrivateSocketPair() async throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        fds.forEach(DictationIMESocket.configure)
        let a = try DictationIMEChannel(taking: fds[0]), b = try DictationIMEChannel(taking: fds[1]); defer { a.close(); b.close() }
        #expect(a.peerIsOpen && b.peerIsOpen)
        await #expect(throws: (any Error).self) { try await a.send(String(repeating: "界", count: DictationIME.frameLimit)) }
        let message = DictationIMEReply(id: UUID(), status: .ok); try await a.send(message)
        let received = try await b.receive(DictationIMEReply.self); #expect(received.id == message.id)
        a.close(); #expect(!b.peerIsOpen)
        await #expect(throws: (any Error).self) { _ = try await b.receive(DictationIMERequest.self) }
    }
}
