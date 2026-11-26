import Foundation
import CoreGraphics
import AppKit
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor struct DictationTextDeliveryTests {
    @Test func validatingDoesNotChangeTheOriginalUTF16SelectionOrEmitInput() async throws {
        let value = "前😀选中👨‍👩‍👧‍👦后", selection = (value as NSString).range(of: "选中👨‍👩‍👧‍👦")
        let driver = Editor(value: value, selection: selection)
        let target = try await DictationTextTarget(editor: driver)
        for _ in 0..<35 { try await target.validate() }
        #expect(driver.current.value == value && driver.current.selection == selection && driver.insertions.isEmpty)
        let final = "下午 3 点，见面。"
        try await target.commitFinal(final)
        #expect(driver.current.value == "前😀" + final + "后")
        #expect(driver.current.selection == NSRange(location: selection.location + final.utf16.count, length: 0))
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal(final) }
        #expect(driver.insertions == [final] && target.acknowledgedLength == final.utf16.count)
    }

    @Test func cancelledTargetCannotEraseOrReplaceTheOriginalSelection() async throws {
        let selection = NSRange(location: 1, length: 2), driver = Editor(value: "前选中后", selection: selection)
        let target = try await DictationTextTarget(editor: driver)
        target.cancel()
        await #expect(throws: CancellationError.self) { try await target.commitFinal("迟到的结果") }
        #expect(driver.current.value == "前选中后" && driver.current.selection == selection && driver.insertions.isEmpty)
    }

    @Test func literalUtf16ChangeFailsEvenWhenTheEditorLooksIdentical() async throws {
        let selection = NSRange(location: 0, length: 0)
        let driver = Editor(value: "e\u{301}后", selection: selection)
        let target = try await DictationTextTarget(editor: driver)
        driver.current = .init(value: "é后", selection: selection)
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal("不能覆盖") }
        #expect(driver.insertions.isEmpty)
    }

    @Test func focusSelectionOrExternalEditsAreNeverRetargeted() async throws {
        for change in 0...2 {
            let selection = NSRange(location: 1, length: 2)
            let driver = Editor(value: "前选中后", selection: selection)
            let target = try await DictationTextTarget(editor: driver)
            switch change {
            case 0: driver.focused = false
            case 1: driver.current = .init(value: driver.current.value, selection: .init(location: 0, length: 0))
            default: driver.current = .init(value: "前手改后", selection: selection)
            }
            await #expect(throws: DictationTargetError.self) { try await target.validate() }
            await #expect(throws: DictationTargetError.self) { try await target.commitFinal("不能覆盖") }
            #expect(driver.insertions.isEmpty)
        }
    }

    @Test func concurrentFinalDuringASlowAcknowledgementCannotPostAgain() async throws {
        let driver = Editor(value: "前旧后", selection: NSRange(location: 1, length: 1))
        driver.delay = .milliseconds(850)
        let target = try await DictationTextTarget(editor: driver)
        let text = String(repeating: "明天下午 3 点，开会。", count: 80)
        let first = Task { try await target.commitFinal(text) }
        while driver.insertions.isEmpty { await Task.yield() }
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal("另一份定稿。") }
        try await first.value
        #expect(driver.current.value == "前" + text + "后" && driver.insertions == [text])
        #expect(target.acknowledgedLength == text.utf16.count)
    }

    @Test func anUnacknowledgedFinalCannotBeReplayedOrFragmented() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        driver.ignoreKeyboard = true
        let target = try await DictationTextTarget(editor: driver)
        let text = String(repeating: "定稿", count: 60)
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal(text) }
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal(text) }
        #expect(driver.insertions == [text] && driver.current.value.isEmpty && target.acknowledgedLength == 0)
    }

    @Test func cancellationAfterPostingNeverIssuesAdditionalInput() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        driver.delay = .seconds(5)
        let target = try await DictationTextTarget(editor: driver)
        let text = String(repeating: "中", count: 1500)
        let task = Task { try await target.commitFinal(text) }
        while driver.insertions.isEmpty { await Task.yield() }
        target.cancel(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.insertions == [text])
    }

    @Test func emptyOrUnsafeOnlyFinalCannotEraseTheOriginalSelection() async throws {
        for text in ["", "  ", "\u{1b}\t\n"] {
            let selection = NSRange(location: 1, length: 1)
            let driver = Editor(value: "前旧后", selection: selection)
            let target = try await DictationTextTarget(editor: driver)
            await #expect(throws: DictationTargetError.self) { try await target.commitFinal(text) }
            #expect(driver.current.value == "前旧后" && driver.current.selection == selection && driver.insertions.isEmpty)
        }
    }

    @Test func checkedUnicodeEventRetainsWholeFinalWithoutPosting() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        for count in [16, 67, 512, 4096, DoubaoASRLimits.textLength] {
            let text = String(repeating: "中", count: count)
            let event = try DictationUnicodeInput.keyDown(text, source: source)
            var actual = 0, units = [UniChar](repeating: 0, count: count)
            units.withUnsafeMutableBufferPointer {
                event.keyboardGetUnicodeString(maxStringLength: count, actualStringLength: &actual, unicodeString: $0.baseAddress)
            }
            #expect(actual == count && units.elementsEqual(text.utf16))
            let appKitEvent = try #require(NSEvent(cgEvent: event))
            #expect(appKitEvent.characters?.utf16.elementsEqual(text.utf16) == true)
        }
        let emoji = "定稿😀👨‍👩‍👧‍👦，完成。"
        let event = try DictationUnicodeInput.keyDown(emoji, source: source)
        var actual = 0, units = [UniChar](repeating: 0, count: emoji.utf16.count)
        units.withUnsafeMutableBufferPointer { event.keyboardGetUnicodeString(maxStringLength: emoji.utf16.count, actualStringLength: &actual, unicodeString: $0.baseAddress) }
        #expect(actual == emoji.utf16.count && units.elementsEqual(emoji.utf16))
        #expect(throws: DictationTargetError.self) { try DictationUnicodeInput.keyDown(String(repeating: "中", count: DoubaoASRLimits.textLength + 1), source: source) }
    }

    @Test func transientAXReadFailuresWaitWithoutResendingTheTypedText() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.unavailableAfterInsert = 3
        try await target.commitFinal("已经写入")
        #expect(driver.current.value == "已经写入")
        #expect(driver.insertions == ["已经写入"])
    }

    @Test func persistentAXReadFailureNeverResendsOrBlindlyDeletes() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.unavailableAfterInsert = 1000
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal("保留已输入") }
        #expect(driver.current.value == "保留已输入")
        #expect(driver.insertions == ["保留已输入"])
    }

    @Test func validationIgnoresSnapshotsMadeStaleByACompletedWrite() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.suspendNextSnapshot = true
        let validation = Task { try await target.validate() }
        while !driver.snapshotIsSuspended { await Task.yield() }
        try await target.commitFinal("新结果")
        driver.resumeSnapshot()
        try await validation.value
        #expect(driver.current.value == "新结果")
        #expect(driver.insertions == ["新结果"])
    }

    @Test func cancellationWhileReadingASnapshotPreventsKeyboardMutation() async throws {
        let driver = Editor(value: "原文", selection: NSRange(location: 2, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.suspendNextSnapshot = true
        let writing = Task { try await target.commitFinal("不应写入") }
        while !driver.snapshotIsSuspended { await Task.yield() }
        target.cancel()
        driver.resumeSnapshot()
        await #expect(throws: CancellationError.self) { try await writing.value }
        #expect(driver.current.value == "原文" && driver.insertions.isEmpty)
    }

    @Test func transcriptionControlCharactersNeverBecomeSendOrNavigationKeys() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        try await target.commitFinal("第一行\n第二行\t不要发送\u{1b}\r\n")
        #expect(driver.current.value == "第一行 第二行 不要发送   ")
        #expect(driver.insertions.allSatisfy { text in !text.unicodeScalars.contains { $0.properties.generalCategory == .control } })
    }

    private final class Editor: DictationEditor {
        var current: DictationEditorSnapshot
        var delay: Duration = .zero
        var ignoreKeyboard = false
        var focused = true
        var unavailableAfterInsert = 0
        private var unavailableSnapshots = 0
        var suspendNextSnapshot = false
        var snapshotIsSuspended: Bool { suspended != nil }
        private var suspended: (DictationEditorSnapshot, CheckedContinuation<DictationEditorSnapshot, Never>)?
        private(set) var insertions: [String] = []
        private var pending: (DictationEditorSnapshot, ContinuousClock.Instant)?
        init(value: String, selection: NSRange) { current = .init(value: value, selection: selection) }
        func validateFocus() throws { if !focused { throw DictationTargetError.changed } }
        func snapshot() async throws -> DictationEditorSnapshot {
            if unavailableSnapshots > 0 { unavailableSnapshots -= 1; throw DictationTargetError.unavailable }
            let value = try readSnapshot()
            guard suspendNextSnapshot else { return value }
            suspendNextSnapshot = false
            return await withCheckedContinuation { suspended = (value, $0) }
        }
        func resumeSnapshot() {
            guard let suspended else { return }
            self.suspended = nil
            suspended.1.resume(returning: suspended.0)
        }
        private func readSnapshot() throws -> DictationEditorSnapshot {
            try validateFocus()
            if let pending, ContinuousClock.now >= pending.1 { current = pending.0; self.pending = nil }
            return current
        }
        func insert(_ text: String, replacing expected: DictationEditorSnapshot) throws {
            try require(expected)
            insertions.append(text)
            guard !ignoreKeyboard else { return }
            try replace(text)
            unavailableSnapshots = unavailableAfterInsert
        }
        private func require(_ expected: DictationEditorSnapshot) throws {
            let actual = try readSnapshot()
            guard actual.value.utf16.elementsEqual(expected.value.utf16), actual.selection == expected.selection else { throw DictationTargetError.changed }
        }
        private func replace(_ text: String) throws {
            let value = (current.value as NSString).replacingCharacters(in: current.selection, with: text)
            try change(.init(value: value, selection: .init(location: current.selection.location + text.utf16.count, length: 0)))
        }
        private func change(_ value: DictationEditorSnapshot) throws {
            _ = try readSnapshot()
            guard pending == nil else { throw DictationTargetError.unconfirmed }
            if delay == .zero { current = value }
            else { pending = (value, ContinuousClock.now.advanced(by: delay)) }
        }
    }
}
