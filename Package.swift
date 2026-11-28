// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Untitled",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Untitled", targets: ["Untitled"]),
        .executable(name: "UntitledDictationInputMethod", targets: ["UntitledDictationInputMethod"])
    ],
    targets: [
        .target(name: "DictationIMEKit"),
        .executableTarget(name: "UntitledDictationInputMethod", dependencies: ["DictationIMEKit"]),
        .executableTarget(name: "Untitled", dependencies: ["DictationIMEKit"], resources: [.process("Resources")]),
        .testTarget(name: "UntitledTests", dependencies: ["Untitled", "DictationIMEKit"])
    ]
)
