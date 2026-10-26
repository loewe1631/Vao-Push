// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaoPushCore",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("26.0"), .macOS(.v13)],
    products: [.library(name: "VaoPushCore", targets: ["VaoPushCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "VaoPushCore", dependencies: ["CSQLite"], resources: [.process("Resources")]),
        .testTarget(name: "VaoPushCoreTests", dependencies: ["VaoPushCore"])
    ]
)
