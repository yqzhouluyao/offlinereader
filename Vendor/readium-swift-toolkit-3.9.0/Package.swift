// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "Readium",
    defaultLocalization: "en",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "ReadiumShared", targets: ["ReadiumShared"]),
        .library(name: "ReadiumStreamer", targets: ["ReadiumStreamer"]),
        .library(name: "ReadiumNavigator", targets: ["ReadiumNavigator"]),
    ],
    dependencies: [
        .package(name: "CryptoSwift", path: "../CryptoSwift-1.9.0"),
        .package(name: "Zip", path: "../Zip-2.1.2"),
        .package(name: "DifferenceKit", path: "../DifferenceKit-1.3.0"),
        .package(name: "Fuzi", path: "../Fuzi-4.0.0"),
        .package(name: "ZIPFoundation", path: "../ZIPFoundation-3.0.1"),
        .package(name: "SwiftSoup", path: "../SwiftSoup-2.13.5"),
    ],
    targets: [
        .target(
            name: "ReadiumShared",
            dependencies: [
                "ReadiumInternal",
                "SwiftSoup",
                "Zip",
                .product(name: "ReadiumFuzi", package: "Fuzi"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/Shared",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("UIKit"),
            ]
        ),
        .target(
            name: "ReadiumStreamer",
            dependencies: [
                "CryptoSwift",
                "ReadiumShared",
                .product(name: "ReadiumFuzi", package: "Fuzi"),
            ],
            path: "Sources/Streamer",
            resources: [
                .copy("Assets"),
            ]
        ),
        .target(
            name: "ReadiumNavigator",
            dependencies: [
                "ReadiumInternal",
                "ReadiumShared",
                "DifferenceKit",
                "SwiftSoup",
            ],
            path: "Sources/Navigator",
            exclude: [
                "EPUB/Scripts",
            ],
            resources: [
                .copy("EPUB/Assets"),
                .process("Resources"),
            ]
        ),
        .target(
            name: "ReadiumInternal",
            path: "Sources/Internal"
        ),
    ]
)
