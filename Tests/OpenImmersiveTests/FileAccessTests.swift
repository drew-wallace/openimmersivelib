import Testing
import Foundation
@testable import OpenImmersive

@Suite @MainActor
struct FileAccessTests {
    @Test func replacementAndStopBalanceEverySuccessfulAcquisition() {
        var acquired: [URL] = [], released: [URL] = []
        let player = VideoPlayer(acquireFileAccess: { url in
            SecurityScopedResource(url, acquire: { acquired.append($0); return true }, release: { released.append($0) })
        })
        let first = URL(fileURLWithPath: "/first.mov"), second = URL(fileURLWithPath: "/second.mov")
        player.openItem(VideoItem(metadata: [:], url: first))
        #expect(acquired == [first] && released.isEmpty)
        player.openItem(VideoItem(metadata: [:], url: second))
        #expect(acquired == [first, second] && released == [first])
        player.stop()
        player.stop()
        #expect(released == [first, second])
    }

    @Test func destructionReleasesAccessAndFailureDoesNotRelease() {
        var releases = 0
        var player: VideoPlayer? = VideoPlayer(acquireFileAccess: { url in
            SecurityScopedResource(url, acquire: { _ in true }, release: { _ in releases += 1 })
        })
        player?.openItem(VideoItem(metadata: [:], url: URL(fileURLWithPath: "/movie.mov")))
        player = nil
        #expect(releases == 1)
        var denied: SecurityScopedResource? = SecurityScopedResource(URL(fileURLWithPath: "/denied.mov"),
            acquire: { _ in false }, release: { _ in releases += 1 })
        #expect(denied == nil)
        denied = nil
        #expect(releases == 1)
    }
}
