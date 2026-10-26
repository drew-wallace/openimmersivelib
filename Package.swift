// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenImmersive",
    platforms: [.visionOS(.v26)],
    products: [.library(name: "OpenImmersiveLib", targets: ["OpenImmersive"])],
    targets: [
        .binaryTarget(name: "CMVC", path: "Artifacts/CMVC.xcframework"),
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
