import Foundation

/// Balances access to a Files URL across replacement, stop, and destruction.
final class SecurityScopedResource {
    private let url: URL
    private let release: (URL) -> Void

    init?(_ url: URL,
          acquire: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
          release: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        guard acquire(url) else { return nil }
        self.url = url
        self.release = release
    }

    isolated deinit { release(url) }
}
