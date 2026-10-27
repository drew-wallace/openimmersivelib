import XCTest
@testable import MediaTransport

final class HTTPContentRangeTests: XCTestCase {
    func testResponseBoundsAreValidated() {
        let range = HTTPContentRange("bytes 100-199/1000")
        XCTAssertEqual(range?.first, 100)
        XCTAssertEqual(range?.last, 199)
        XCTAssertEqual(range?.total, 1000)
        for malformed in ["bytes */1000", "bytes 100-99/1000", "bytes 0-1000/1000", "items 0-1/2", "bytes -1-5/20"] {
            XCTAssertNil(HTTPContentRange(malformed))
        }
    }
}
