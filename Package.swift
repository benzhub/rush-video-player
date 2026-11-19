// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VideoPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        // 純邏輯：字幕比對、播放清單、持久化、AI / Notion 客戶端（可單元測試）
        .target(name: "VideoPlayerCore"),
        // App：SwiftUI 介面 + libmpv 播放
        .executableTarget(
            name: "VideoPlayer",
            dependencies: [
                "VideoPlayerCore",
                .product(name: "MPVKit", package: "MPVKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "VideoPlayerCoreTests", dependencies: ["VideoPlayerCore"]),
    ]
)
