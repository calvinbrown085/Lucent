// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "logo-gen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LogoGen",
            path: "Sources/LogoGen"
        )
    ]
)
