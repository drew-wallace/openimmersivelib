import Testing
import AVFoundation
@testable import OpenImmersive

@Suite @MainActor
struct MediaSelectionTests {
    @Test func selectedFilesUseTheirAppropriateDefaultProjection() {
        for ext in ["mkv", "MK3D"] {
            let url = URL(fileURLWithPath: "/tmp/movie.\(ext)")
            let item = VideoItem.selectedFile(url, description: "From Local Files")
            #expect(item.url == url)
            #expect(item.projection == .rectangular)
            #expect(item.usesMVC)
            #expect(item.metadata[.commonIdentifierTitle] == url.lastPathComponent)
        }
        #expect(VideoItem.selectedFile(URL(fileURLWithPath: "/tmp/a.aivu"), description: "").projection == .appleImmersive)
        #expect(VideoItem.selectedFile(URL(fileURLWithPath: "/tmp/a.mov"), description: "").projection == nil)
    }
    @Test func streamInputAcceptsHTTPResourcesWithoutRequiringAnExtension() {
        #expect(VideoItem.streamURL(from: "  https://example.test/resource?id=1  ")?.path == "/resource")
        #expect(VideoItem.streamURL(from: "http://example.test/index.m3u8") != nil)
        for input in ["", "not a url", "ftp://example.test/movie", "file:///movie.mkv"] {
            #expect(VideoItem.streamURL(from: input) == nil)
        }
    }
}
