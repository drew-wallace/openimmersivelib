// swift-tools-version: 6.2
import PackageDescription
// Scripts/test_core.py stages the production sources beside this manifest.
let package = Package(name: "MVCValidation", platforms: [.macOS(.v14)], targets: [
    .binaryTarget(name: "CMVC", path: "Artifacts/CMVC.xcframework"),
    .target(name: "MVCCore", dependencies: ["CMVC"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv")]),
    .testTarget(name: "MVCCoreTests", dependencies: ["MVCCore", "CMVC"],
                swiftSettings: [.swiftLanguageMode(.v5)])
])
