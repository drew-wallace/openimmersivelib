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
    @Published public private(set) var title = "MVC Vision"
    @Published public private(set) var position: Double = 0
    @Published public private(set) var error: String?
    @Published public private(set) var diagnostics = PlaybackDiagnostics()
    @Published public private(set) var selectedAudio = -1
    @Published public private(set) var eyesSwapped = false
    private var worker: NativeWorker?
    private var testSignal: TestSignalProducer?
    @Published public private(set) var testChannels = 0
    public var activeTestChannel: String {
        let names = testChannels == 8 ? ["Left", "Right", "Center", "LFE", "Rear left", "Rear right", "Side left", "Side right"] : ["Left", "Right", "Center", "LFE", "Surround left", "Surround right"]
        return testChannels > 0 ? names[Int(position) % names.count] : ""
    }
    private var token = UUID()
    private var timer: Timer?
    private var wantsPlayback = false
    private var videoEnd: Double = 0, audioEnd: Double = 0
    private var presentCount = 0, droppedCount = 0, bufferCount = 0
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
                if type == .began { self.restoreAfterInterruption = self.wantsPlayback; self.pause() }
                else if self.restoreAfterInterruption,
                        let flags = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                        AVAudioSession.InterruptionOptions(rawValue: flags).contains(.shouldResume) { self.play() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.media != nil else { return }
                self.seek(to: self.position)
            }
        })
        #endif
    }
    deinit { timer?.invalidate(); worker?.stop(); testSignal?.stop(); for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    public func open(_ source: MediaSource, threads: Int = 4, autoplay: Bool = false) {
        stop()
        let openingToken = UUID(); token = openingToken
        title = source.displayName; state = .opening; wantsPlayback = autoplay; error = nil; media = nil
        position = 0; eyesSwapped = false; presentCount = 0; droppedCount = 0; bufferCount = 0
        diagnostics = PlaybackDiagnostics(); diagnostics.transport = source.transport; diagnostics.workerThreads = threads
        let native = NativeWorker(source: source, threads: threads, onInfo: { [weak self] info, selected in
            Task { @MainActor in
                guard let self, self.token == openingToken else { return }
                self.media = info; self.selectedAudio = selected
                self.state = self.wantsPlayback ? .buffering : .paused
                if let time = self.pendingSeek { self.pendingSeek = nil; self.seek(to: time) }
                self.onUpdate?()
            }
        }, onFinish: { [weak self] report in
            Task { @MainActor in
                guard let self, self.token == openingToken else { return }
                self.diagnostics = report
                if let failure = report.rendererErrors.last { self.fail(failure) }
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
        guard state != .idle, state != .failed else { return }
        wantsPlayback = true
        guard media != nil else { onUpdate?(); return }
        if state == .ended {
            if testChannels > 0 { startTestSignal(channels: testChannels); return }
            seek(to: 0)
        }
        wantsPlayback = true; state = .buffering; onUpdate?()
    }
    public func pause() {
        wantsPlayback = false; synchronizer.rate = 0
        if media != nil { position = max(0, synchronizer.currentTime().seconds); state = .paused }
        onUpdate?()
    }
    public func stop() {
        worker?.stop(); worker = nil; testSignal?.stop(); testSignal = nil; testChannels = 0; token = UUID()
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
        selectedAudio = id; seek(to: position)
    }
    public func swapEyes() { eyesSwapped.toggle(); seek(to: position) }
    public func startTestSignal(channels: Int) {
        guard channels == 6 || channels == 8 else { return }
        stop(); error = nil; position = 0; presentCount = 0; droppedCount = 0; bufferCount = 0
        title = "Eye identification + \(channels == 6 ? "5.1" : "7.1") channel test"
        media = TestSignalProducer.info(); selectedAudio = 0; testChannels = channels
        diagnostics = PlaybackDiagnostics(); diagnostics.stereoConfirmed = true; diagnostics.renderedAudioChannels = channels
        wantsPlayback = true; state = .buffering
        let producer = TestSignalProducer(channels: channels); testSignal = producer
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        producer.start()
    }
    public func reportData() throws -> Data {
        updateDiagnostics()
        return try diagnostics.json()
    }
    private func fail(_ message: String) {
        error = message; wantsPlayback = false; synchronizer.rate = 0
        if diagnostics.rendererErrors.last != message { diagnostics.rendererErrors.append(message) }
        state = .failed; worker?.stop(); timer?.invalidate(); timer = nil
        onUpdate?()
    }
    private func tick() {
        let previousState = state
        defer { if state != previousState { onUpdate?() } }
        guard let mailbox = worker?.mailbox ?? testSignal?.mailbox, state != .failed else { return }
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
            if synchronizer.rate > 0 && item.end < now - 0.04 { droppedCount += 1; continue }
            videoRenderer.enqueue(item.sample); videoEnd = item.end; presentCount += 1
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
            synchronizer.rate = 0; state = .buffering; bufferCount += 1
        }
        now = synchronizer.currentTime().seconds
        let hostTime = ProcessInfo.processInfo.systemUptime
        if hostTime - lastUIUpdate >= 0.25 {
            position = max(0, now); updateDiagnostics(); lastUIUpdate = hostTime; onUpdate?()
        }
        if after.eof && after.video == 0 && after.audio == 0 && now >= max(videoEnd, hasAudio ? audioEnd : videoEnd) {
            synchronizer.rate = 0; wantsPlayback = false; state = .ended
        }
    }
    private func updateDiagnostics() {
        let messages = diagnostics.rendererErrors
        if let worker { diagnostics = worker.report() }
        for message in messages where !diagnostics.rendererErrors.contains(message) { diagnostics.rendererErrors.append(message) }
        diagnostics.media = media
        diagnostics.playbackState = state.rawValue; diagnostics.playbackPositionSeconds = position
        diagnostics.presentedPairs = presentCount; diagnostics.droppedPairs = droppedCount; diagnostics.bufferEvents = bufferCount
        diagnostics.thermalState = thermalName()
    }
}
