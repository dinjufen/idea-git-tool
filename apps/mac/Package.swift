// swift-tools-version: 6.0
import PackageDescription

// 先运行 scripts/build-core-mac.sh 生成 Generated/ 下的 Rust 核心产物。
let package = Package(
    name: "GitDeck",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GitDeck", targets: ["GitDeck"]),
    ],
    targets: [
        .binaryTarget(
            name: "GitDeckCoreFFI",
            path: "Generated/GitDeckCoreFFI.xcframework"
        ),
        // UniFFI 生成的 Swift API，按 Swift 5 模式编译以兼容生成代码。
        .target(
            name: "GitDeckCore",
            dependencies: ["GitDeckCoreFFI"],
            path: "Generated/GitDeckCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GitDeck",
            dependencies: ["GitDeckCore"],
            path: "Sources/GitDeck",
            resources: [.process("Resources")]
        ),
    ]
)
