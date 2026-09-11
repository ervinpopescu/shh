// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShhCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ShhCore", targets: ["ShhCore"]),
        .library(name: "ShhSSH", targets: ["ShhSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.7.0")
    ],
    targets: [
        .target(name: "ShhCore"),
        .target(name: "ShhSSH", dependencies: [
            "ShhCore",
            .product(name: "Citadel", package: "Citadel")
        ]),
        .testTarget(name: "ShhCoreTests", dependencies: ["ShhCore"]),
        .testTarget(name: "ShhSSHTests", dependencies: ["ShhSSH", "ShhCore"])
    ]
)

