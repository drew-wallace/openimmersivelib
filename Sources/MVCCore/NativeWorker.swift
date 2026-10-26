import Foundation
import CoreMedia
import CMVC

struct QueuedSample {
    let sample: CMSampleBuffer
    let generation: Int
    var start: Double { sample.presentationTimeStamp.seconds }
    var end: Double { start + sample.duration.seconds }
}
final class FrameMailbox: @unchecked Sendable {
    let condition = NSCondition()
    private var video: [QueuedSample] = [], audio: [QueuedSample] = []
    private(set) var generation = 0
    private var eof = false
    private var failure: String?
    private var closed = false
    var audioDuration: Double { audio.reduce(0) { $0 + max(0, $1.sample.duration.seconds) } }
    func push(_ sample: CMSampleBuffer, video isVideo: Bool, generation expected: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while expected == generation && !closed && (isVideo ? video.count >= 8 : audioDuration >= 1) { condition.wait() }
        guard expected == generation, !closed else { return false }
        let entry = QueuedSample(sample: sample, generation: expected)
        if isVideo { video.append(entry) } else { audio.append(entry) }
        condition.broadcast()
        return true
    }
    func pop(video isVideo: Bool) -> QueuedSample? {
        condition.lock(); defer { condition.unlock() }
        guard !(isVideo ? video.isEmpty : audio.isEmpty) else { return nil }
        let result = isVideo ? video.removeFirst() : audio.removeFirst()
        condition.broadcast(); return result
    }
    @discardableResult func invalidate(close: Bool = false) -> Int {
        condition.lock(); defer { condition.unlock() }
        generation += 1; video.removeAll(); audio.removeAll(); eof = false; failure = nil; closed = close
        condition.broadcast(); return generation
    }
    func finish(_ error: String? = nil, generation expected: Int? = nil) { condition.lock(); defer { condition.unlock() }; if let expected, expected != generation { return }; eof = true; failure = error; condition.broadcast() }
    func snapshot() -> (generation: Int, video: Int, audio: Int, eof: Bool, error: String?, videoEnd: Double, audioEnd: Double) {
        condition.lock(); defer { condition.unlock() }; return (generation, video.count, audio.count, eof, failure, video.last?.end ?? 0, audio.last?.end ?? 0)
    }
}

final class NativeWorker: @unchecked Sendable {
    let mailbox = FrameMailbox()
    private let lock = NSLock()
    private var decoder: OpaquePointer?
    private var source: ByteSource?
    private var stopped = false
    private var pendingSeek: (Double, Int, Bool, Int)?
    private var generation = 0
    private let factory = SampleFactory()
    private let input: MediaSource
    private let threads: Int
    private var diagnostics = PlaybackDiagnostics()
    private let metricsLock = NSLock()
    func report() -> PlaybackDiagnostics { metricsLock.lock(); defer { metricsLock.unlock() }; return diagnostics }
    private let onInfo: @Sendable (MediaInfo, Int) -> Void
    private let onFinish: @Sendable (PlaybackDiagnostics) -> Void
    private let benchmarkSeconds: Double?
    private let initialTime: Double
    private let initialAudio: Int?
    private var callbackError: String?
    private var benchmarkStart: Double = 0
    private var callbackWait: Double = 0
    private var expectedAudioEnd: Double?

