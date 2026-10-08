// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KadrPOC",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "POCCore", targets: ["POCCore"]),
        .executable(name: "kadrpoc-cli", targets: ["kadrpoc-cli"]),
    ],
    dependencies: [
        // Kadr 依赖走内部镜像（fork 自 SteliyanH/*），防上游单作者仓库变动；版本约束保持不变
        .package(url: "https://github.com/timehzy/kadr.git", from: "1.0.0"),
        .package(url: "https://github.com/timehzy/kadr-captions.git", .upToNextMinor(from: "0.12.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "POCCore",
            dependencies: [
                .product(name: "Kadr", package: "kadr"),
                .product(name: "KadrCaptions", package: "kadr-captions"),
            ]
        ),
        .executableTarget(
            name: "kadrpoc-cli",
            dependencies: [
                "POCCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "POCCoreTests",
            dependencies: ["POCCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
