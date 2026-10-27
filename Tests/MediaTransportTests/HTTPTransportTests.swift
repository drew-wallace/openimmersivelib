#if os(macOS)
import XCTest
import Darwin
@testable import MediaTransport

final class HTTPTransportTests: XCTestCase {
    private var server: Process!
    private var port = ""
    override func setUpWithError() throws {
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        server.arguments = ["python3", "-u", root.appendingPathComponent("Scripts/test_http_server.py").path]
        let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run()
        port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(Int(port))
    }
    override func tearDown() { if server.isRunning { kill(server.processIdentifier, SIGKILL); server.waitUntilExit() } }
    func testPrefetchRandomReadsAndCancellationReset() throws {
        let source = try HTTPByteSource(URL(string: "http://127.0.0.1:\(port)/data")!)
        XCTAssertEqual(source.size, 64*1024*1024)
        for offset: Int64 in [0, 4*1024*1024-32, 4*1024*1024+96, 12*1024*1024+20, 0] {
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = bytes.withUnsafeMutableBufferPointer { source.read(at: offset, into: $0.baseAddress!, count: $0.count) }
            XCTAssertGreaterThan(count, 0)
            for i in 0..<max(0,count) { XCTAssertEqual(bytes[i], UInt8((offset + Int64(i)) % 251)) }
        }
        source.cancel()
        var byte: UInt8 = 0
        XCTAssertEqual(source.read(at: 0, into: &byte, count: 1), -1)
        source.resetCancellation()
        XCTAssertEqual(source.read(at: 0, into: &byte, count: 1), 1)
        XCTAssertEqual(byte, 0)
    }
    func testCancellationWakesAnActiveNetworkRead() throws {
        let source = try HTTPByteSource(URL(string: "http://127.0.0.1:\(port)/slow")!)
        let finished = expectation(description: "read cancelled")
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            XCTAssertEqual(source.read(at: 0, into: &byte, count: 1), -1)
            finished.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { source.cancel() }
        wait(for: [finished], timeout: 1)
    }
    func testRejectsIgnoredIncorrectAndTruncatedRanges() {
        for path in ["ignores-range", "wrong-range", "truncated"] {
            XCTAssertThrowsError(try HTTPByteSource(URL(string: "http://127.0.0.1:\(port)/\(path)")!))
        }
    }
    func testCancellationAlsoInterruptsOpeningProbe() {
        let began = Date()
        XCTAssertThrowsError(try HTTPByteSource(URL(string: "http://127.0.0.1:\(port)/slow-probe")!, onPrepared: { source in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { source.cancel() }
        }))
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    }

    func testCacheRemainsBoundedAcrossMoreThanEightBlocks() throws {
        let source = try HTTPByteSource(URL(string: "http://127.0.0.1:\(port)/data")!)
        defer { source.cancel() }
        for block in 0..<12 {
            var byte: UInt8 = 0
            XCTAssertEqual(source.read(at: Int64(block * 4 * 1024 * 1024), into: &byte, count: 1), 1)
            XCTAssertLessThanOrEqual(source.cachedByteCount, 32 * 1024 * 1024)
        }
    }

    func testContainerProbeSupportsExtensionlessResources() async throws {
        let matroska = try await HTTPByteSource.isMatroska(URL(string: "http://127.0.0.1:\(port)/matroska")!)
        let other = try await HTTPByteSource.isMatroska(URL(string: "http://127.0.0.1:\(port)/data")!)
        XCTAssertTrue(matroska)
        XCTAssertFalse(other)
    }
    func testContainerProbeCancellationInterruptsTheRequest() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/slow-probe")!
        let task = Task { try await HTTPByteSource.isMatroska(url) }
        try await Task.sleep(for: .milliseconds(100))
        let began = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Probe should be cancelled") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    }

}

#endif
