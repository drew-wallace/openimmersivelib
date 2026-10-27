import Foundation

/// A seekable input read on a decoder worker, with thread-safe cancellation.
public protocol ByteSource: AnyObject {
    var size: Int64 { get }
    func read(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int
    func cancel()
    func resetCancellation()
}

public struct ByteSourceFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
