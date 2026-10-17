// swift-tools-version: 5.9
// 上游 CodeEditTextView 0.12.1（MIT，commit d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec）的 vendored 副本。
// 与上游的唯一差异：去掉 SwiftLint 构建插件与测试 target（插件在部分 Xcode 版本上崩溃，且构建时会下载二进制）。
// 源码未做修改；升级时整体替换 Sources/ 并更新本注释中的版本。

import PackageDescription

let package = Package(
    name: "CodeEditTextView",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditTextView",
            targets: ["CodeEditTextView"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/TextStory", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "CodeEditTextView",
            dependencies: [
                "TextStory",
                .product(name: "Collections", package: "swift-collections"),
                "CodeEditTextViewObjC",
            ]
        ),
        .target(
            name: "CodeEditTextViewObjC",
            publicHeadersPath: "include"
        ),
    ]
)
