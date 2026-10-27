// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OpenImmersive",
    platforms: [.visionOS(.v26)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "OpenImmersiveLib",
            targets: ["OpenImmersive"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "OpenImmersive",
            path: "Sources", exclude: ["MediaTransport"],
            swiftSettings: [
                .swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)
            ]
        ),
        .target(name: "MediaTransport", path: "Sources/MediaTransport",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MediaTransportTests", dependencies: ["MediaTransport"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OpenImmersiveTests", dependencies: ["OpenImmersive"],
                    swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]),
    ]
)
