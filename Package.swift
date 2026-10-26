// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenImmersive",
    platforms: [.visionOS(.v26)],
    products: [.library(name: "OpenImmersiveLib", targets: ["OpenImmersive"])],
    targets: [
        .binaryTarget(name: "CMVC",
            url: "https://github.com/drew-wallace/openimmersivelib/releases/download/mvc-native-2026.10.26.1/CMVC.xcframework.zip",
            checksum: "30fa951eab2cf29e1535b436f2c2b8b15fbe6f1858d87fac66dc0ce89f17ce66"),
        .target(name: "MVCCore", dependencies: ["CMVC"], path: "Sources/MVCCore",
                swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv")]),
        .target(name: "OpenImmersive", dependencies: ["MVCCore"], path: "Sources",
                exclude: ["MVCCore", "CMVC"],
                resources: [.copy("Notices")],
                swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]),
        .testTarget(name: "OpenImmersiveTests", dependencies: ["OpenImmersive", "MVCCore"],
                    resources: [.copy("Fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]),
    ]
)
