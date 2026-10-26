import Testing
import AVFoundation
import MVCCore
@testable import OpenImmersive

@MainActor
private final class FakeMVC: MVCPlaybackControlling {
    let videoRenderer = AVSampleBufferVideoRenderer()
    var onUpdate: (() -> Void)?
    var state: PlaybackState = .idle
    var media: MVCCore.MediaInfo?
    var position = 0.0
    var error: String?
    var diagnostics = PlaybackDiagnostics()
    var selectedAudio = -1
    var eyesSwapped = false
    var playbackRequested = false
    var volume: Float = 1
    var seeks: [Double] = []
    var stopped = false
    func open(_ source: MediaSource) { state = .opening; onUpdate?() }
    func play() { playbackRequested = true; if media != nil { state = .playing }; onUpdate?() }
    func pause() { playbackRequested = false; if media != nil { state = .paused }; onUpdate?() }
    func stop() { stopped = true; state = .idle }
    func seek(to time: Double) { position = max(0, time); seeks.append(time); onUpdate?() }
    func selectAudio(_ id: Int) { selectedAudio = id; onUpdate?() }
    func swapEyes() { eyesSwapped.toggle(); onUpdate?() }
    func reportData() throws -> Data { try diagnostics.json() }
    func ready() throws {
        media = try JSONDecoder().decode(MVCCore.MediaInfo.self, from: Data("""
        {"width":1920,"height":1080,"fps":23.976,"duration":120,
        "fullRange":false,"colorPrimaries":1,"colorTransfer":1,"colorMatrix":1,
        "sampleAspectRatio":1,"baseIsRight":false,
        "audioTracks":[{"id":1,"codec":"DTS","language":"eng","title":"7.1","channels":8,"sampleRate":48000},
        {"id":3,"codec":"AC3","language":"fra","title":"Stereo","channels":2,"sampleRate":48000}]}
        """.utf8))
        selectedAudio = 1
        state = playbackRequested ? .playing : .paused
        onUpdate?()
    }
}

@Suite @MainActor
struct MVCControllerTests {
    private func item(_ path: String = "movie.mkv", engine: VideoItem.PlaybackEngine = .automatic,
                      projection: VideoItem.Projection? = nil,
                      packing: VideoItem.FramePacking = .none) -> VideoItem {
        VideoItem(metadata: [.commonIdentifierTitle: "MVC fixture"], url: URL(string: "https://example.test/\(path)")!,
                  projection: projection, framePacking: packing, playbackEngine: engine)
    }

