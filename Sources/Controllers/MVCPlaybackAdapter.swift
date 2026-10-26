import AVFoundation
import MVCCore

/// An embedded MKV track. IDs are demux stream IDs, not array indices.
public typealias EmbeddedAudioTrack = MVCCore.AudioTrack
/// Decoder/renderer counters; these do not measure acoustic sync or compositor presentation.
public typealias MVCPlaybackDiagnostics = MVCCore.PlaybackDiagnostics

/// Internal boundary also used by deterministic controller tests.
protocol MVCPlaybackControlling: AnyObject {
    var videoRenderer: AVSampleBufferVideoRenderer { get }
    var onUpdate: (() -> Void)? { get set }
    var state: PlaybackState { get }
    var media: MVCCore.MediaInfo? { get }
    var position: Double { get }
    var error: String? { get }
    var diagnostics: PlaybackDiagnostics { get }
    var selectedAudio: Int { get }
    var eyesSwapped: Bool { get }
    var playbackRequested: Bool { get }
    var volume: Float { get set }
    func open(_ source: MediaSource)
    func play()
    func pause()
    func stop()
    func seek(to time: Double)
    func selectAudio(_ id: Int)
    func swapEyes()
    func reportData() throws -> Data
}

final class MVCPlaybackAdapter: MVCPlaybackControlling {
    private let session = PlaybackSession()
    var videoRenderer: AVSampleBufferVideoRenderer { session.videoRenderer }
    var onUpdate: (() -> Void)? {
        get { session.onUpdate }
        set { session.onUpdate = newValue }
    }
    var state: PlaybackState { session.state }
    var media: MVCCore.MediaInfo? { session.media }
    var position: Double { session.position }
    var error: String? { session.error }
    var diagnostics: PlaybackDiagnostics { session.diagnostics }
    var selectedAudio: Int { session.selectedAudio }
    var eyesSwapped: Bool { session.eyesSwapped }
    var playbackRequested: Bool { session.playbackRequested }
    var volume: Float {
        get { session.volume }
        set { session.volume = newValue }
    }
    func open(_ source: MediaSource) { session.open(source) }
    func play() { session.play() }
    func pause() { session.pause() }
    func stop() { session.stop() }
    func seek(to time: Double) { session.seek(to: time) }
    func selectAudio(_ id: Int) { session.selectAudio(id) }
    func swapEyes() { session.swapEyes() }
    func reportData() throws -> Data { try session.reportData() }
}
