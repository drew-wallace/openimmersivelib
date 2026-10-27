import Testing
import AVFoundation
@testable import OpenImmersive

@Suite(.serialized) @MainActor
struct PlayerLifecycleTests {
    @Test func stopRejectsPendingAssetCallbacksAndClearsState() async throws {
        let player = VideoPlayer()
        player.openItem(VideoItem(metadata: [.commonIdentifierTitle: "First"],
                                  url: URL(fileURLWithPath: "/missing-first.mov")))
        player.stop()
        try await Task.sleep(for: .milliseconds(150))
        #expect(player.url == nil)
        #expect(player.player.currentItem == nil)
        #expect(player.metadata.isEmpty)
        #expect(player.title.isEmpty)
        #expect(player.error == nil)
        #expect(!player.loading && !player.buffering)
        #expect(player.paused)
        #expect(player.duration == 0 && player.currentTime == 0)
    }

    @Test func replacingItemPreservesNewestIdentity() async throws {
        let player = VideoPlayer()
        defer { player.stop() }
        let first = VideoItem(metadata: [.commonIdentifierTitle: "First"], url: URL(fileURLWithPath: "/missing-first.mov"))
        let second = VideoItem(metadata: [.commonIdentifierTitle: "Second"], url: URL(fileURLWithPath: "/missing-second.mov"))
        player.openItem(first)
        player.openItem(second)
        try await Task.sleep(for: .milliseconds(150))
        #expect(player.url == second.url)
        #expect(player.title == "Second")
        #expect(player.metadata == second.metadata)
    }

    @Test func invalidSelectionsAndSeekCannotCorruptState() {
        let player = VideoPlayer()
        defer { player.stop() }
        player.openAudioOption(index: -2)
        player.selectBitrateRung(index: -2)
        player.seek(to: Double.nan)
        player.seek(to: Double.infinity)
        #expect(player.selectedAudioIndex == -1)
        #expect(player.selectedBitrateRungIndex == -1)
        #expect(player.currentTime.isFinite)
        player.volume = -1
        #expect(player.volume == 0)
        player.volume = 2
        #expect(player.volume == 1)
    }
}
