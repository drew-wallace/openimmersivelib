import Foundation
import CoreMedia
import CoreVideo
import AudioToolbox
import CMVC

final class SampleFactory {
    private var pool: CVPixelBufferPool?
    private var poolKey = ""
    private var stereoFormat: CMTaggedBufferGroupFormatDescription?
    private var formatKey = ""
    private var cachedAudioFormat: CMAudioFormatDescription?
    private var cachedAudioRate = 0
    private var cachedAudioIDs: [MVCChannel] = []
    var info: MediaInfo?
    var swapEyes = false

    private func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let range = info?.fullRange ?? false
        let key = "\(width)x\(height):\(range)"
        if key != poolKey {
            let attrs: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let result = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 20] as CFDictionary, attrs as CFDictionary, &pool)
            guard result == kCVReturnSuccess else { throw MVCFailure("Cannot allocate stereo pixel-buffer pool (\(result))") }
            poolKey = key
        }
        var pixel: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool!, [kCVPixelBufferPoolAllocationThresholdKey: 48] as CFDictionary, &pixel)
        guard result == kCVReturnSuccess, let pixel else { throw MVCFailure("Stereo pixel-buffer pool exhausted (\(result))") }
        let matrix: CFString = info?.colorMatrix == 9 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : (info?.colorMatrix == 6 || info?.colorMatrix == 5 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        let primaries: CFString
        switch info?.colorPrimaries {
        case 5: primaries = kCVImageBufferColorPrimaries_EBU_3213
        case 6: primaries = kCVImageBufferColorPrimaries_SMPTE_C
        case 9: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        default: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        }
        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, info?.colorTransfer == 13 ? kCVImageBufferTransferFunction_sRGB : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if let info {
            CVBufferSetAttachment(pixel, kCVImageBufferPixelAspectRatioKey,
                [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int((info.sampleAspectRatio * 10000).rounded()),
                 kCVImageBufferPixelAspectRatioVerticalSpacingKey: 10000] as CFDictionary, .shouldPropagate)
        }
        return pixel
    }
    private func copyView(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>, frame: MVCVideoFrame) throws -> CVPixelBuffer {
        let pixel = try buffer(width: Int(frame.width), height: Int(frame.height))
        let result = CVPixelBufferLockBaseAddress(pixel, [])
        guard result == kCVReturnSuccess else { throw MVCFailure("Cannot lock pixel buffer") }
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let destY = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let destUV = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
        let strideY = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), strideUV = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
        guard mvc_copy_nv12(y, u, v, frame.width, frame.height, frame.stride_y, frame.stride_c,
                            destY, destUV, Int32(strideY), Int32(strideUV)) == 0 else { throw MVCFailure("Invalid YUV plane geometry") }
        return pixel
    }
    func video(_ frame: MVCVideoFrame) throws -> CMSampleBuffer {
        guard let by = frame.base_y, let bu = frame.base_u, let bv = frame.base_v,
              let dy = frame.dependent_y, let du = frame.dependent_u, let dv = frame.dependent_v else { throw MVCFailure("Incomplete stereo pair") }
        let base = try copyView(y: by, u: bu, v: bv, frame: frame)
        let dependent = try copyView(y: dy, u: du, v: dv, frame: frame)
        let reversed = (info?.baseIsRight ?? false) != swapEyes
        let tags = [
            CMTaggedBuffer(tags: [.videoLayerID(0), .stereoView(.leftEye), .mediaType(.video)], pixelBuffer: reversed ? dependent : base),
            CMTaggedBuffer(tags: [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)], pixelBuffer: reversed ? base : dependent)
        ]
        let key = "\(frame.width)x\(frame.height):\(info?.fullRange ?? false)"
        if key != formatKey {
            stereoFormat = CMTaggedBufferGroupFormatDescription(taggedBuffers: tags)
            formatKey = key
        }
        return CMSampleBuffer(taggedBuffers: tags, presentationTimeStamp: CMTime(value: frame.pts_us, timescale: 1_000_000),
                              duration: CMTime(value: frame.duration_us, timescale: 1_000_000), formatDescription: stereoFormat!)
    }

    static func channelLabel(_ channel: MVCChannel, hasSideChannels: Bool) -> AudioChannelLabel {
        switch channel {
        case MVC_CH_LEFT: return kAudioChannelLabel_Left
        case MVC_CH_RIGHT: return kAudioChannelLabel_Right
        case MVC_CH_CENTER: return kAudioChannelLabel_Center
        case MVC_CH_LFE: return kAudioChannelLabel_LFEScreen
        case MVC_CH_SIDE_LEFT: return kAudioChannelLabel_LeftSurround
        case MVC_CH_SIDE_RIGHT: return kAudioChannelLabel_RightSurround
        case MVC_CH_BACK_LEFT: return hasSideChannels ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
        case MVC_CH_BACK_RIGHT: return hasSideChannels ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
        case MVC_CH_BACK_CENTER: return kAudioChannelLabel_CenterSurround
        default: return kAudioChannelLabel_Unknown
        }
    }
    private func audioFormat(rate: Int, ids: [MVCChannel]) throws -> CMAudioFormatDescription {
        if let format = cachedAudioFormat, cachedAudioRate == rate, cachedAudioIDs == ids { return format }
        let channels = ids.count
        let size = MemoryLayout<AudioChannelLayout>.size + (channels - 1) * MemoryLayout<AudioChannelDescription>.size
        let layout = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { layout.deallocate() }
        layout.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let typed = layout.assumingMemoryBound(to: AudioChannelLayout.self)
        typed.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        typed.pointee.mNumberChannelDescriptions = UInt32(channels)
        let descriptions = layout.advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!).assumingMemoryBound(to: AudioChannelDescription.self)
        let hasSide = ids.contains(MVC_CH_SIDE_LEFT)
        for index in 0..<channels {
            descriptions[index].mChannelLabel = Self.channelLabel(ids[index], hasSideChannels: hasSide)
            guard descriptions[index].mChannelLabel != kAudioChannelLabel_Unknown else { throw MVCFailure("Unknown PCM channel label") }
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: size, layout: typed,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw MVCFailure("PCM format creation failed (\(status))") }
        cachedAudioFormat = format; cachedAudioRate = rate; cachedAudioIDs = ids
        return format
    }
    func audio(_ frame: MVCAudioFrame) throws -> CMSampleBuffer {
        let channels = Int(frame.channels), frames = Int(frame.sample_count)
        guard channels > 0, channels <= 8, frames > 0, let samples = frame.samples else { throw MVCFailure("Invalid PCM frame") }
        var tuple = frame.channel_ids
        let ids = withUnsafePointer(to: &tuple) { p in p.withMemoryRebound(to: MVCChannel.self, capacity: 8) { Array(UnsafeBufferPointer(start: $0, count: channels)) } }
        let format = try audioFormat(rate: Int(frame.sample_rate), ids: ids)
        var status: OSStatus
        var block: CMBlockBuffer?
        let bytes = frames * channels * 4
        status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw MVCFailure("PCM allocation failed") }
        status = CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        guard status == noErr else { throw MVCFailure("PCM copy failed") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: frame.sample_rate),
            presentationTimeStamp: CMTime(value: frame.pts_us, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw MVCFailure("PCM sample creation failed (\(status))") }
        return sample
    }
}
