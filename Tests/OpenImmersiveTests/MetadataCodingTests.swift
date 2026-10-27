import Testing
import AVFoundation
@testable import OpenImmersive

@Suite @MainActor
struct MetadataCodingTests {
    @Test func identifiersUseTheirExistingStringRepresentation() throws {
        let identifier = AVMetadataIdentifier.commonIdentifierTitle
        let encoded = try JSONEncoder().encode(identifier)
        #expect(try JSONDecoder().decode(String.self, from: encoded) == identifier.rawValue)
        #expect(try JSONDecoder().decode(AVMetadataIdentifier.self, from: encoded) == identifier)
    }

    @Test func itemMetadataRoundTrips() throws {
        let item = VideoItem(metadata: [.commonIdentifierTitle: "Example", .commonIdentifierDescription: "Description"],
                             url: URL(fileURLWithPath: "/tmp/example.mov"), projection: .rectangular)
        let decoded = try JSONDecoder().decode(VideoItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.metadata == item.metadata)
        #expect(decoded.url == item.url)
        #expect(decoded.projection == item.projection)
    }
}
