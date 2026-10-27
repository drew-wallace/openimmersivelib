import Testing
import AVFoundation
@testable import OpenImmersive

@Suite(.serialized) @MainActor
struct ContainerPreparationTests {
    @Test func extensionlessResourceOpensAutomaticallyAndPreservesEarlyPause() async throws {
        let backend = FakeMVC()
        var complete: CheckedContinuation<VideoItem, Never>?
        let player = VideoPlayer(makeMVC: { backend }, prepareItem: { item in
            await withCheckedContinuation { complete = $0 }
        })
        defer { player.stop() }
        let item = VideoItem(metadata: [:], url: URL(string: "https://example.test/resource")!)
        player.openItem(item)
        await Task.yield()
        player.play()
        player.pause()
        player.seek(to: 0.15)
        var prepared = item; prepared.playbackEngine = .mvc; prepared.projection = .rectangular
        complete?.resume(returning: prepared)
        for _ in 0..<100 where !player.isMVC { try await Task.sleep(for: .milliseconds(5)) }
        #expect(player.isMVC)
        try backend.ready()
        #expect(player.paused)
        #expect(!backend.playbackRequested)
        #expect(backend.seeks == [0.15])
    }

    @Test func replacedItemsRejectLateContainerProbes() async throws {
        var complete: CheckedContinuation<VideoItem, Never>?
        var created = 0
        let player = VideoPlayer(makeMVC: { created += 1; return FakeMVC() }, prepareItem: { item in
            await withCheckedContinuation { complete = $0 }
        })
        defer { player.stop() }
        var old = VideoItem(metadata: [:], url: URL(string: "https://example.test/resource")!)
        player.openItem(old)
        await Task.yield()
        let current = VideoItem(metadata: [:], url: URL(fileURLWithPath: "/tmp/new.mov"))
        player.openItem(current)
        old.playbackEngine = .mvc
        complete?.resume(returning: old)
        try await Task.sleep(for: .milliseconds(30))
        #expect(player.url == current.url)
        #expect(!player.isMVC)
        #expect(created == 0)
    }
}
