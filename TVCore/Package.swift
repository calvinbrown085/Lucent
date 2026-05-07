// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVCore",
    platforms: [
        .tvOS("26.0"),
        .iOS("18.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "TVCore", targets: ["TVCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TVCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "TVCoreTests",
            dependencies: ["TVCore"],
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
