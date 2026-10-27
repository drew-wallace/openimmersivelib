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
            dependencies: ["MVCCore", "MediaTransport"],
            path: "Sources", exclude: ["MediaTransport", "MVCCore", "CMVC"],
            resources: [.copy("Notices")],
            swiftSettings: [
                .swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)
            ]
        ),
        .binaryTarget(name: "CMVC",
            url: "https://github.com/drew-wallace/openimmersivelib/releases/download/mvc-native-2026.10.26.2/CMVC.xcframework.zip",
            checksum: "005cea50dc70507f32842492944f7a9223c6a20e05ca6e2b0ac9958a3db4c36f"),
        .target(name: "MVCCore", dependencies: ["CMVC", "MediaTransport"], path: "Sources/MVCCore",
                swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv")]),
        .testTarget(name: "MVCCoreTests", dependencies: ["MVCCore", "CMVC"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MediaTransport", path: "Sources/MediaTransport",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MediaTransportTests", dependencies: ["MediaTransport"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OpenImmersiveTests", dependencies: ["OpenImmersive", "MVCCore"],
                    resources: [.copy("Fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]),
    ]
)
