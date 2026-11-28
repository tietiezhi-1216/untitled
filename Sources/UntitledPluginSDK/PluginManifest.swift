import Foundation

package enum HostInfo {
    package static let name = "Untitled"
    package static let version = "0.13.57"
    package static let nativeCapabilityVersion = "0.13.53"
    package static let bundleIdentifier = "com.untitled.app"
    package static let repository = URL(string: "https://github.com/tietiezhi-1216/untitled")!
    package static let catalog = URL(string: "https://raw.githubusercontent.com/tietiezhi-1216/untitled/main/Plugins/catalog.json")!
}

/// A plugin may keep its own source repository and release independently of the host.
private enum GitHubPluginSource {
    package static func hasValidOrigin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    package static func isRepository(_ url: URL) -> Bool {
        hasValidOrigin(url) && url.path.range(
            of: #"^/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*/?$"#,
            options: .regularExpression) != nil
    }

    package static func isReleaseArchive(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard hasValidOrigin(url), parts.count == 7,
              parts[3] == "releases", parts[4] == "download",
              !parts.contains("."), !parts.contains(".."), url.pathExtension == "zip"
        else { return false }
        return [parts[1], parts[2]].allSatisfy {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        }
    }
}

package enum PluginError: LocalizedError {
    case invalid(String)

    package var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// A style is a flat, bounded data record, interpreted only by a registered module.
package enum PluginStyleValue: Codable, Equatable, Sendable {
    case number(Double), strings([String])

    package init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .strings(try value.decode([String].self)) }
    }
    package func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .strings(let strings): try value.encode(strings)
        }
    }
    package var isBounded: Bool {
        switch self {
        case .number(let number): number.isFinite
        case .strings(let strings): (1...8).contains(strings.count) && strings.allSatisfy { (1...24).contains($0.utf8.count) }
        }
    }
}

