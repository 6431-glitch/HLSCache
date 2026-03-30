// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HLSCache",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "HLSCache",
            targets: ["HLSCache"]
        ),
        .library(
            name: "CoreCache",
            targets: ["CoreCache"]
        ),
        .executable(
            name: "HLSCacheCLI",
            targets: ["HLSCacheCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "HLSCache",
            dependencies: [
                "CoreCache",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "CoreCache",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "HLSCacheCLI",
            dependencies: ["HLSCache"]
        ),
        .testTarget(
            name: "HLSCacheTests",
            dependencies: [
                "HLSCache",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "CoreCacheTests",
            dependencies: [
                "CoreCache",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "HLSCacheCLITests",
            dependencies: ["HLSCacheCLI"]
        )
    ]
)