    init(source: MediaSource, threads: Int = 4, benchmarkSeconds: Double? = nil, initialTime: Double = 0, initialAudio: Int? = nil,
         onInfo: @escaping @Sendable (MediaInfo, Int) -> Void,
         onFinish: @escaping @Sendable (PlaybackDiagnostics) -> Void) {
        input = source; self.threads = threads; self.benchmarkSeconds = benchmarkSeconds
        self.onInfo = onInfo; self.onFinish = onFinish; self.initialTime = initialTime; self.initialAudio = initialAudio
        diagnostics.workerThreads = threads; diagnostics.transport = source.transport
    }
    func start() { DispatchQueue(label: "mvc.decode", qos: .userInitiated).async { self.run() } }
    func stop() {
        lock.lock(); stopped = true; source?.cancel(); if let decoder { mvc_cancel(decoder) }; lock.unlock()
        mailbox.invalidate(close: true)
    }
    func seek(_ time: Double, audio: Int, swap: Bool) {
        lock.lock()
        let newGeneration = mailbox.invalidate()
        pendingSeek = (time, audio, swap, newGeneration)
        source?.cancel(); if let decoder { mvc_cancel(decoder) }
        lock.unlock()
    }
    private func failed(_ message: String) { metricsLock.lock(); diagnostics.rendererErrors.append(message); metricsLock.unlock(); mailbox.finish(message, generation: generation) }
    private func run() {
        defer { lock.lock(); source = nil; lock.unlock() }
        defer { metricsLock.lock(); diagnostics.thermalState = thermalName(); metricsLock.unlock(); onFinish(report()) }
        do {
            let opened: ByteSource
            switch input { case .local(let url): opened = try LocalByteSource(url); case .http(let url): opened = try HTTPByteSource(url, onPrepared: { input in
                self.lock.lock(); self.source = input; let stopped = self.stopped; self.lock.unlock()
                if stopped { input.cancel() }
            }) }
            lock.lock(); source = opened; let cancelled = stopped; lock.unlock()
            if cancelled { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            let io = MVCIO(context: context, read_at: { ctx, offset, buffer, count in
                guard let ctx, let buffer else { return -1 }
                let worker = Unmanaged<NativeWorker>.fromOpaque(ctx).takeUnretainedValue()
                guard let source = worker.source else { return -1 }
                return Int32(source.read(at: offset, into: buffer, count: Int(count)))
            }, size: opened.size)
            let callbacks = MVCCallbacks(context: context, video: { ctx, frame in
                guard let ctx, let frame else { return 0 }
                return Unmanaged<NativeWorker>.fromOpaque(ctx).takeUnretainedValue().video(frame.pointee) ? 1 : 0
            }, audio: { ctx, frame in
                guard let ctx, let frame else { return 0 }
                return Unmanaged<NativeWorker>.fromOpaque(ctx).takeUnretainedValue().audio(frame.pointee) ? 1 : 0
            })
            guard let native = mvc_create(io, callbacks, Int32(threads)) else { throw MVCFailure("Cannot allocate MVC decoder") }
            lock.lock(); decoder = native; let wasStopped = stopped; lock.unlock()
            defer {
                lock.lock(); decoder = nil; lock.unlock()
                mvc_close(native)
                lock.lock(); source = nil; lock.unlock()
            }
            if wasStopped { return }
            guard mvc_open(native) == 0 else { throw MVCFailure(String(cString: mvc_error(native))) }
            let info = MediaInfo(mvc_info(native).pointee)
            factory.info = info; metricsLock.lock(); diagnostics.media = info; metricsLock.unlock()
            let selected = initialAudio ?? Int(mvc_selected_audio(native))
            if initialTime > 0 || selected != Int(mvc_selected_audio(native)) {
                guard mvc_seek(native, Int64(initialTime * 1_000_000), Int32(selected)) == 0 else { throw MVCFailure(String(cString: mvc_error(native))) }
            }
            onInfo(info, selected)
            benchmarkStart = ProcessInfo.processInfo.systemUptime
            while true {
                lock.lock()
                let end = stopped, command = pendingSeek
                pendingSeek = nil
                lock.unlock()
                if end { break }
                if let command {
                    generation = command.3; factory.swapEyes = command.2
                    opened.resetCancellation(); mvc_reset_cancel(native)
                    callbackError = nil; expectedAudioEnd = nil
                    guard mvc_seek(native, Int64(command.0 * 1_000_000), Int32(command.1)) == 0 else { throw MVCFailure(String(cString: mvc_error(native))) }
                }
                let before = ProcessInfo.processInfo.systemUptime, oldWait = callbackWait
                let result = mvc_step(native)
                let elapsed = ProcessInfo.processInfo.systemUptime - before
                metricsLock.lock()
                diagnostics.decodeAndCopySeconds += max(0, elapsed - (callbackWait - oldWait))
                diagnostics.decodeWallSeconds = ProcessInfo.processInfo.systemUptime - benchmarkStart
                let wall = diagnostics.decodeWallSeconds
                metricsLock.unlock()
                if let seconds = benchmarkSeconds, wall >= seconds { mailbox.finish(generation: generation); break }
                if result == 0 {
                    mailbox.finish(generation: generation)
                    // Keep the decoder alive at EOF so a seek/replay uses the same session.
                    if benchmarkSeconds != nil { break }
                    lock.lock(); let done = stopped || pendingSeek != nil; lock.unlock()
                    if !done { Thread.sleep(forTimeInterval: 0.02) }
                } else if result == -2 {
                    lock.lock(); let transitioning = stopped || pendingSeek != nil; lock.unlock()
                    if !transitioning { throw MVCFailure(callbackError ?? "Playback interrupted") }
                } else if result < 0 { throw MVCFailure(callbackError ?? String(cString: mvc_error(native))) }
            }
        } catch { lock.lock(); let expected = stopped; lock.unlock(); if !expected { failed(error.localizedDescription) } }
    }
    private func video(_ frame: MVCVideoFrame) -> Bool {
        do {
            let sample = try factory.video(frame)
            metricsLock.lock()
            diagnostics.stereoConfirmed = true; diagnostics.decodedPairs += 1
            if frame.flags & 1 != 0 { diagnostics.concealedPairs += 1 }
            metricsLock.unlock()
            if benchmarkSeconds != nil { return true }
            let before = ProcessInfo.processInfo.systemUptime
            let accepted = mailbox.push(sample, video: true, generation: generation)
            callbackWait += ProcessInfo.processInfo.systemUptime - before
            return accepted
        } catch { callbackError = error.localizedDescription; return false }
    }
    private func audio(_ frame: MVCAudioFrame) -> Bool {
        do {
            let timestamp = Double(frame.pts_us)
            metricsLock.lock()
            diagnostics.renderedAudioChannels = Int(frame.channels)
            if let expectedAudioEnd {
                let delta = abs(timestamp - expectedAudioEnd)
                if delta > 2 { diagnostics.audioTimingGaps += 1 }
                diagnostics.maxAudioTimingGapMicroseconds = max(diagnostics.maxAudioTimingGapMicroseconds, delta)
            }
            metricsLock.unlock()
            expectedAudioEnd = timestamp + Double(frame.sample_count) * 1_000_000 / Double(frame.sample_rate)
            if benchmarkSeconds != nil { return true }
            let sample = try factory.audio(frame)
            let before = ProcessInfo.processInfo.systemUptime
            let accepted = mailbox.push(sample, video: false, generation: generation)
            callbackWait += ProcessInfo.processInfo.systemUptime - before
            return accepted
        } catch { callbackError = error.localizedDescription; return false }
    }
}