package struct PluginManifest: Codable, Equatable, Sendable, Identifiable {
    package let schemaVersion: Int
    package let id: String
    package let name: String
    package let version: String
    package let summary: String
    package let author: String
    package let repository: URL
    package let minimumHostVersion: String
    package let actions: [ActionKind]
    package let templates: [CommandTemplate]
    package var ui: PluginInterface?
    package var permissions: [PluginPermissionDeclaration]?
    package var icon: PluginIcon? = nil
    package var storefront: PluginStorefront? = nil
    package var shortcutInputs: [ShortcutInputKind]? = nil
    package var styles: [String: [String: PluginStyleValue]]? = nil
    package var allowedShortcutInputs: Set<ShortcutInputKind> { shortcutInputs.map { Set($0) } ?? ShortcutInputKind.all }

    package func validate() throws {
        try icon?.validate()
        try storefront?.validate()
        guard schemaVersion == 1 || schemaVersion == 2 else { throw PluginError.invalid("不支持这个插件格式，请更新主程序。") }
        if schemaVersion == 2 {
            guard let ui, let minimum = Version(minimumHostVersion), minimum >= Version("0.4.0")! else {
                throw PluginError.invalid("v2 插件需要界面声明与 0.4.0 或更高版本的宿主。")
            }
            try ui.validate()
        } else if ui != nil { throw PluginError.invalid("声明界面槽位时需要使用插件协议 v2。") }
        if schemaVersion == 2, let minimum = Version(minimumHostVersion), minimum >= Version("0.5.0")!, permissions == nil {
            throw PluginError.invalid("此版本的插件必须声明 permissions；无需系统权限时使用空数组。")
        }
        if let permissions {
            guard schemaVersion == 2, let minimum = Version(minimumHostVersion), minimum >= Version("0.5.0")!,
                  permissions.count <= 32, Set(permissions.map(\.id)).count == permissions.count,
                  permissions.allSatisfy({
                      $0.id.rawValue.count <= 100 &&
                      $0.id.rawValue.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil &&
                      !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.reason.count <= 240
                  }) else { throw PluginError.invalid("插件权限声明无效，或未指定 0.5.0 及以上宿主。") }
        }
        guard id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)+$"#, options: .regularExpression) != nil,
              id.utf8.count <= 100 else { throw PluginError.invalid("插件标识不合法。") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              summary.count <= 1000, !author.isEmpty,
              Version(version) != nil, let minimum = Version(minimumHostVersion),
              minimum <= Version(HostInfo.version)! else { throw PluginError.invalid("插件信息无效，或需要更高版本的主程序。") }
        guard GitHubPluginSource.isRepository(repository) else {
            throw PluginError.invalid("插件源码地址必须是 HTTPS GitHub 仓库地址。")
        }
        if storefront != nil, minimum < Version("0.12.0")! {
            throw PluginError.invalid("商店宣传图需要 0.12.0 或更高版本宿主。")
        }
        guard (1...100).contains(actions.count), Set(actions).count == actions.count,
              actions.allSatisfy(\.isValid), templates.count <= 100, Set(templates.map(\.id)).count == templates.count,
              templates.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && $0.title.count <= 100 && actions.contains($0.action) && $0.action.canBindCommand }) else {
            throw PluginError.invalid("插件的操作声明无效。")
        }
        let notificationDeclared = permissions?.contains { $0.id == .notifications } == true
        if actions.contains(where: \.isNativeUtility) || notificationDeclared {
            guard schemaVersion == 2, minimum >= Version(HostInfo.nativeCapabilityVersion)! else {
                throw PluginError.invalid("文件、剪贴板和通知能力需要 0.13.53 或更高版本宿主。")
            }
        }
        if actions.contains(.sendNotification), !notificationDeclared {
            throw PluginError.invalid("发送通知需要声明 system.notifications 权限。")
        }
        if templates.contains(where: { $0.defaultHotKey != nil || $0.installByDefault != nil }) {
            guard minimum >= Version("0.6.0")! else { throw PluginError.invalid("默认动作声明需要 0.6.0 或更高版本宿主。") }
        }
        if let shortcutInputs {
            guard schemaVersion == 2, minimum >= Version("0.13.29")!, Set(shortcutInputs).count == shortcutInputs.count else {
                throw PluginError.invalid("快捷键类型声明需要 0.13.29 或更高版本宿主，且类型不能重复。")
            }
        }
        if let styles {
            guard schemaVersion == 2, minimum >= Version("0.13.51")!, (1...8).contains(styles.count),
                  styles.allSatisfy({ name, values in
                      name.utf8.count <= 100 && name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*\.[a-zA-Z0-9._-]+$"#,
                                                           options: .regularExpression) != nil &&
                      (1...24).contains(values.count) && values.allSatisfy { key, value in
                          key.utf8.count <= 36 && key.range(of: #"^[a-zA-Z][a-zA-Z0-9]*$"#, options: .regularExpression) != nil
                              && value.isBounded
                      }
                  }) else { throw PluginError.invalid("插件样式声明无效，或未指定 0.13.51 及以上宿主。") }
        }
        var defaultKeys = Set<String>()
        for template in templates {
            if let key = template.defaultHotKey {
                try key.validate(allowedInputs: allowedShortcutInputs)
                if key.isRightCommand, minimum < Version("0.13.31")! {
                    throw PluginError.invalid("右 ⌘ 默认快捷键需要 0.13.31 或更高版本宿主。")
                }
                if key.isRightControl, minimum < Version("0.13.32")! {
                    throw PluginError.invalid("右 ⌃ 默认快捷键需要 0.13.32 或更高版本宿主。")
                }
                if !key.supportsLegacyHosts, minimum < Version("0.13.29")! {
                    throw PluginError.invalid("此默认快捷键需要 0.13.29 或更高版本宿主。")
                }
                guard template.installByDefault == true, defaultKeys.insert(key.identity).inserted else {
                    throw PluginError.invalid("默认快捷键必须属于默认动作，且不能重复。")
                }
            }
            if template.installByDefault == true { try template.action.validateTarget("") }
        }
    }

    package init(schemaVersion: Int, id: String, name: String, version: String, summary: String, author: String, repository: URL,
                 minimumHostVersion: String, actions: [ActionKind], templates: [CommandTemplate], ui: PluginInterface? = nil,
                 permissions: [PluginPermissionDeclaration]? = nil, icon: PluginIcon? = nil, storefront: PluginStorefront? = nil,
                 shortcutInputs: [ShortcutInputKind]? = nil, styles: [String: [String: PluginStyleValue]]? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.author = author
        self.repository = repository
        self.minimumHostVersion = minimumHostVersion
        self.actions = actions
        self.templates = templates
        self.ui = ui
        self.permissions = permissions
        self.icon = icon
        self.storefront = storefront
        self.shortcutInputs = shortcutInputs
        self.styles = styles
    }
}

