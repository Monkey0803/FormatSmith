// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FormatSmith",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // 引擎与模型：不依赖 SwiftUI，可以单独被别的工具复用，也能无窗口单测。
        .library(name: "FormatSmithCore", targets: ["FormatSmithCore"]),
        // 应用：SwiftUI 界面 + 命令行入口。
        .executable(name: "FormatSmith", targets: ["FormatSmith"]),
    ],
    targets: [
        .target(
            name: "FormatSmithCore",
            path: "Sources/FormatSmithCore"
        ),
        .executableTarget(
            name: "FormatSmith",
            dependencies: ["FormatSmithCore"],
            path: "Sources/FormatSmithApp"
        ),
        .testTarget(
            name: "FormatSmithCoreTests",
            dependencies: ["FormatSmithCore"],
            path: "Tests/FormatSmithCoreTests"
        ),
    ]
)
