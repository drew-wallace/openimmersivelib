import Testing
import Foundation
import AVFoundation
@testable import OpenImmersive

@Suite(.serialized) @MainActor
struct MVCPlaybackIntegrationTests {
    private func movie(_ name: String = "mvc-bframes") throws -> VideoItem {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures"))
        return VideoItem(metadata: [:], url: url)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Playback condition timed out")
    }

    @Test func realDecoderProducesStereoSamplesAndEmbeddedTracks() async throws {
        let player = VideoPlayer()
        defer { player.stop() }
        player.openItem(try movie())
        // A test runner has no compositor surface. Check decode/sample output here;
        // paced EOF/replay requires the app's attached RealityView.
        try await waitUntil { (player.mvcDiagnostics?.decodedPairs ?? 0) == 9 || player.error != nil }
        #expect(player.error == nil)
        #expect(player.mvcDiagnostics?.stereoConfirmed == true)
        #expect(player.mvcDiagnostics?.decodedPairs == 9)
        #expect(player.mvcDiagnostics?.renderedAudioChannels == 6)
        #expect(player.renderer != nil)
        #expect(player.embeddedAudioTracks.first?.channels == 6)
    }

    @Test func earlyPauseSeekAndSwapPreserveIntent() async throws {
        let player = VideoPlayer()
        defer { player.stop() }
        player.openItem(try movie())
        player.play()
        player.pause()
        player.seek(to: 0.15)
        try await waitUntil { !player.loading || player.error != nil }
        #expect(player.error == nil)
        #expect(player.paused)
        #expect(abs(player.currentTime - 0.15) < 0.01)
        player.swapEyes()
        player.selectEmbeddedAudioTrack(id: 1)
        #expect(player.eyesSwapped)
        #expect(player.paused)
        #expect(abs(player.currentTime - 0.15) < 0.01)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.error == nil)
        #expect(player.paused)
    }

    @Test func stopDuringOpeningAndReopenDiscardOldFailure() async throws {
        let player = VideoPlayer()
        defer { player.stop() }
        player.openItem(try movie("avc-only"))
        player.stop()
        player.openItem(try movie())
        try await waitUntil { !player.loading || player.error != nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.error == nil)
        #expect(player.duration > 0)
        #expect(player.embeddedAudioTracks.count == 1)
        player.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.url == nil)
        #expect(player.error == nil)
        #expect(player.mvcDiagnostics == nil)
    }

    @Test func ordinaryMKVReportsStereoUnavailable() async throws {
        let player = VideoPlayer()
        defer { player.stop() }
        player.openItem(try movie("avc-only"))
        try await waitUntil { player.error != nil }
        #expect(player.error?.localizedDescription.contains("MVC stereo is unavailable") == true)
        #expect(player.mvcDiagnostics?.stereoConfirmed == false)
    }
}
