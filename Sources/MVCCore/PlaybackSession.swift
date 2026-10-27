import Foundation
import Combine
import AVFoundation
import CoreMedia

@MainActor public final class PlaybackSession: ObservableObject {
    public var onUpdate: (() -> Void)?
    public var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = min(1, max(0, newValue)) }
    }
    public var playbackRequested: Bool { wantsPlayback }
    private var pendingSeek: Double?
    public let videoRenderer = AVSampleBufferVideoRenderer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var media: MediaInfo?
    @Published public private(set) var position: Double = 0
    @Published public private(set) var error: String?
    @Published public private(set) var selectedAudio = -1
    @Published public private(set) var eyesSwapped = false
    private var worker: NativeWorker?
    private var token = UUID()
    private var timer: Timer?
    private var wantsPlayback = false
    private var videoEnd: Double = 0, audioEnd: Double = 0
    private var lastUIUpdate: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var restoreAfterInterruption = false

    public init() {
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        audioRenderer.allowedAudioSpatializationFormats = .multichannel
        #if os(visionOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    let resume = self.wantsPlayback
                    self.pause()
                    self.restoreAfterInterruption = resume
                }
                else if self.restoreAfterInterruption,
                        let flags = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                        AVAudioSession.InterruptionOptions(rawValue: flags).contains(.shouldResume) { self.play() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.media != nil else { return }
                self.seek(to: self.synchronizer.currentTime().seconds)
            }
        })
        #endif
    }
    deinit { timer?.invalidate(); worker?.stop(); for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    public func open(_ source: MediaSource, threads: Int = 4, autoplay: Bool = false) {
        stop()
        let openingToken = UUID(); token = openingToken
        state = .opening; wantsPlayback = autoplay; error = nil; media = nil
        position = 0; eyesSwapped = false
        let native = NativeWorker(source: source, threads: threads, onInfo: { [weak self] info, selected in
            Task { @MainActor in
                guard let self, self.token == openingToken else { return }
                self.media = info; self.selectedAudio = selected
                self.state = self.wantsPlayback ? .buffering : .paused
                if let time = self.pendingSeek { self.pendingSeek = nil; self.seek(to: time) }
                self.onUpdate?()
            }
        }, onFinish: { [weak self] failure in
            Task { @MainActor in
                guard let self, self.token == openingToken else { return }
                if let failure { self.fail(failure) }
                self.onUpdate?()
            }
        })
        worker = native
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        native.start()
        onUpdate?()
    }
    public func play() {
        restoreAfterInterruption = false
        guard state != .idle, state != .failed else { return }
        wantsPlayback = true
        guard media != nil else { onUpdate?(); return }
        if state == .ended {
            seek(to: 0)
        }
        wantsPlayback = true; state = .buffering; onUpdate?()
    }
    public func pause() {
        restoreAfterInterruption = false
        wantsPlayback = false; synchronizer.rate = 0
        if media != nil { position = max(0, synchronizer.currentTime().seconds); state = .paused }
        onUpdate?()
    }
    public func stop() {
        worker?.stop(); worker = nil; token = UUID()
        timer?.invalidate(); timer = nil; wantsPlayback = false
        synchronizer.setRate(0, time: .zero)
        videoRenderer.flush(); audioRenderer.flush()
        videoEnd = 0; audioEnd = 0; state = .idle
        media = nil; error = nil; selectedAudio = -1; position = 0; eyesSwapped = false
        pendingSeek = nil; restoreAfterInterruption = false
        onUpdate?()
    }
    public func seek(to time: Double) {
        guard time.isFinite else { return }
        if state == .opening { pendingSeek = max(0, time); return }
        guard let worker, let media, state != .failed else { return }
        let target = min(max(0, time), media.duration > 0 ? max(0, media.duration - 0.05) : Double.greatestFiniteMagnitude)
        state = .seeking
        synchronizer.rate = 0
        worker.seek(target, audio: selectedAudio, swap: eyesSwapped)
        videoRenderer.flush(); audioRenderer.flush()
        synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 1_000_000))
        position = target; videoEnd = target; audioEnd = target
        state = wantsPlayback ? .buffering : .paused
        onUpdate?()
    }
    public func selectAudio(_ id: Int) {
        guard media?.audioTracks.contains(where: { $0.id == id }) == true else { return }
        selectedAudio = id; seek(to: synchronizer.currentTime().seconds)
    }
    public func swapEyes() { eyesSwapped.toggle(); seek(to: synchronizer.currentTime().seconds) }
    private func fail(_ message: String) {
        error = message; wantsPlayback = false; synchronizer.rate = 0
        state = .failed; worker?.stop(); timer?.invalidate(); timer = nil
        onUpdate?()
    }
    private func tick() {
        let previousState = state
        defer { if state != previousState { onUpdate?() } }
        guard let mailbox = worker?.mailbox, state != .failed else { return }
        let snapshot = mailbox.snapshot()
        if let failure = snapshot.error { fail(failure); return }
        if let failure = videoRenderer.error ?? audioRenderer.error { fail(failure.localizedDescription); return }
        guard media != nil else { return }
        var now = synchronizer.currentTime().seconds
        guard now.isFinite else { return }
        let hasAudio = selectedAudio >= 0
        // Readiness plus a presentation horizon bounds the renderers as well as our queues.
        while videoRenderer.isReadyForMoreMediaData && videoEnd < now + 0.30,
              let item = mailbox.pop(video: true) {
            guard item.generation == snapshot.generation else { continue }
            if synchronizer.rate > 0 && item.end < now - 0.04 { continue }
            videoRenderer.enqueue(item.sample); videoEnd = item.end
        }
        while audioRenderer.isReadyForMoreMediaData && audioEnd < now + 0.75,
              let item = mailbox.pop(video: false) {
            guard item.generation == snapshot.generation else { continue }
            audioRenderer.enqueue(item.sample); audioEnd = item.end
        }
        let after = mailbox.snapshot()
        let videoReserve = max(videoEnd, after.videoEnd) - now
        let enoughVideo = videoReserve >= 0.45 || (after.eof && videoEnd > now)
        let enoughAudio = !hasAudio || max(audioEnd, after.audioEnd) > now + 0.25 || (after.eof && audioEnd > now)
        if wantsPlayback && synchronizer.rate == 0 && enoughVideo && enoughAudio {
            synchronizer.setRate(1, time: CMTime(seconds: now, preferredTimescale: 1_000_000)); state = .playing
        } else if synchronizer.rate > 0 && !after.eof &&
                    ((videoEnd < now + 0.02 && after.video == 0) || (hasAudio && audioEnd < now + 0.02 && after.audio == 0)) {
            synchronizer.rate = 0; state = .buffering
        }
        now = synchronizer.currentTime().seconds
        let hostTime = ProcessInfo.processInfo.systemUptime
        if hostTime - lastUIUpdate >= 0.25 {
            position = max(0, now); lastUIUpdate = hostTime; onUpdate?()
        }
        if after.eof && after.video == 0 && after.audio == 0 && now >= max(videoEnd, hasAudio ? audioEnd : videoEnd) {
            synchronizer.rate = 0; wantsPlayback = false; state = .ended
        }
    }
}
