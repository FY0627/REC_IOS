// swift-tools-version: 6.0
// 纯 Swift 的业务核心：不依赖 SwiftUI / UIKit，可以在 macOS、iOS 模拟器和 Linux 上跑测试。
// 依赖方向：App → BKBackend → BKDatabase → BKModel。App 不直接 import BKDatabase。
import PackageDescription

let package = Package(
    name: "BKCore",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "BKModel", targets: ["BKModel"]),
        .library(name: "BKBackend", targets: ["BKBackend"]),
    ],
    targets: [
        // Apple 平台使用 SDK 自带的 SQLite3 模块；Linux 只在本地开发时用系统 libsqlite3。
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(name: "BKModel"),
        .target(
            name: "BKDatabase",
            dependencies: [
                "BKModel",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(name: "BKBackend", dependencies: ["BKModel", "BKDatabase"]),
        .testTarget(name: "BKDatabaseTests", dependencies: ["BKDatabase", "BKModel"]),
        .testTarget(name: "BKBackendTests", dependencies: ["BKBackend", "BKDatabase", "BKModel"]),
    ],
    swiftLanguageModes: [.v6]
)