package struct Version: Comparable, Equatable, Sendable {
    package let components: [Int]

    package init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }

    package static func < (lhs: Version, rhs: Version) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

package struct PluginActionPresentation: Sendable {
    package let title: String
    package let symbol: String
    package var detail: String? = nil
    package var bindingHelp: String? = nil
    package var minimumHostVersion: String? = nil

    package init(title: String, symbol: String, detail: String? = nil, bindingHelp: String? = nil,
                 minimumHostVersion: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.bindingHelp = bindingHelp
        self.minimumHostVersion = minimumHostVersion
    }
}

/// Stable wire ID; native modules declare their own constants. Decoding
/// a name never enables execution: the host validates the active catalog.
package struct ActionKind: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String

    package init(rawValue: String) { self.rawValue = rawValue }
    package init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    package var isValid: Bool {
        rawValue.utf8.count <= 100 && rawValue.range(of: #"^[A-Za-z][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    package static let openApplication = Self(rawValue: "openApplication")
    package static let openURL = Self(rawValue: "openURL")
    package static let runShortcut = Self(rawValue: "runShortcut")
    package static let showMainWindow = Self(rawValue: "showMainWindow")
    package static let revealFile = Self(rawValue: "revealFile")
    package static let shareFile = Self(rawValue: "shareFile")
    package static let readClipboardText = Self(rawValue: "readClipboardText")
    package static let copyText = Self(rawValue: "copyText")
    package static let sendNotification = Self(rawValue: "sendNotification")

    package var isNativeUtility: Bool {
        switch self {
        case .revealFile, .shareFile, .readClipboardText, .copyText, .sendNotification: true
        default: false
        }
    }

    package var canBindCommand: Bool { self != .readClipboardText }
    package var title: String { Self.hostPresentation[self]?.title ?? rawValue }
    package var symbol: String { Self.hostPresentation[self]?.symbol ?? "puzzlepiece.extension" }

    package static let hostPresentation: [ActionKind: PluginActionPresentation] = [
        .openApplication: .init(title: "打开应用", symbol: "app"),
        .openURL: .init(title: "打开网址", symbol: "link"),
        .runShortcut: .init(title: "运行快捷指令", symbol: "command.square"),
        .showMainWindow: .init(title: "显示主面板", symbol: "macwindow"),
        .revealFile: .init(title: "在 Finder 中定位文件", symbol: "folder"),
        .shareFile: .init(title: "系统分享文件", symbol: "square.and.arrow.up"),
        .readClipboardText: .init(title: "读取剪贴板文本", symbol: "doc.on.clipboard"),
        .copyText: .init(title: "复制文本到剪贴板", symbol: "doc.on.clipboard"),
        .sendNotification: .init(title: "发送本地通知", symbol: "bell")
    ]
    package func validateTarget(_ target: String) throws {
        switch self {
        case .openApplication:
            guard target.hasPrefix("/"), URL(fileURLWithPath: target).pathExtension.lowercased() == "app" else {
                throw PluginError.invalid("请先选择一个应用。")
            }
        case .openURL:
            guard let url = URL(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw PluginError.invalid("请输入有效的 http 或 https 网址。")
            }
        case .runShortcut:
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.count <= 500 else {
                throw PluginError.invalid("请输入 macOS「快捷指令」中的名称。")
            }
        case .revealFile, .shareFile:
            guard target.isEmpty else { throw PluginError.invalid("运行时请选择要使用的文件。") }
        case .readClipboardText:
            throw PluginError.invalid("读取剪贴板由插件面板或原生 provider 调用。")
        case .copyText:
            try NativeCapabilityInput.validateClipboardText(target)
        case .sendNotification:
            _ = try NativeCapabilityInput.notificationTitle(target, body: "")
        default: break
        }
    }
}

package enum NativeCapabilityInput {
    package static let clipboardByteLimit = 16 * 1024
    package static let notificationTitleByteLimit = 240
    package static let notificationBodyByteLimit = 1024

    package static func validateClipboardText(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= clipboardByteLimit else {
            throw PluginError.invalid("剪贴板文本须为 1 字节至 16 KiB。")
        }
    }

    package static func notificationTitle(_ title: String, body: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= notificationTitleByteLimit,
              body.utf8.count <= notificationBodyByteLimit else {
            throw PluginError.invalid("请输入标题，标题最多 240 字节，正文最多 1 KiB。")
        }
        return title
    }
}

package struct CommandTemplate: Codable, Equatable, Sendable, Identifiable {
    package let id: String
    package let title: String
    package let action: ActionKind
    package var defaultHotKey: HotKey? = nil
    package var installByDefault: Bool? = nil

    package init(id: String, title: String, action: ActionKind, defaultHotKey: HotKey? = nil, installByDefault: Bool? = nil) {
        self.id = id
        self.title = title
        self.action = action
        self.defaultHotKey = defaultHotKey
        self.installByDefault = installByDefault
    }
}

package struct PluginCommand: Codable, Equatable, Sendable, Identifiable {
    package var id = UUID()
    package var action: ActionKind
    package var target = ""
    package var applicationBookmark: Data?
    package var hotKey: HotKey?
    package var isEnabled = true
    package var templateID: String? = nil

    // 名称由动作和目标派生；旧配置中的 title 字段由 Codable 自动忽略。
    package var title: String { title(actionTitle: ActionKind.hostPresentation[action]?.title ?? action.rawValue) }

    package func title(actionTitle: String) -> String {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return actionTitle }
        switch action {
        case .openApplication:
            let name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
            return "打开 \(name)"
        case .openURL:
            var destination = value
            for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) {
                destination = String(value.dropFirst(prefix.count))
                break
            }
            if let url = URL(string: value), url.path.isEmpty || url.path == "/",
               url.query == nil, url.fragment == nil, destination.hasSuffix("/") {
                destination.removeLast()
            }
            return "打开 \(destination)"
        case .runShortcut:
            return "运行快捷指令：\(value)"
        default:
            return actionTitle
        }
    }

    package var isConfigured: Bool { (try? action.validateTarget(target)) != nil }

    package func validate(allowedActions: [ActionKind]) throws {
        guard allowedActions.contains(action) else { throw PluginError.invalid("请选择插件支持的操作。") }
        try action.validateTarget(target)
        try hotKey?.validate()
    }

    package init(id: UUID = UUID(), action: ActionKind, target: String = "", applicationBookmark: Data? = nil,
                 hotKey: HotKey? = nil, isEnabled: Bool = true, templateID: String? = nil) {
        self.id = id
        self.action = action
        self.target = target
        self.applicationBookmark = applicationBookmark
        self.hotKey = hotKey
        self.isEnabled = isEnabled
        self.templateID = templateID
    }
}

