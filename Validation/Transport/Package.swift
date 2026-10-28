// swift-tools-version: 6.2
import PackageDescription
// Staged by Scripts/test_transport.py with the production transport sources.
let package = Package(name: "TransportValidation", platforms: [.macOS(.v14)], targets: [
    .target(name: "MediaTransport", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "MediaTransportTests", dependencies: ["MediaTransport"], swiftSettings: [.swiftLanguageMode(.v5)])
])
