import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Untitled

@Suite(.serialized)
struct PluginMarketplaceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNTITLED_PACKAGE_CANDIDATES_DIR"] != nil))
    @MainActor func validatePackagedPluginCatalog() throws {
        let path = try #require(ProcessInfo.processInfo.environment["UNTITLED_PACKAGE_CANDIDATES_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let catalog = try JSONDecoder().decode(PluginCatalog.self, from:
            Data(contentsOf: directory.appendingPathComponent("catalog.json")))
        try catalog.validate()
        let entries = catalog.plugins
        let archiveNames = entries.map { $0.downloadURL.lastPathComponent }
        let packaged = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" }.map(\.lastPathComponent)
        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.id)) == Set(PluginPresentationIndex.bundled.plugins.map(\.id)))
        #expect(Set(archiveNames).count == entries.count)
        #expect(Set(archiveNames) == Set(packaged))
        let registry = PluginComposition.makeUIRegistry()
        let permissions = PluginComposition.makePermissionCenter()
        for entry in entries {
            let manifest = try PluginArchive.read(directory.appendingPathComponent(entry.downloadURL.lastPathComponent),
                                                  expectedSHA256: entry.sha256)
            #expect(manifest.id == entry.id && manifest.version == entry.version && manifest.name == entry.name)
            try registry.validate(manifest)
            try permissions.validate(manifest)
        }
    }

    @Test func storefrontRejectsInvalidAssetsAndRequiresCompatibleHost() throws {
        let source = try #require(PluginPresentationIndex.bundled.plugins.first?.storefront)
        var plugin = manifest(id: "dev.test.storefront", name: "Storefront")
        plugin.storefront = source
        #expect(throws: PluginError.self) { try plugin.validate() }
        var compatible = manifest(id: plugin.id, name: plugin.name, minimumHostVersion: HostInfo.version)
        compatible.storefront = source
        try compatible.validate()
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(compatible))
        #expect(decoded.storefront == source)
        var oversized = source
        oversized.jpeg = Data(repeating: 0, count: 96 * 1024 + 1)
        #expect(throws: PluginError.self) { try oversized.validate() }
        var invalid = source
        invalid.jpeg = Data([255, 216, 255, 0, 0])
        #expect(throws: PluginError.self) { try invalid.validate() }
    }

    @Test @MainActor func artworkCacheRespectsBudgetAndCancellation() async throws {
        let jpeg = try #require(PluginPresentationIndex.bundled.plugins.first?.storefront?.jpeg)
        for index in 0..<24 {
            var variant = jpeg
            variant.append(contentsOf: "cache-variant-\(index)".utf8)
            let image = await PluginArtworkCache.image(variant)
            #expect(image != nil)
            #expect(PluginArtworkCache.cachedByteCount <= 12 * 1024 * 1024)
            #expect(PluginArtworkCache.cachedImageCount <= 16)
        }
        let cancelled = Task { await PluginArtworkCache.image(jpeg) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
    }

    @Test func artworkBoundsAndBundledPresentations() throws {
        let bundled = PluginPresentationIndex.bundled
        #expect(bundled.plugins.count == 4)
        for item in bundled.plugins {
            let icon = try #require(item.icon)
            #expect(icon.png != nil)
            try icon.validate()
            let storefront = try #require(item.storefront)
            #expect(storefront.jpeg != nil)
            try storefront.validate()
            #expect(bundled.appearance(id: item.id, repository: item.repository, version: "0.1.0")?.name == item.name)
            #expect(bundled.appearance(id: item.id, repository: item.repository, version: "99.0.0") == nil)
            #expect(bundled.appearance(id: item.id, repository: URL(string: "https://github.com/alice/fork")!, version: "0.1.0") == nil)
        }
        for icon in [PluginIcon(symbol: "", tint: "#112233"), PluginIcon(symbol: "mic", tint: "red"),
                     PluginIcon(symbol: "mic", tint: "#112233", png: Data("invalid".utf8)),
                     PluginIcon(symbol: "mic", tint: "#112233", png: Data(repeating: 0, count: 65_537))] {
            #expect(throws: PluginError.self) { try icon.validate() }
        }
        try PluginIcon(symbol: "mic", tint: "#112233").validate()
    }

    @Test @MainActor func documentationPersistsWithoutResettingConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginStore(directory: directory)
        let original = manifest(id: "dev.test.documentation", name: "Original")
        try store.installManifest(original, readme: "# Original\n\nOffline documentation.")
        let command = PluginCommand(action: .showMainWindow, isEnabled: false)
        try store.saveCommand(command, pluginID: original.id)
        store.setEnabled(false, pluginID: original.id)
        let upgrade = manifest(id: original.id, name: "Renamed", version: "1.1.0")
        try store.installManifest(upgrade, readme: "# Renamed\n\nNew documentation.")
        #expect(store.installed.first?.commands == [command])
        #expect(store.installed.first?.isEnabled == false)
        let entry = CatalogEntry(id: original.id, name: upgrade.name, version: upgrade.version, summary: "", author: "Tests",
                                 downloadURL: URL(string: "https://github.com/alice/plugin/releases/download/v1.1.0/plugin.zip")!, sha256: String(repeating: "a", count: 64))
        #expect(try await store.documentation(for: entry) == "# Renamed\n\nNew documentation.")
        let reloaded = PluginStore(directory: directory)
        #expect(reloaded.installed.first?.readme == "# Renamed\n\nNew documentation.")
        #expect(reloaded.installed.first?.commands == [command])
        #expect(reloaded.installed.first?.isEnabled == false)
        #expect(throws: PluginError.self) { try store.installManifest(upgrade, readme: String(repeating: "x", count: 131_073)) }
        #expect(reloaded.installed.first?.manifest == upgrade)
        try store.installManifest(manifest(id: original.id, name: "No README", version: "1.2.0"))
        #expect(store.installed.first?.readme == nil)
        store.uninstall(original.id)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(original.id + ".json").path))
    }

    @Test func archivesBoundReadmeAndKeepLegacyPackagesReadable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest(id: "dev.test.archive", name: "Legacy")).write(to: source)
        var archive = try zip(directory, files: ["manifest.json"])
        #expect(try PluginArchive.readContents(archive).readme == nil)
        try FileManager.default.removeItem(at: archive)
        try Data("# README\n\nText".utf8).write(to: directory.appendingPathComponent("README.md"))
        archive = try zip(directory, files: ["manifest.json", "README.md"])
        #expect(try PluginArchive.readContents(archive).readme == "# README\n\nText")
        try FileManager.default.removeItem(at: archive)
        try Data(repeating: 65, count: 131_073).write(to: directory.appendingPathComponent("README.md"))
        archive = try zip(directory, files: ["manifest.json", "README.md"])
        #expect(throws: PluginError.self) { try PluginArchive.readContents(archive) }
        try FileManager.default.removeItem(at: archive)
        try Data([0xff, 0xff]).write(to: directory.appendingPathComponent("README.md"))
        archive = try zip(directory, files: ["manifest.json", "README.md"])
        #expect(throws: PluginError.self) { try PluginArchive.readContents(archive) }
    }

    @Test func nativeMarkdownPreservesSectionsListsAndCode() {
        let blocks = PluginReadmeBlock.parse("# Title\n\nParagraph with **bold**.\n\n- Item\n1. Step\n\n```swift\nlet value = 1\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n> Quote")
        #expect(blocks.map(\.kind) == [.heading(1), .paragraph, .list("•"), .list("1."), .code, .table, .quote])
        #expect(blocks[4].text == "let value = 1")
        let longTable = String(repeating: "| value | value |\n", count: 201)
        #expect(PluginReadmeBlock.parse(longTable).first?.kind == .code)
        #expect(PluginReadmeBlock.parse(longTable).first?.text.contains("value") == true)
    }

    @Test @MainActor func marketplaceGalleryMatchesReferenceAndFiltersLocally() async throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let presentations = PluginPresentationIndex.bundled.plugins
        #expect(presentations.count == 4)
        let catalog = presentations.enumerated().map { index, appearance in
            CatalogEntry(id: "dev.test.card-\(index)", name: appearance.name, version: "1.0.0",
                         summary: "简洁的功能说明。",
                         author: index == 0 ? String(repeating: "Long author ", count: 30) : "tietiezhi-1216",
                         downloadURL: URL(string: "https://github.com/alice/plugin/releases/download/v1.0.0/plugin.zip")!,
                         sha256: String(repeating: "a", count: 64), icon: appearance.icon, storefront: appearance.storefront)
        }
        let store = PluginStore(directory: directory, initialCatalog: catalog)
        for entry in catalog {
            let plugin = manifest(id: entry.id, name: entry.name, author: entry.author)
            try store.installManifest(plugin, readme: "# \(entry.name)\n\n可离线阅读的插件文档。\n\n## 使用\n\n1. 打开插件。\n2. 根据说明使用。\n\n```text\n示例内容\n```")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            application.appearance = NSAppearance(named: appearance)
            for width in [655.0, 815.0, 1055.0] {
                let observation = MarketplaceBounds()
                let navigation = PluginMarketplaceNavigation()
                let root = PluginStoreView(navigation: navigation) { _ in }
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                    .background(PanelPalette.store(appearance == .darkAqua ? .dark : .light))
                    .environmentObject(store).coordinateSpace(name: PanelLayout.coordinateSpace)
                    .onPreferenceChange(PanelLayoutBoundsKey.self) { frames in
                        MainActor.assumeIsolated { observation.frames = frames }
                    }
                let host = NSHostingView(rootView: root)
                let window = makeWindow(host, width: width)
                await settle(host, window: window)
                let controls = try #require(observation.frames["panel.header"])
                let title = try #require(observation.frames["panel.title"])
                let filter = try #require(observation.frames["store.filter"])
                #expect(observation.frames["store.scope"] == nil)
                #expect(filter.maxX <= width - 27)
                #expect(title.maxX < filter.minX)
                #expect(title.minY < filter.maxY && filter.minY < title.maxY)
                let cards = try store.installed.map { plugin in
                    let card = try #require(observation.frames["store.card.\(plugin.id)"])
                    let header = try #require(observation.frames["store.card.\(plugin.id).header"])
                    let identity = try #require(observation.frames["store.card.\(plugin.id).identity"])
                    let action = try #require(observation.frames["store.card.\(plugin.id).action"])
                    let preview = try #require(observation.frames["store.card.\(plugin.id).preview"])
                    #expect(identity.maxX < action.minX)
                    #expect(header.maxY < preview.minY)
                    #expect(abs(preview.width / preview.height - 1.6) < 0.02)
                    #expect(card.insetBy(dx: -1, dy: -1).contains(header))
                    return card
                }.sorted { $0.minY < $1.minY }
                #expect(cards.count == 4)
                #expect(cards.allSatisfy { $0.minY >= controls.maxY && $0.minX >= 27 && $0.maxX <= width - 27 })
                let firstRow = cards.filter { abs($0.minY - (cards.first?.minY ?? 0)) < 1 }
                #expect(firstRow.count == 2)
                try snapshot(host, filename: "store-\(appearance.rawValue)-\(Int(width)).png")
                navigation.search = "语音输入"
                await settle(host, window: window)
                let matches = observation.frames.keys.filter { $0.hasPrefix("store.card.") && !$0.hasSuffix(".header") && !$0.hasSuffix(".identity") && !$0.hasSuffix(".action") && !$0.hasSuffix(".preview") }
                #expect(matches.count == 1)
                if appearance == .darkAqua && width == 815 {
                    navigation.search = "效率工具"
                    await settle(host, window: window)
                    #expect(!observation.frames.keys.contains { $0.hasPrefix("store.card.") })
                    navigation.search = ""
                    navigation.onlyUninstalled = true
                    await settle(host, window: window)
                    #expect(!observation.frames.keys.contains { $0.hasPrefix("store.card.") })
                }
                window.close()
            }
        }
        let entry = try #require(catalog.first)
        let detail = PluginStoreDetailView(
            item: PluginStoreItem(id: entry.id, entry: entry, plugin: store.installed.first { $0.id == entry.id },
                                  presentation: store.presentation(for: entry), author: entry.author),
            goBack: {}, openPlugin: { _ in }
        )
            .environment(\.colorScheme, .dark).background(PanelPalette.content(.dark))
            .environmentObject(store)
        let host = NSHostingView(rootView: detail)
        let window = makeWindow(host, width: 815)
        await settle(host, window: window)
        try snapshot(host, filename: "detail.png")
        window.close()

        let local = manifest(id: "dev.test.local-only", name: "Local Only")
        try store.installManifest(local)
        let sidebarObservation = MarketplaceBounds()
        let fullRoot = ContentView().environmentObject(store)
            .environment(\.colorScheme, .dark)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { frames in
                MainActor.assumeIsolated { sidebarObservation.frames = frames }
            }
        let fullHost = NSHostingView(rootView: fullRoot)
        let fullWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        fullWindow.isReleasedWhenClosed = false
        fullWindow.contentView = fullHost
        await settle(fullHost, window: fullWindow)
        #expect(sidebarObservation.frames["navigation.__store__"] != nil)
        #expect(sidebarObservation.frames["navigation.__installed__"] == nil)
        for plugin in store.installed {
            #expect(sidebarObservation.frames["navigation.\(plugin.id)"] != nil)
        }
        #expect(sidebarObservation.frames["store.card.\(local.id)"] == nil)
        try snapshot(fullHost, filename: "window-dark.png")
        fullWindow.close()
    }

    private func manifest(id: String, name: String, version: String = "1.0.0", author: String = "Tests",
                          minimumHostVersion: String = "0.2.0") -> PluginManifest {
        PluginManifest(schemaVersion: 1, id: id, name: name, version: version, summary: "简洁的功能说明。", author: author,
                       repository: HostInfo.repository, minimumHostVersion: minimumHostVersion, actions: [.showMainWindow], templates: [])
    }

    @MainActor private func makeWindow(_ host: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    @MainActor private func settle(_ host: NSView, window: NSWindow) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor private func snapshot(_ host: NSView, filename: String) throws {
        guard let output = ProcessInfo.processInfo.environment["UNTITLED_STORE_REVIEW_DIRECTORY"],
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(filename))
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UntitledMarketplace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func zip(_ directory: URL, files: [String]) throws -> URL {
        let archive = directory.appendingPathComponent("package.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", archive.path] + files
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return archive
    }
}

@MainActor private final class MarketplaceBounds { var frames: [String: CGRect] = [:] }
