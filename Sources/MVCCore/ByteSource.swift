import Foundation
import Darwin

protocol ByteSource: AnyObject {
    var size: Int64 { get }
    func read(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int
    func cancel()
    func resetCancellation()
}

final class LocalByteSource: ByteSource {
    private let descriptor: Int32
    private let url: URL
    private let scoped: Bool
    private let lock = NSLock()
    private var cancelled = false
    let size: Int64
    init(_ url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw MVCFailure("Cannot open local file: \(String(cString: strerror(errno)))")
        }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_size > 0 else {
            Darwin.close(descriptor)
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw MVCFailure("File is empty or cannot be inspected")
        }
        size = attributes.st_size
    }
    deinit { Darwin.close(descriptor); if scoped { url.stopAccessingSecurityScopedResource() } }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func resetCancellation() { lock.lock(); cancelled = false; lock.unlock() }
    func read(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { return -1 }
        var result: Int
        repeat { result = pread(descriptor, buffer, count, offset) } while result < 0 && errno == EINTR
        return result
    }
}
