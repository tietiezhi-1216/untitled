import AppKit
import Carbon
import Testing
@testable import Untitled

@Suite(.serialized)
struct CaptureWorkflowTests {
    private func manifest() throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
    }
    @Test func onlyThreeDefaultsAreInstalledAndConflictsAreNotStolen() throws {
        let manifest = try manifest()
        try manifest.validate()
        var plugin = InstalledPlugin(manifest: manifest, commands: [])
        let conflicts = plugin.initializeDefaultCommands(occupiedHotKeys: ["18:4096"])
        #expect(conflicts == ["区域截图"])
        let expected: [ActionKind: String] = [.pinSelection: "19:4096", .restorePin: "20:4096"]
        #expect(plugin.commands.count == 3)
        #expect(plugin.commands.first { $0.action == .captureRegion }?.hotKey == nil)
        for (action, identity) in expected { #expect(plugin.commands.first { $0.action == action }?.hotKey?.identity == identity) }
    }
    @Test @MainActor func captureUsesSharedGlobalRegistrationAndKeepsKeyboardPinLocal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureRouting-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let screenshot = try manifest()
        let drivers = (screenshot.permissions ?? []).map { permission in
            HostPermissionDriver(descriptor: .init(id: permission.id, title: "Test", summary: "Test", symbol: "lock"),
                                 status: { .notGranted }, request: {}, openSettings: {})
        }
        var registrations: [String: Bool] = [:]
        let store = PluginStore(directory: folder, captureDirectory: folder.appendingPathComponent("Capture"),
                                permissions: HostPermissionCenter(drivers: drivers), ordinaryHotKeyDriver: .init(register: { key, exclusive, _ in
            registrations[key.identity] = exclusive
            return { _ = registrations.removeValue(forKey: key.identity) }
        }))
        try store.installManifest(screenshot)
        #expect(registrations == ["18:4096": false, "20:4096": false])
        #expect(store.matchesSelectionPinShortcut(keyCode: 19, modifiers: UInt32(controlKey), pluginID: screenshot.id))

        var pin = try #require(store.installed.first?.commands.first { $0.action == .pinSelection })
        pin.hotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), key: "P")
        try store.saveCommand(pin, pluginID: screenshot.id)
        #expect(!store.matchesSelectionPinShortcut(keyCode: 19, modifiers: UInt32(controlKey), pluginID: screenshot.id))
        #expect(store.matchesSelectionPinShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), pluginID: screenshot.id))
        #expect(registrations == ["18:4096": false, "20:4096": false])
        store.setHotKeysPaused(true)
        #expect(registrations.isEmpty)
        #expect(!store.matchesSelectionPinShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), pluginID: screenshot.id))
    }
    @Test func upgradingPreservesCustomClearedDisabledAndDeletedDefaults() throws {
        var legacy = PluginCommand(action: .captureRegion, hotKey: HotKey(keyCode: 15, modifiers: UInt32(cmdKey), key: "R"), isEnabled: false)
        legacy.target = ""
        var plugin = InstalledPlugin(manifest: try manifest(), commands: [legacy])
        #expect(plugin.initializeDefaultCommands().isEmpty)
        #expect(plugin.commands.first?.id == legacy.id)
        #expect(plugin.commands.first?.hotKey == legacy.hotKey)
        #expect(plugin.commands.first?.isEnabled == false)
        let pinIndex = try #require(plugin.commands.firstIndex { $0.action == .pinSelection })
        plugin.commands[pinIndex].hotKey = nil
        plugin.commands.removeAll { $0.action == .restorePin }
        let saved = plugin.commands
        _ = plugin.initializeDefaultCommands()
        #expect(plugin.commands == saved)
        let decoded = try JSONDecoder().decode(InstalledPlugin.self, from: JSONEncoder().encode(plugin))
        #expect(decoded == plugin)
        #expect(plugin.initializeDefaultCommands(restoring: true).isEmpty)
        #expect(plugin.commands.count == 3)
        #expect(plugin.commands.first { $0.action == .captureRegion }?.hotKey?.identity == "18:4096")
    }
    @Test func restoringSwappedDefaultsDoesNotReportFalseConflicts() throws {
        var plugin = InstalledPlugin(manifest: try manifest(), commands: [])
        plugin.initializeDefaultCommands()
        let first = plugin.commands[0].hotKey
        plugin.commands[0].hotKey = plugin.commands[1].hotKey
        plugin.commands[1].hotKey = first
        #expect(plugin.initializeDefaultCommands(restoring: true).isEmpty)
        #expect(Set(plugin.commands.compactMap { $0.hotKey?.identity }).count == 3)
    }
    @Test @MainActor func upgradingOldScreenshotActionsKeepsTheThreeBindingsAndDropsOnlyRetiredCommands() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutUpgrade-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let updated = try manifest()
        let legacyActions: [ActionKind] = [.captureRegion, .pinClipboard, .restorePin, .captureDelayed, .cyclePinGroup]
        let legacyTemplates = zip(["region", "pin", "restore-pin", "delayed", "cycle-group"], legacyActions).map { id, action in
            CommandTemplate(id: id, title: action.title, action: action)
        }
        let legacy = PluginManifest(schemaVersion: 2, id: updated.id, name: updated.name, version: "1.9.5",
                                    summary: updated.summary, author: updated.author, repository: updated.repository,
                                    minimumHostVersion: "0.13.5", actions: legacyActions, templates: legacyTemplates,
                                    ui: .init(slots: ["content": [.component("commands", "host.commands")]]),
                                    permissions: updated.permissions)
        let store = PluginStore(directory: folder, captureDirectory: folder.appendingPathComponent("Capture"),
                                ordinaryHotKeyDriver: .init(register: { _, _ in {} }))
        try store.installManifest(legacy)
        let other = try JSONDecoder().decode(PluginManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Plugins/global-shortcuts/manifest.json")))
        try store.installManifest(other)
        let otherBefore = try Data(contentsOf: folder.appendingPathComponent(other.id + ".json"))
        let region = PluginCommand(action: .captureRegion, hotKey: HotKey(keyCode: 15, modifiers: UInt32(cmdKey), key: "R"),
                                   isEnabled: false, templateID: "region")
        let pin = PluginCommand(action: .pinClipboard, hotKey: nil, templateID: "pin")
        for command in [region, pin, PluginCommand(action: .captureDelayed), PluginCommand(action: .cyclePinGroup)] {
            try store.saveCommand(command, pluginID: updated.id)
        }
        try store.installManifest(updated)
        let config = try #require(store.installed.first { $0.id == updated.id })
        #expect(config.commands.map(\.action) == [.captureRegion, .pinSelection, .restorePin])
        #expect(config.commands[0] == region)
        #expect(config.commands[1].id == pin.id && config.commands[1].hotKey == nil)
        #expect(config.commands[2].hotKey?.identity == "20:4096")
        #expect(throws: PluginError.self) { try store.saveCommand(PluginCommand(action: .captureWindow), pluginID: updated.id) }
        #expect(throws: PluginError.self) {
            try store.saveCommand(PluginCommand(action: .pinSelection, templateID: "pin"), pluginID: updated.id)
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent(other.id + ".json")) == otherBefore)
    }
    @Test @MainActor func localBindingsAreScopedAndClearedBindingsPersist() throws {
        let name = "CaptureShortcutsTest-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureShortcutSettings(defaults: defaults)
        #expect(settings.action(keyCode: 49, modifiers: 0, scope: .editor) == .hideToolbar)
        #expect(settings.action(keyCode: 49, modifiers: 0, scope: .pin) == .pinAnnotate)
        #expect(settings.binding(.redo)?.identity == "16:256")
        #expect(settings.binding(.clearMarks)?.identity == "6:768")
        #expect(throws: PluginError.self) { try settings.set(CaptureShortcutAction.copy.defaultKey, for: .save) }
        try settings.set(nil, for: .copy)
        #expect(CaptureShortcutSettings(defaults: defaults).binding(.copy) == nil)
        settings.restoreDefaults()
        #expect(settings.binding(.copy) == CaptureShortcutAction.copy.defaultKey)
        for scope in [CaptureShortcutScope.editor, .pin] {
            let keys = CaptureShortcutAction.allCases.filter { $0.scopes.contains(scope) }.compactMap { settings.binding($0)?.identity }
            #expect(Set(keys).count == keys.count)
        }
    }
    @Test @MainActor func allLegacyGroupsLoadAndClosedPinsRestoreFromNewestToOldest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PinTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(CaptureImage.context(width: 100, height: 80).makeImage())
        let manager = CapturePinManager(directory: folder, displaysWindows: false)
        let newest = try manager.create(image, text: "legacy")
        let older = try manager.create(image)
        let open = try manager.create(image)
        manager.toggleAll()
        #expect(manager.records.allSatisfy { $0.isOpen })
        manager.close(older)
        manager.close(newest)
        manager.toggle(newest, \.locked)
        manager.toggle(newest, \.clickThrough)
        let file = folder.appendingPathComponent("pins.json")
        var oldArchive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var rows = try #require(oldArchive["records"] as? [[String: Any]])
        let work = UUID().uuidString
        rows[0]["groupID"] = work
        rows[2]["groupID"] = work
        let firstClosedAt = try #require(rows[0]["closedAt"] as? Double)
        rows[1]["closedAt"] = firstClosedAt - 60
        oldArchive["records"] = rows
        var groups = try #require(oldArchive["groups"] as? [[String: Any]])
        groups.append(["id": work, "name": "工作"])
        oldArchive["groups"] = groups
        try JSONSerialization.data(withJSONObject: oldArchive).write(to: file, options: .atomic)

        let restored = CapturePinManager(directory: folder, displaysWindows: false)
        #expect(restored.records.map(\.id) == [newest, older, open])
        #expect(restored.record(open)?.isOpen == true)
        #expect(restored.record(newest)?.locked == true && restored.record(newest)?.clickThrough == true)
        #expect(restored.record(newest)?.text == "legacy")
        let oldClosedAt = restored.record(older)?.closedAt
        restored.close(older)
        #expect(restored.record(older)?.closedAt == oldClosedAt)
        restored.restoreLastClosed()
        #expect(restored.record(newest)?.isOpen == true && restored.record(older)?.isOpen == false)
        restored.restoreLastClosed()
        #expect(restored.record(older)?.isOpen == true)
        restored.restoreLastClosed()
        restored.deactivate()

        let reopened = CapturePinManager(directory: folder, displaysWindows: false)
        #expect(reopened.records.count == 3 && reopened.records.allSatisfy { $0.isOpen })
        let png = try CaptureImage.png(image)
        for pin in reopened.records { #expect(try Data(contentsOf: reopened.url(pin)) == png) }
    }
    @Test @MainActor func markMovementClearAndSpotlightAreUndoableAndExported() throws {
        let context = try CaptureImage.context(width: 200, height: 120)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let document = CaptureDocument(image: try #require(context.makeImage()))
        document.add(CaptureMark(tool: .cover, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: .black, width: 2))
        document.moveMark(at: 0, by: CGSize(width: 50, height: 0))
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 20, y: 20)!.brightnessComponent > 0.95)
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 70, y: 20)!.brightnessComponent < 0.05)
        document.clearMarks(); #expect(document.marks.isEmpty)
        document.undo(); #expect(document.marks.count == 1)
        document.removeMark(at: 0); document.undo(); #expect(document.marks.count == 1)
        document.clearMarks()
        document.add(CaptureMark(tool: .spotlight, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)], color: .red, width: 2))
        let pixels = NSBitmapImageRep(cgImage: document.image)
        #expect(pixels.colorAt(x: 20, y: 20)!.brightnessComponent > 0.95)
        #expect(pixels.colorAt(x: 100, y: 90)!.brightnessComponent < 0.6)
    }
    @Test func redactionMapsVisionCoordinatesAndDoesNotMarkOrdinaryText() throws {
        let text = CaptureText(lines: [RecognizedLine(text: "hello@example.com", rect: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1)),
            RecognizedLine(text: "Ordinary text", rect: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.1))], codes: [])
        let regions = CaptureRecognition.sensitiveTextRegions(text, size: CGSize(width: 1000, height: 500))
        #expect(regions.count == 1)
        let rect = try #require(regions.first)
        #expect(rect.minX == 96 && abs(rect.minY - 96) < 0.01)
        #expect(rect.width == 408 && abs(rect.height - 58) < 0.01)
        let memory = CaptureRegionMemory(displayID: 1, rect: CGRect(x: 90, y: 10, width: 40, height: 40))
        #expect(try memory.clamped(to: CGSize(width: 100, height: 100)) == CGRect(x: 90, y: 10, width: 10, height: 40))
        #expect(throws: PluginError.self) { try memory.clamped(to: CGSize(width: 50, height: 50)) }
    }
}