package struct InstalledPlugin: Codable, Equatable, Sendable, Identifiable {
    package var manifest: PluginManifest
    package var isEnabled = true
    package var commands: [PluginCommand]
    package var installedAt = Date()
    package var initializedDefaultTemplateIDs: [String]? = nil
    package var readme: String? = nil
    package var blockedNativeActions: Set<ActionKind>? = nil
    package var id: String { manifest.id }

    package func allowsAction(_ action: ActionKind) -> Bool {
        manifest.actions.contains(action) && (!action.isNativeUtility || blockedNativeActions?.contains(action) != true)
    }

    /// Upgrade defaults once; user edits, cleared bindings and deleted defaults survive later upgrades.
    @discardableResult package mutating func initializeDefaultCommands(
        occupiedHotKeys: Set<String> = [], restoring: Bool = false
    ) -> [String] {
        var initialized = Set(initializedDefaultTemplateIDs ?? [])
        var conflicts: [String] = []
        let restoringIDs = restoring ? Set(manifest.templates.filter { $0.installByDefault == true }.map(\.id)) : []
        for template in manifest.templates where template.installByDefault == true {
            guard restoring || !initialized.contains(template.id) else { continue }
            initialized.insert(template.id)
            var index = commands.firstIndex { $0.templateID == template.id }
            if index == nil, !restoring {
                index = commands.firstIndex { $0.templateID == nil && $0.action == template.action }
            }
            if let index, !restoring {
                commands[index].templateID = template.id
                continue
            }
            var command = index.map { commands[$0] } ?? PluginCommand(action: template.action)
            command.templateID = template.id
            command.action = template.action
            command.target = ""
            command.hotKey = template.defaultHotKey
            command.isEnabled = true
            if let key = command.hotKey,
               occupiedHotKeys.contains(key.identity) || commands.contains(where: {
                   $0.id != command.id && $0.isEnabled && !($0.templateID.map { restoringIDs.contains($0) } ?? false) && $0.hotKey?.identity == key.identity
               }) {
                conflicts.append(template.title)
                command.hotKey = nil
            }
            if let index { commands[index] = command } else { commands.append(command) }
        }
        initializedDefaultTemplateIDs = initialized.sorted()
        return conflicts
    }

    package init(manifest: PluginManifest, isEnabled: Bool = true, commands: [PluginCommand], installedAt: Date = Date(),
                 initializedDefaultTemplateIDs: [String]? = nil, readme: String? = nil) {
        self.manifest = manifest
        self.isEnabled = isEnabled
        self.commands = commands
        self.installedAt = installedAt
        self.initializedDefaultTemplateIDs = initializedDefaultTemplateIDs
        self.readme = readme
    }
}

