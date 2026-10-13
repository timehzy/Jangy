// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JangyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JangyCore", targets: ["JangyCore"]),
        .executable(name: "jangy-cli", targets: ["jangy-cli"]),
    ],
    dependencies: [
        // Kadr 依赖走内部镜像（fork 自 SteliyanH/*），防上游单作者仓库变动；版本约束保持不变。
        // v1.2.0 起含 fork 自加的 `Video.renderedFrame(at:)`（导出保真单帧渲染，FrameSnapshotter 依赖）
        .package(url: "https://github.com/timehzy/kadr.git", from: "1.2.0"),
        .package(url: "https://github.com/timehzy/kadr-captions.git", .upToNextMinor(from: "0.12.0")),
        // kadr-photos 0.11 起 kadr 约束放开为整个 1.x；其 Package.swift 仍指向上游 kadr，
        // SwiftPM 按包身份去重，根包声明的 timehzy 镜像 URL 生效（与 kadr-captions 同款处理）
        .package(url: "https://github.com/timehzy/kadr-photos.git", .upToNextMinor(from: "0.11.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // 剪辑 Agent 的 LLM 接入层：FoundationModels 同 API 的 provider 抽象（Anthropic/OpenAI/端侧可换）。
        // 走内部镜像（fork 自 huggingface/AnyLanguageModel，与 kadr 同款依赖风险缓解）；版本约束保持不变。
        .package(url: "https://github.com/timehzy/AnyLanguageModel.git", from: "0.16.0"),
    ],
    targets: [
        .target(
            name: "JangyCore",
            dependencies: [
                .product(name: "Kadr", package: "kadr"),
                .product(name: "KadrCaptions", package: "kadr-captions"),
                .product(name: "KadrPhotos", package: "kadr-photos"),
            ]
        ),
        // POC/测试专属脚手架（样例工程、测试素材合成器）：仅测试与 CLI 依赖，不进 App 产物
        .target(
            name: "JangyTestSupport",
            dependencies: ["JangyCore"]
        ),
        // 剪辑 Agent：L1 意图的 headless 消费方（工具层 + 编排层），App 与 CLI 共用
        .target(
            name: "JangyAgent",
            dependencies: [
                "JangyCore",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
        .executableTarget(
            name: "jangy-cli",
            dependencies: [
                "JangyCore",
                "JangyTestSupport",
                "JangyAgent",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "JangyCoreTests",
            dependencies: ["JangyCore", "JangyTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "JangyAgentTests",
            dependencies: ["JangyAgent", "JangyCore", "JangyTestSupport"]
        ),
    ]
)
