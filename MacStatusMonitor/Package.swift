// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacStatusMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacStatusMonitor", targets: ["MacStatusMonitor"]),
    ],
    targets: [
        // 纯采集层：不 import SwiftUI / AppKit，可单测
        .target(
            name: "MonitorKit",
            path: "Sources/MonitorKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 菜单栏应用层：AppKit + SwiftUI
        .executableTarget(
            name: "MacStatusMonitor",
            dependencies: ["MonitorKit"],
            path: "Sources/MacStatusMonitor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