package struct PluginCatalog: Codable, Sendable {
    package let schemaVersion: Int
    package let plugins: [CatalogEntry]

    package func validate() throws {
        guard schemaVersion == 1, plugins.count <= 500, Set(plugins.map(\.id)).count == plugins.count else {
            throw PluginError.invalid("插件目录格式无效。")
        }
        for entry in plugins { try entry.validate() }
    }

    package init(schemaVersion: Int, plugins: [CatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.plugins = plugins
    }
}

package struct CatalogEntry: Codable, Identifiable, Sendable {
    package let id: String
    package let name: String
    package let version: String
    package let summary: String
    package let author: String
    package let downloadURL: URL
    package let sha256: String
    package var icon: PluginIcon? = nil
    package var storefront: PluginStorefront? = nil

    package func validate() throws {
        try icon?.validate()
        try storefront?.validate()
        guard GitHubPluginSource.isReleaseArchive(downloadURL),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              Version(version) != nil, !id.isEmpty, !name.isEmpty else {
            throw PluginError.invalid("插件下载地址或校验信息无效。")
        }
    }

    package init(id: String, name: String, version: String, summary: String, author: String, downloadURL: URL, sha256: String,
                 icon: PluginIcon? = nil, storefront: PluginStorefront? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.author = author
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.icon = icon
        self.storefront = storefront
    }
}
