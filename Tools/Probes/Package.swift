// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "probe",
            path: "Sources/probe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
