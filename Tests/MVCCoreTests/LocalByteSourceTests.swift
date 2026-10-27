import XCTest
@testable import MVCCore

final class LocalByteSourceTests: XCTestCase {
    func testOffsetReadsEOFAndCancellation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([10, 20, 30, 40]).write(to: url)
        let source = try LocalByteSource(url)
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { source.read(at: 1, into: $0.baseAddress!, count: 2) }, 2)
        XCTAssertEqual(bytes, [20, 30])
        var byte: UInt8 = 0
        XCTAssertEqual(source.read(at: 4, into: &byte, count: 1), 0)
        source.cancel()
        XCTAssertEqual(source.read(at: 0, into: &byte, count: 1), -1)
        source.resetCancellation()
        XCTAssertEqual(source.read(at: 0, into: &byte, count: 1), 1)
        XCTAssertEqual(byte, 10)
    }
}
