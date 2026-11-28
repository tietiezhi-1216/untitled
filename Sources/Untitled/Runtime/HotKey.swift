import Carbon
import Foundation
import CoreGraphics
import IOKit.hidsystem

enum ShortcutInputKind: String, Codable, Hashable, CaseIterable, Sendable {
    case singleKey, keyCombination, mouseButton
    static let all = Set(allCases)
    static let keyboard: Set<Self> = [.singleKey, .keyCombination]
}

struct HotKey: Codable, Hashable, Sendable {
    // Keep the old keyboard JSON unchanged. Mouse bindings never encode a keyCode:
    // an older host must not mistake button 3 for the F key.
    let keyCode: UInt32?
    let modifiers: UInt32
    private let key: String?
    let mouseButton: UInt32?
    static let sideButtons: ClosedRange<UInt32> = 3...31
    static let validModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key; mouseButton = nil
    }
    init(mouseButton: UInt32, modifiers: UInt32 = 0) {
        self.mouseButton = mouseButton; self.modifiers = modifiers; keyCode = nil; key = nil
    }
    static let rightCommand = HotKey(keyCode: UInt32(kVK_RightCommand), modifiers: 0, key: "右 ⌘")
    static let rightControl = HotKey(keyCode: UInt32(kVK_RightControl), modifiers: 0, key: "右 ⌃")
    var isRightCommand: Bool { self == Self.rightCommand }
    var isRightControl: Bool { self == Self.rightControl }
    var isStandaloneModifier: Bool { isRightCommand || isRightControl }

    // Aggregate .maskCommand stays set when one of the two Command keys is released.
    static func rightCommandDown(_ flags: CGEventFlags, fallback: () -> Bool) -> Bool {
        guard flags.contains(.maskCommand) else { return false }
        let sides = flags.rawValue & UInt64(NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK)
        return sides == 0 ? fallback() : sides & UInt64(NX_DEVICERCMDKEYMASK) != 0
    }
    static func rightCommandAlone(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.rawValue & UInt64(NX_DEVICELCMDKEYMASK) == 0 &&
            flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskSecondaryFn, .maskHelp]).isEmpty
    }
    static func rightControlAlone(_ flags: CGEventFlags, leftControlDown: Bool) -> Bool {
        flags.contains(.maskControl) && !leftControlDown &&
            flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn, .maskHelp]).isEmpty
    }
    var standaloneModifierCode: UInt32? {
        if isRightCommand { return UInt32(kVK_RightCommand) }
        if isRightControl { return UInt32(kVK_RightControl) }
        return nil
    }
    var supportsLegacyHosts: Bool { mouseButton == nil && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 }
    var inputKind: ShortcutInputKind {
        mouseButton != nil ? .mouseButton : (modifiers == 0 ? .singleKey : .keyCombination)
    }

    var display: String {
        if isRightCommand { return "右 ⌘" }
        if isRightControl { return "右 ⌃" }
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        if let button = mouseButton, Self.sideButtons.contains(button) { return prefix + "鼠标侧键 \(button - 2)" }
        return prefix + (key ?? "")
    }

    var identity: String {
        if let button = mouseButton { return "mouse:\(button):\(modifiers)" }
        return "\(keyCode.map(String.init) ?? "?"):\(modifiers)"
    }

    func validate(allowedInputs: Set<ShortcutInputKind> = ShortcutInputKind.all) throws {
        guard modifiers & ~Self.validModifiers == 0 else { throw PluginError.invalid("快捷键的修饰键无效。") }
        if let mouseButton {
            guard keyCode == nil, key == nil, Self.sideButtons.contains(mouseButton) else {
                throw PluginError.invalid("请选择有效的鼠标侧键。")
            }
        } else {
            guard let keyCode, keyCode < 128, let key, !key.isEmpty, key.count <= 20 else {
                throw PluginError.invalid("请选择有效的键盘按键。")
            }
        }
        guard allowedInputs.contains(inputKind) else { throw PluginError.invalid("此插件不接受这种快捷键。") }
    }
}


@MainActor enum HotKeyRecordingSession {
    static let changed = Notification.Name("Untitled.hotKeyRecordingChanged")
    private(set) static var isRecording = false
    static func setRecording(_ value: Bool) {
        guard isRecording != value else { return }
        isRecording = value
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
