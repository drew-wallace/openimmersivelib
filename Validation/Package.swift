// swift-tools-version: 6.2
import PackageDescription
// Staged by Scripts/test_core.py using the production sources.
let package = Package(name: "CoreValidation", platforms: [.macOS(.v14)], targets: [
    .binaryTarget(name: "CMVC", path: "Artifacts/CMVC.xcframework"),
    .target(name: "MediaTransport", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "MVCCore", dependencies: ["CMVC", "MediaTransport"], swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv")]),
    .testTarget(name: "MVCCoreTests", dependencies: ["MVCCore", "CMVC"], swiftSettings: [.swiftLanguageMode(.v5)])
])
