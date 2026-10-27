#if os(macOS)
import XCTest
import CMVC
import Foundation
@testable import MVCCore

private final class DecodeCapture {
    let source: LocalByteSource
    var hashes: [[String]] = []
    var timestamps: [Int64] = []
    var audioTimestamps: [Int64] = []
    var audioChannels: Set<Int> = []
    var audioSamples = 0
    init(_ url: URL) throws { source = try LocalByteSource(url) }
    func video(_ frame: MVCVideoFrame) {
        var pair: [String] = []
        for planes in [[frame.base_y,frame.base_u,frame.base_v],[frame.dependent_y,frame.dependent_u,frame.dependent_v]] {
            var hash: UInt64 = 0xcbf29ce484222325
            for (index,plane) in planes.enumerated() {
                let width = Int(index == 0 ? frame.width : frame.chroma_width), height = Int(index == 0 ? frame.height : frame.chroma_height)
                let stride = Int(index == 0 ? frame.stride_y : frame.stride_c)
                for row in 0..<height { for column in 0..<width { hash = (hash ^ UInt64(plane![row * stride + column])) &* 0x100000001b3 } }
            }
            pair.append(String(format: "%016llx", hash))
        }
        hashes.append(pair); timestamps.append(frame.pts_us)
    }
}
final class DecodeIntegrationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    override class func setUp() {
        super.setUp()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3",root.appendingPathComponent("Scripts/make_test_fixture.py").path]
        process.currentDirectoryURL = root
        do { try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0) }
        catch { XCTFail(error.localizedDescription) }
    }
    func testSampleClockIgnoresDTSContainerQuantizationWithoutDrift() throws {
        let root = Self.root
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        let binary = root.appendingPathComponent(".build/audio-clock-regression")
        compile.arguments = ["clang", "-O2", "-I", root.appendingPathComponent("Sources/CMVC").path,
            "-I", root.appendingPathComponent(".build/native/macos/ffmpeg/include").path,
            root.appendingPathComponent("Tests/NativeAudioClockTests.c").path,
            root.appendingPathComponent(".build/native/macos/libCMVC.a").path, "-lz", "-liconv", "-o", binary.path]
        try compile.run(); compile.waitUntilExit(); XCTAssertEqual(compile.terminationStatus, 0)
        let run = Process(); run.executableURL = binary
        try run.run(); run.waitUntilExit(); XCTAssertEqual(run.terminationStatus, 0)
    }
    private func decoder(_ capture: DecodeCapture, threads: Int32) throws -> OpaquePointer {
        let context = Unmanaged.passUnretained(capture).toOpaque()
        let io = MVCIO(context: context, read_at: { ctx, offset, buffer, count in
            Int32(Unmanaged<DecodeCapture>.fromOpaque(ctx!).takeUnretainedValue().source.read(at: offset, into: buffer!, count: Int(count)))
        }, size: capture.source.size)
        let callbacks = MVCCallbacks(context: context, video: { ctx, frame in
            Unmanaged<DecodeCapture>.fromOpaque(ctx!).takeUnretainedValue().video(frame!.pointee); return 1
        }, audio: { ctx, frame in
            let capture = Unmanaged<DecodeCapture>.fromOpaque(ctx!).takeUnretainedValue()
            capture.audioTimestamps.append(frame!.pointee.pts_us)
            capture.audioSamples += Int(frame!.pointee.sample_count)
            capture.audioChannels.insert(Int(frame!.pointee.channels)); return 1
        })
        let decoder = try XCTUnwrap(mvc_create(io, callbacks, threads))
        let status = mvc_open(decoder)
        guard status == 0 else { let message = String(cString: mvc_error(decoder)); mvc_close(decoder); throw MVCFailure(message) }
        return decoder
    }
    private func drain(_ decoder: OpaquePointer) throws {
        for _ in 0..<1000 {
            let result = mvc_step(decoder)
            if result == 0 { return }
            if result < 0 { throw MVCFailure(String(cString: mvc_error(decoder))) }
        }
        throw MVCFailure("Demuxer failed to reach EOF")
    }
    func testMKVBothEyesMatchReferenceWithBFramePTS() throws {
        struct Reference: Decodable {
            struct Hash: Decodable { let view: Int, display: Int; let hash: String }
            let frames: Int
            let hashes: [Hash]
        }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: Self.root.appendingPathComponent(".build/fixtures/mvc-bframes-reference.json")))
        for threads: Int32 in [1, 2, 4, 6, 8] {
            let capture = try DecodeCapture(Self.root.appendingPathComponent(".build/fixtures/mvc-bframes.mkv"))
            let native = try decoder(capture, threads: threads); defer { mvc_close(native) }
            try drain(native)
            XCTAssertEqual(capture.hashes.count, reference.frames)
            for row in reference.hashes { XCTAssertEqual(capture.hashes[row.display][row.view], row.hash) }
            XCTAssertEqual(capture.timestamps, capture.timestamps.sorted())
            XCTAssertEqual(Set(capture.timestamps).count, reference.frames)
            XCTAssertEqual(capture.audioChannels, [6])
            XCTAssertEqual(capture.audioSamples, reference.frames * 2000)
            XCTAssertEqual(mvc_saw_stereo(native), 1)
            XCTAssertEqual(mvc_selected_audio(native), 1)
        }
    }
    func testSeekDiscardsPrerollAndTrimsAudio() throws {
        let capture = try DecodeCapture(Self.root.appendingPathComponent(".build/fixtures/mvc-bframes.mkv"))
        let native = try decoder(capture, threads: 4); defer { mvc_close(native) }
        try drain(native)
        for target: Int64 in [150000, 0, 250000, 100000] {
            capture.hashes = []; capture.timestamps = []; capture.audioTimestamps = []
            mvc_cancel(native)
            XCTAssertEqual(mvc_step(native), -2)
            mvc_reset_cancel(native)
            XCTAssertEqual(mvc_seek(native, target, 1), 0, String(cString: mvc_error(native)))
            try drain(native)
            XCTAssertFalse(capture.timestamps.isEmpty)
            XCTAssertTrue(capture.timestamps.allSatisfy { $0 >= target })
            XCTAssertTrue(capture.audioTimestamps.allSatisfy { $0 >= target })
        }
    }
    func testAVCOnlyFileFailsWithoutStereoFallback() throws {
        let capture = try DecodeCapture(Self.root.appendingPathComponent(".build/fixtures/avc-only.mkv"))
        let native = try decoder(capture, threads: 2); defer { mvc_close(native) }
        XCTAssertThrowsError(try drain(native)) { error in
            XCTAssertTrue(error.localizedDescription.contains("MVC view missing"))
        }
        XCTAssertTrue(capture.hashes.isEmpty)
        XCTAssertEqual(mvc_saw_stereo(native), 0)
    }
}

#endif
