// swift-tools-version: 6.0

import PackageDescription

let ime = "Plugins/doubao-speech-input/IME"
let nativeModules: [Target.Dependency] = ["UntitledPluginCapture", "UntitledPluginSharing", "UntitledPluginSpeech"]
let pluginInterface: [Target.Dependency] = ["UntitledPluginSDK", "UntitledHost"]

let package = Package(
    name: "Untitled",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Untitled", targets: ["Untitled"]),
        .library(name: "UntitledComposition", type: .static, targets: ["UntitledComposition"]),
        .executable(name: "UntitledDictationInputMethod", targets: ["UntitledDictationInputMethod"]),
    ],
    targets: [
        .target(name: "UntitledPluginSDK"),
        .target(name: "UntitledHost", dependencies: ["UntitledPluginSDK"], path: "Sources/Untitled",
                exclude: ["App/PluginComposition.swift", "App/UntitledApp.swift"], resources: [.process("Resources")]),
        .target(name: "UntitledPluginCapture", dependencies: pluginInterface, path: "Plugins/screenshot/Sources"),
        .target(name: "UntitledPluginSharing", dependencies: pluginInterface, path: "Plugins",
                exclude: ["README.md", "catalog.json", "manifest-schema.json", "global-shortcuts", "screenshot", "doubao-speech-input",
                          "peripheral-sharing/README.md", "peripheral-sharing/manifest.json", "peripheral-sharing/Tools",
                          "peripheral-sharing/Icon.png", "peripheral-sharing/Preview.jpg",
                          "wireless-microphone/README.md", "wireless-microphone/manifest.json"],
                sources: ["peripheral-sharing/Sources", "wireless-microphone/Sources"]),
        .target(name: "UntitledPluginSpeech", dependencies: pluginInterface, path: "Plugins/doubao-speech-input/Sources"),
        .target(name: "UntitledComposition", dependencies: pluginInterface + nativeModules, path: "Sources/Untitled/App",
                exclude: ["IdentityMigration.swift", "HostSoftwareUpdate.swift"]),
        .executableTarget(name: "Untitled", dependencies: ["UntitledComposition"], path: "Sources/UntitledEntry"),

        // The experimental input method and its regression fixtures are not
        // dependencies of the normal app or the production speech module.
        .target(name: "DictationIMEKit", path: ime + "/DictationIMEKit"),
        .executableTarget(name: "UntitledDictationInputMethod", dependencies: ["DictationIMEKit"], path: ime + "/Application"),
        .testTarget(name: "UntitledTests", dependencies: pluginInterface + nativeModules + ["UntitledComposition", "DictationIMEKit"]),
    ]
)
