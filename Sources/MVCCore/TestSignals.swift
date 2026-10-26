import Foundation
import CMVC

// Deliberately generated at full 1080p per eye, exercising the same NV12 copy,
// tagging, multichannel conversion, queueing and presentation paths as a movie.
final class TestSignalProducer: @unchecked Sendable {
    let mailbox = FrameMailbox()
    let channels: Int
    static let width = 1920, height = 1080
    init(channels: Int) { self.channels = channels }
    func stop() { mailbox.invalidate(close: true) }
    func start() {
        DispatchQueue(label: "mvc.test-signal", qos: .userInitiated).async { self.run() }
    }
    static func info() -> MediaInfo {
        var info = MVCMediaInfo()
        info.width = Int32(width); info.height = Int32(height); info.fps = 24; info.duration = 32
        info.sar_num = 1; info.sar_den = 1
        return MediaInfo(info)
    }
    static func luma(right: Bool) -> [UInt8] {
        let letter = right ? ["11110","10001","10001","11110","10100","10010","10001"] : ["10000","10000","10000","10000","10000","10000","11111"]
        var pixels = [UInt8](repeating: 32, count: width * height)
        let scale = 90, x0 = (width - 5 * scale)/2, y0 = (height - 7 * scale)/2
        for (row,line) in letter.enumerated() {
            for (column, character) in line.enumerated() where character == "1" {
                for y in (y0 + row * scale)..<(y0 + (row + 1) * scale) {
                    for x in (x0 + column * scale)..<(x0 + (column + 1) * scale) { pixels[y * width + x] = 210 }
                }
            }
        }
        return pixels
    }
    private func run() {
        let factory = SampleFactory(); factory.info = Self.info()
        let left = Self.luma(right: false), right = Self.luma(right: true)
        let chroma = [UInt8](repeating: 128, count: Self.width * Self.height / 4)
        let ids: [MVCChannel] = channels == 8 ? [MVC_CH_LEFT,MVC_CH_RIGHT,MVC_CH_CENTER,MVC_CH_LFE,MVC_CH_BACK_LEFT,MVC_CH_BACK_RIGHT,MVC_CH_SIDE_LEFT,MVC_CH_SIDE_RIGHT] : [MVC_CH_LEFT,MVC_CH_RIGHT,MVC_CH_CENTER,MVC_CH_LFE,MVC_CH_BACK_LEFT,MVC_CH_BACK_RIGHT]
        do {
            for frameNumber in 0..<(32 * 24) {
                let sample = try left.withUnsafeBufferPointer { l in
                    try right.withUnsafeBufferPointer { r in
                        try chroma.withUnsafeBufferPointer { c in
                            var frame = MVCVideoFrame()
                            frame.base_y = l.baseAddress; frame.dependent_y = r.baseAddress
                            frame.base_u = c.baseAddress; frame.base_v = c.baseAddress; frame.dependent_u = c.baseAddress; frame.dependent_v = c.baseAddress
                            frame.width = Int32(Self.width); frame.height = Int32(Self.height)
                            frame.chroma_width = Int32(Self.width/2); frame.chroma_height = Int32(Self.height/2)
                            frame.stride_y = Int32(Self.width); frame.stride_c = Int32(Self.width/2)
                            frame.pts_us = Int64(frameNumber) * 1_000_000 / 24; frame.duration_us = 41667
                            return try factory.video(frame)
                        }
                    }
                }
                guard mailbox.push(sample, video: true, generation: 0) else { return }
                let active = frameNumber / 24 % channels
                var pcm = [Float](repeating: 0, count: 2000 * channels)
                let frequency = active == 3 ? 60.0 : 440.0 + Double(active) * 80
                for index in 0..<2000 {
                    let global = frameNumber * 2000 + index
                    let withinSecond = global % 48000
                    let envelope = min(1, Double(withinSecond)/500) * min(1, Double(48000 - withinSecond)/500)
                    pcm[index * channels + active] = Float(0.1 * envelope * sin(2 * .pi * frequency * Double(global) / 48000))
                }
                let audio = try pcm.withUnsafeBufferPointer { values in
                    var frame = MVCAudioFrame(); frame.samples = values.baseAddress; frame.sample_count = 2000
                    frame.sample_rate = 48000; frame.channels = Int32(channels); frame.pts_us = Int64(frameNumber) * 1_000_000 / 24
                    withUnsafeMutablePointer(to: &frame.channel_ids) { pointer in
                        pointer.withMemoryRebound(to: MVCChannel.self, capacity: 8) { for i in ids.indices { $0[i] = ids[i] } }
                    }
                    return try factory.audio(frame)
                }
                guard mailbox.push(audio, video: false, generation: 0) else { return }
            }
            mailbox.finish()
        } catch { mailbox.finish(error.localizedDescription) }
    }
}
