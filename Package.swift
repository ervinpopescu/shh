// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ShhCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ShhCore", targets: ["ShhCore"]),
        .library(name: "ShhSSH", targets: ["ShhSSH"]),
        .library(name: "ShhTerminal", targets: ["ShhTerminal"]),
        .library(name: "ShhVoice", targets: ["ShhVoice"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.18.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "ShhCore"),
        .target(name: "ShhSSH", dependencies: [
            "ShhCore",
            .product(name: "Citadel", package: "Citadel")
        ]),
        .target(name: "ShhTerminal", dependencies: [
            "ShhCore",
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .target(name: "ShhVoice", dependencies: [
            "ShhCore",
            .product(name: "WhisperKit", package: "WhisperKit")
        ]),
        .testTarget(name: "ShhCoreTests", dependencies: ["ShhCore"]),
        .testTarget(name: "ShhSSHTests", dependencies: ["ShhSSH", "ShhCore"]),
        .testTarget(name: "ShhTerminalTests", dependencies: ["ShhTerminal", "ShhCore"]),
        .testTarget(name: "ShhVoiceTests", dependencies: ["ShhVoice", "ShhCore"])
    ]
)


