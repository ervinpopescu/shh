// swift-tools-version: 5.10
import PackageDescription

let strictWarningSettings: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"])
]

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
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.7.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.18.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "ShhCore", swiftSettings: strictWarningSettings),
        .target(name: "ShhSSH", dependencies: [
            "ShhCore",
            .product(name: "Citadel", package: "Citadel")
        ], swiftSettings: strictWarningSettings),
        .target(name: "ShhTerminal", dependencies: [
            "ShhCore",
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ], swiftSettings: strictWarningSettings),
        .target(name: "ShhVoice", dependencies: [
            "ShhCore",
            .product(name: "WhisperKit", package: "WhisperKit")
        ], swiftSettings: strictWarningSettings),
        .testTarget(name: "ShhCoreTests", dependencies: ["ShhCore"], swiftSettings: strictWarningSettings),
        .testTarget(name: "ShhSSHTests", dependencies: ["ShhSSH", "ShhCore"], swiftSettings: strictWarningSettings),
        .testTarget(name: "ShhTerminalTests", dependencies: ["ShhTerminal", "ShhCore"], swiftSettings: strictWarningSettings),
        .testTarget(name: "ShhVoiceTests", dependencies: ["ShhVoice", "ShhCore"], swiftSettings: strictWarningSettings)
    ],
    // PackageDescription 5.10 has no target-scoped language-mode setting. Keep the
    // package's Swift 5 compatibility boundary explicit until the manifest can adopt
    // PackageDescription 6's target-scoped .swiftLanguageMode(.v5).
    swiftLanguageVersions: [.v5]
)
