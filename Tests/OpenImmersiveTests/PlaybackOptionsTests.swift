import Testing
import AVFoundation
@testable import OpenImmersive

@Suite @MainActor
struct PlaybackOptionsTests {
    private func item() -> VideoItem {
        VideoItem(metadata: [:], url: URL(fileURLWithPath: "/movie.mkv"))
    }
    @Test func controlsUseMVCClockAndTrackIDs() throws {
        let backend = FakeMVC()
        let player = VideoPlayer(makeMVC: { backend })
        defer { player.stop() }
        player.openItem(item())
        try backend.ready()
        player.seek(to: 40)
        player.plus15()
        player.minus15()
        #expect(backend.seeks == [40, 55, 40])
        player.scrubState = .scrubStarted
        player.currentTime = 80
        backend.position = 45; backend.onUpdate?()
        #expect(player.currentTime == 80)
        player.scrubState = .scrubEnded
        #expect(backend.seeks.last == 80)
        #expect(player.canChooseAudio)
        player.selectEmbeddedAudioTrack(id: 3)
        #expect(player.selectedEmbeddedAudioTrackID == 3)
        player.selectEmbeddedAudioTrack(id: 99)
        #expect(backend.selectedAudio == 3)
        player.swapEyes()
        #expect(player.eyesSwapped)
        #expect(player.currentTime == 80)
        #expect(player.paused)
        player.volume = 0.25
        #expect(backend.volume == 0.25)
        #expect(player.volume == 0.25)
    }


    @Test func stopClearsTrackAndEyeSelections() throws {
        let backend = FakeMVC()
        let player = VideoPlayer(makeMVC: { backend })
        player.openItem(item())
        try backend.ready()
        player.selectEmbeddedAudioTrack(id: 3)
        player.swapEyes()
        player.stop()
        #expect(player.embeddedAudioTracks.isEmpty)
        #expect(player.selectedEmbeddedAudioTrackID == -1)
        #expect(!player.eyesSwapped)
    }
}
