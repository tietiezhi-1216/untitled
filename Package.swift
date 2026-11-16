// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Untitled",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Untitled", targets: ["Untitled"])
    ],
    targets: [
        .executableTarget(name: "Untitled", resources: [.process("Resources")]),
        .testTarget(name: "UntitledTests", dependencies: ["Untitled"])
    ]
)
