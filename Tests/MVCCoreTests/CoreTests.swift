import XCTest
import CMVC
import CoreMedia
import CoreVideo
import AudioToolbox
@testable import MVCCore

private final class NALCollector {
    var units: [Data] = []
}
final class CoreTests: XCTestCase {
    func testNALOrderAndLengthValidation() {
        for length in [1, 2, 4] {
            let nals: [[UInt8]] = [[0x67, 1], [0x6f, 2], [0x6e, 3], [0x65, 4], [0x74, 5]]
            var packet: [UInt8] = []
            for nal in nals {
                for i in (0..<length).reversed() { packet.append(UInt8((nal.count >> (8 * i)) & 255)) }
                packet += nal
            }
            let collector = NALCollector()
            let context = Unmanaged.passUnretained(collector).toOpaque()
            let result = packet.withUnsafeBufferPointer { buffer in
                mvc_visit_nals(buffer.baseAddress, buffer.count, Int32(length), { ctx, bytes, count in
                    Unmanaged<NALCollector>.fromOpaque(ctx!).takeUnretainedValue().units.append(Data(bytes: bytes!, count: count)); return 0
                }, context)
            }
            XCTAssertEqual(result, 0); XCTAssertEqual(collector.units, nals.map { Data($0) })
            packet.removeLast()
            XCTAssertEqual(packet.withUnsafeBufferPointer { mvc_visit_nals($0.baseAddress, $0.count, Int32(length), { _,_,_ in 0 }, nil) }, -1)
        }
        let truncated: [UInt8] = [0, 0, 0, 20, 0x65]
        XCTAssertEqual(truncated.withUnsafeBufferPointer { mvc_visit_nals($0.baseAddress, $0.count, 4, { _,_,_ in 0 }, nil) }, -1)
    }
    func testAnnexBPreservesAllMVCUnits() {
        let bytes: [UInt8] = [0,0,0,1,0x67,1,0,0,1,0x6f,2,0,0,0,1,0x74,3]
        let collector = NALCollector()
        XCTAssertEqual(bytes.withUnsafeBufferPointer { mvc_visit_nals($0.baseAddress, $0.count, 0, { ctx, p, n in
            Unmanaged<NALCollector>.fromOpaque(ctx!).takeUnretainedValue().units.append(Data(bytes: p!, count: n)); return 0
        }, Unmanaged.passUnretained(collector).toOpaque()) }, 0)
        XCTAssertEqual(collector.units, [Data([0x67,1]),Data([0x6f,2]),Data([0x74,3])])
    }
    func testMailboxInvalidationWakesBlockedProducer() {
        let mailbox = FrameMailbox()
        let sample = makeVideoSample()
        for _ in 0..<8 { XCTAssertTrue(mailbox.push(sample, video: true, generation: 0)) }
        let finished = expectation(description: "blocked producer cancelled")
        DispatchQueue.global().async {
            XCTAssertFalse(mailbox.push(sample, video: true, generation: 0)); finished.fulfill()
        }
        mailbox.invalidate()
        wait(for: [finished], timeout: 2)
        XCTAssertNil(mailbox.pop(video: true))
        XCTAssertTrue(mailbox.push(sample, video: true, generation: 1))
    }
    func testMultichannelPCMLabelsAndSampleCount() throws {
        for ids: [MVCChannel] in [[MVC_CH_LEFT,MVC_CH_RIGHT,MVC_CH_CENTER,MVC_CH_LFE,MVC_CH_BACK_LEFT,MVC_CH_BACK_RIGHT],
             [MVC_CH_LEFT,MVC_CH_RIGHT,MVC_CH_CENTER,MVC_CH_LFE,MVC_CH_BACK_LEFT,MVC_CH_BACK_RIGHT,MVC_CH_SIDE_LEFT,MVC_CH_SIDE_RIGHT]] {
            var frame = MVCAudioFrame(); frame.channels = Int32(ids.count); frame.sample_count = 480; frame.sample_rate = 48000; frame.pts_us = 250000
            withUnsafeMutablePointer(to: &frame.channel_ids) { p in p.withMemoryRebound(to: MVCChannel.self, capacity: 8) { for i in ids.indices { $0[i] = ids[i] } } }
            let samples = Array(repeating: Float(0.125), count: ids.count * 480)
            let result = try samples.withUnsafeBufferPointer { buffer -> CMSampleBuffer in frame.samples = buffer.baseAddress; return try SampleFactory().audio(frame) }
            XCTAssertEqual(result.numSamples, 480)
            XCTAssertEqual(result.presentationTimeStamp.seconds, 0.25, accuracy: 0.000001)
            let format = result.formatDescription!
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee.mChannelsPerFrame, UInt32(ids.count))
            var size = 0
            let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size)!
            XCTAssertEqual(layout.pointee.mNumberChannelDescriptions, UInt32(ids.count))
            XCTAssertEqual(CMBlockBufferGetDataLength(result.dataBuffer!), samples.count * 4)
        }
        XCTAssertEqual(SampleFactory.channelLabel(MVC_CH_BACK_LEFT, hasSideChannels: true), kAudioChannelLabel_RearSurroundLeft)
        XCTAssertEqual(SampleFactory.channelLabel(MVC_CH_SIDE_LEFT, hasSideChannels: true), kAudioChannelLabel_LeftSurround)
    }
    func testReportContainsNoSourceURL() throws {
        let text = String(data: try PlaybackDiagnostics().json(), encoding: .utf8)!
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("http://"))
    }
    func testHTTPRangeValidation() {
        XCTAssertEqual(HTTPContentRange("bytes 100-199/1000"), HTTPContentRange("bytes 100-199/1000"))
        XCTAssertEqual(HTTPContentRange("bytes 100-199/1000")?.total, 1000)
        for malformed in ["bytes */1000", "bytes 100-99/1000", "bytes 0-1000/1000", "items 0-1/2", "bytes -1-5/20"] {
            XCTAssertNil(HTTPContentRange(malformed))
        }
    }
    func testStereoTagsAndEyeSwap() throws {
        let base = [UInt8](repeating: 40, count: 16*16), dependent = [UInt8](repeating: 200, count: 16*16)
        let chroma = [UInt8](repeating: 128, count: 8*8)
        let factory = SampleFactory()
        for swapped in [false, true] {
            factory.swapEyes = swapped
            let sample = try base.withUnsafeBufferPointer { b in try dependent.withUnsafeBufferPointer { d in try chroma.withUnsafeBufferPointer { c in
                var frame = MVCVideoFrame(); frame.base_y = b.baseAddress; frame.dependent_y = d.baseAddress
                frame.base_u = c.baseAddress; frame.base_v = c.baseAddress; frame.dependent_u = c.baseAddress; frame.dependent_v = c.baseAddress
                frame.width = 16; frame.height = 16; frame.chroma_width = 8; frame.chroma_height = 8; frame.stride_y = 16; frame.stride_c = 8
                frame.duration_us = 41667; return try factory.video(frame)
            } } }
            let buffers = try XCTUnwrap(sample.taggedBuffers)
            XCTAssertEqual(buffers.count, 2)
            XCTAssertTrue(buffers[0].tags.contains(.mediaType(.video)))
            XCTAssertTrue(buffers[0].tags.contains(.stereoView(.leftEye)))
            XCTAssertTrue(buffers[1].tags.contains(.stereoView(.rightEye)))
            guard case .pixelBuffer(let left) = buffers[0].buffer else { return XCTFail("Missing pixel buffer") }
            CVPixelBufferLockBaseAddress(left, .readOnly)
            XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(left, 0)!.load(as: UInt8.self), swapped ? 200 : 40)
            CVPixelBufferUnlockBaseAddress(left, .readOnly)
        }
    }
    private func makeVideoSample() -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel)
        let format = try! CMVideoFormatDescription(imageBuffer: pixel!)
        return try! CMSampleBuffer(imageBuffer: pixel!, formatDescription: format,
            sampleTiming: CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 24),presentationTimeStamp: .zero,decodeTimeStamp: .invalid))
    }
}
