import Foundation

struct HTTPContentRange: Equatable {
    let first: Int64, last: Int64, total: Int64
    init?(_ text: String) {
        guard text.hasPrefix("bytes ") else { return nil }
        let parts = text.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let size = Int64(parts[1]) else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first >= 0, last >= first, last < size else { return nil }
        self.first = first; self.last = last; total = size
    }
}
// Validate the response before accepting its body. A server ignoring Range must
// never cause a full Blu-ray download into URLSession's in-memory data buffer.
private final class RangeRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private var data = Data()
    private var result: Result<(Data, Int64), Error>?
    private var total: Int64 = 0
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private let first: Int64, last: Int64
    init(url: URL, first: Int64, last: Int64) {
        self.first = first; self.last = last
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // DLNA servers should deliver the original file, never a profile transcode.
        request.setValue("Streaming", forHTTPHeaderField: "transferMode.dlna.org")
        task = session.dataTask(with: request)
    }
    func wait() throws -> (Data, Int64) {
        task.resume()
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(22)
        while result == nil {
            if !condition.wait(until: deadline) {
                task.cancel(); throw ByteSourceFailure("HTTP byte-range request timed out")
            }
        }
        return try result!.get()
    }
    func cancel() {
        condition.lock()
        if result == nil { result = .failure(CancellationError()) }
        condition.broadcast(); condition.unlock()
        task.cancel()
    }
    private func fail(_ message: String) {
        condition.lock(); result = .failure(ByteSourceFailure(message)); condition.broadcast(); condition.unlock()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 206,
              let value = response.value(forHTTPHeaderField: "Content-Range"), let range = HTTPContentRange(value),
              range.first == first, range.last == min(last, range.total - 1), range.last - range.first < 4 * 1024 * 1024 else {
            fail("Server did not honor HTTP byte ranges. Select an original seekable media resource.")
            completionHandler(.cancel); return
        }
        total = range.total
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count + bytes.count <= last - first + 1 else { fail("HTTP range response exceeded its requested size"); dataTask.cancel(); return }
        data.append(bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        if result == nil {
            if let error { result = .failure(ByteSourceFailure("HTTP read failed: \(error.localizedDescription)")) }
            else if data.count != min(last, total - 1) - first + 1 { result = .failure(ByteSourceFailure("Truncated HTTP byte-range response")) }
            else { result = .success((data, total)) }
        }
        condition.broadcast(); condition.unlock()
        session.finishTasksAndInvalidate()
    }
}

public final class HTTPByteSource: ByteSource, @unchecked Sendable {
    public private(set) var size: Int64 = 0
    private let url: URL
    private let condition = NSCondition()
    private let network = DispatchQueue(label: "media.http.prefetch", qos: .userInitiated, attributes: .concurrent)
    private let blockSize: Int64 = 4 * 1024 * 1024
    private var generation = 0
    private var cancelled = false
    private var active: [Int64: RangeRequest] = [:]
    private var cache: [Int64: Data] = [:]
    private var order: [Int64] = []
    private var failures: Set<Int64> = []
    public init(_ url: URL, onPrepared: ((HTTPByteSource) -> Void)? = nil) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw ByteSourceFailure("Enter an HTTP(S) media URL") }
        self.url = url
        // MiniDLNA treats bytes=0-0 as an open-ended request; use two bytes.
        let request = RangeRequest(url: url, first: 0, last: 1)
        active[-1] = request
        onPrepared?(self)
        defer { condition.lock(); active[-1] = nil; condition.unlock() }
        let (_, size) = try request.wait()
        condition.lock(); let interrupted = cancelled; condition.unlock()
        guard !interrupted else { throw CancellationError() }
        self.size = size
    }
    /// Read only the container signature, without fetching a movie-sized block.
    /// Servers without range support can still be handled by another playback engine.
    public static func isMatroska(_ url: URL) async throws -> Bool {
        let request = RangeRequest(url: url, first: 0, last: 3)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        let (bytes, _) = try request.wait()
                        return bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3])
                    })
                }
            }
        }, onCancel: { request.cancel() })
    }

    /// Compressed cache storage, excluding in-flight response buffers.
    var cachedByteCount: Int {
        condition.lock(); defer { condition.unlock() }
        return cache.values.reduce(0) { $0 + $1.count }
    }
    public func cancel() {
        condition.lock(); cancelled = true; generation += 1
        let requests = Array(active.values); active.removeAll(); failures.removeAll()
        condition.broadcast(); condition.unlock()
        for request in requests { request.cancel() }
    }
    public func resetCancellation() { condition.lock(); cancelled = false; failures.removeAll(); condition.unlock() }
    // Caller holds condition. At most current + next block are requested per
    // sequential read. Eight cached blocks cap compressed storage at 32 MiB.
    private func fetchLocked(_ start: Int64) {
        guard start >= 0, start < size, cache[start] == nil, active[start] == nil, !failures.contains(start), !cancelled else { return }
        let request = RangeRequest(url: url, first: start, last: min(size - 1, start + blockSize - 1))
        let expected = generation
        active[start] = request
        network.async { [weak self] in
            let result = Result { try request.wait() }
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard expected == self.generation, !self.cancelled else { return }
            self.active[start] = nil
            switch result {
            case .success(let (data, total)) where total == self.size:
                self.cache[start] = data
                self.order.removeAll { $0 == start }; self.order.append(start)
                while self.order.count > 8 { self.cache[self.order.removeFirst()] = nil }
            default: self.failures.insert(start)
            }
            self.condition.broadcast()
        }
    }
    public func read(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard offset >= 0, count > 0 else { return -1 }
        if offset >= size { return offset == size ? 0 : -1 }
        let start = offset / blockSize * blockSize
        condition.lock()
        let expected = generation
        guard !cancelled else { condition.unlock(); return -1 }
        fetchLocked(start)
        let deadline = Date().addingTimeInterval(22)
        while cache[start] == nil && !cancelled && expected == generation && !failures.contains(start) {
            if !condition.wait(until: deadline) { condition.unlock(); return -1 }
        }
        guard !cancelled, expected == generation, let bytes = cache[start] else { condition.unlock(); return -1 }
        order.removeAll { $0 == start }; order.append(start)
        fetchLocked(start + blockSize)
        condition.unlock()
        let index = Int(offset - start), length = min(count, bytes.count - index)
        guard length > 0 else { return -1 }
        _ = bytes.withUnsafeBytes { memcpy(buffer, $0.baseAddress!.advanced(by: index), length) }
        return length
    }
    deinit { for request in active.values { request.cancel() } }
}