    @Test func engineSelectionAndLegacyCoding() throws {
        #expect(item("MOVIE.MK3D?token=1").usesMVC)
        #expect(item("resource", engine: .mvc).usesMVC)
        #expect(!item("movie.mkv", engine: .avFoundation).usesMVC)
        #expect(!item("index.m3u8").usesMVC)
        #expect(!item("spatial.mov").usesMVC)
        let original = item()
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "playbackEngine")
        let decoded = try JSONDecoder().decode(VideoItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.metadata[.commonIdentifierTitle] == "MVC fixture")
        #expect(decoded.playbackEngine == .automatic)
        #expect(decoded.usesMVC)
        for engine: VideoItem.PlaybackEngine in [.automatic, .avFoundation, .mvc] {
            let roundtrip = try JSONDecoder().decode(VideoItem.self, from: JSONEncoder().encode(item(engine: engine)))
            #expect(roundtrip.playbackEngine == engine)
        }
    }

    @Test func opensWithRendererAndHonorsEarlyPause() throws {
        let backend = FakeMVC()
        let player = VideoPlayer(makeMVC: { backend })
        defer { player.stop() }
        player.openItem(item())
        #expect(player.renderer === backend.videoRenderer)
        #expect(player.projection == .rectangular)
        #expect(player.player.currentItem == nil)
        #expect(player.loading)
        player.play()
        player.pause()
        try backend.ready()
        #expect(player.paused)
        #expect(!backend.playbackRequested)
        #expect(player.duration == 120)
        player.play()
        #expect(!player.paused)
        #expect(player.mvcDiagnostics != nil)
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
        #expect(try player.mvcDiagnosticReport() != nil)
    }

    @Test func stopAndReopenRejectStaleUpdates() throws {
        let first = FakeMVC(), second = FakeMVC()
        var opening = 0
        let player = VideoPlayer(makeMVC: { opening += 1; return opening == 1 ? first : second })
        defer { player.stop() }
        player.openItem(item())
        let lateUpdate = first.onUpdate
        player.openItem(item("second.mkv"))
        #expect(first.stopped)
        try second.ready()
        first.error = "stale failure"; first.position = 100
        lateUpdate?()
        #expect(player.error == nil)
        #expect(player.currentTime == 0)
        #expect(player.renderer === second.videoRenderer)
        player.stop()
        #expect(second.stopped)
        #expect(player.renderer == nil)
        #expect(player.embeddedAudioTracks.isEmpty)
        #expect(player.mvcDiagnostics == nil)
        #expect(player.url == nil)
        #expect(!player.loading)
    }

    @Test func endCallbackFiresOnceAndReplayRoutesToMVC() throws {
        let backend = FakeMVC()
        let player = VideoPlayer(makeMVC: { backend })
        defer { player.stop() }
        var ends = 0
        player.playbackEndedAction = { ends += 1 }
        player.openItem(item())
        try backend.ready()
        backend.state = .ended; backend.playbackRequested = false
        backend.onUpdate?(); backend.onUpdate?()
        #expect(ends == 1)
        #expect(player.hasReachedEnd)
        player.play()
        #expect(backend.playbackRequested)
        #expect(!player.hasReachedEnd)
    }

    @Test func rejectsIncompatibleMVCFormatsAndDoesNotInvokeHLSControls() {
        var creations = 0
        let backend = FakeMVC()
        let player = VideoPlayer(makeMVC: { creations += 1; return backend })
        defer { player.stop() }
        player.openItem(item(projection: .equirectangular(fieldOfView: 180)))
        #expect(player.error != nil)
        player.openItem(item(packing: .sideBySide))
        #expect(player.error != nil)
        #expect(creations == 0)
        player.openItem(item("resource", engine: .mvc))
        #expect(creations == 1)
        player.openAudioOption(index: -2)
        player.selectBitrateRung(index: -2)
        #expect(player.player.currentItem == nil)
        #expect(player.audioOptions.isEmpty)
    }

    @Test func nonMVCStillUsesAVFoundation() {
        let player = VideoPlayer(makeMVC: { Issue.record("MVC should not open for MOV"); return FakeMVC() })
        defer { player.stop() }
        player.openItem(VideoItem(metadata: [:], url: URL(fileURLWithPath: "/tmp/spatial.mov")))
        #expect(!player.isMVC)
        #expect(player.player.currentItem != nil)
        #expect(player.renderer == nil)
    }
    @Test func framePackedAndAIVItemsKeepTheirExistingRenderingPaths() {
        let player = VideoPlayer(makeMVC: { Issue.record("Existing formats must not open MVC"); return FakeMVC() })
        defer { player.stop() }
        for packing: VideoItem.FramePacking in [.sideBySide, .overUnder] {
            player.openItem(VideoItem(metadata: [:], url: URL(fileURLWithPath: "/tmp/packed.mov"),
                                      projection: .equirectangular(fieldOfView: 180), framePacking: packing))
            #expect(!player.isMVC)
            #expect(player.player.currentItem != nil)
            #expect(player.renderer != nil)
            #expect(player.framePacking == packing)
        }
        player.openItem(VideoItem(metadata: [:], url: URL(fileURLWithPath: "/tmp/immersive.aivu"), projection: .appleImmersive))
        #expect(!player.isMVC)
        #expect(player.renderer == nil)
        #expect(player.projection == .appleImmersive)
    }

}
