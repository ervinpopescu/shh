// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShhCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "ShhCore", targets: ["ShhCore"])],
    targets: [
        .target(name: "ShhCore"),
        .testTarget(name: "ShhCoreTests", dependencies: ["ShhCore"])
    ]
)
