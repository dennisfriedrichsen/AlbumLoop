import Testing
@testable import AlbumLoopCore

@Suite("ImageBuffer")
@MainActor
struct ImageBufferTests {
    private let target = PixelSize(width: 100, height: 100) // 40 000 bytes decoded

    private func makeBuffer(
        _ provider: FakeImageProvider,
        _ scheduler: ManualScheduler,
        configuration: ImageBuffer.Configuration
    ) -> ImageBuffer {
        ImageBuffer(provider: provider, scheduler: scheduler, targetPixelSize: target, configuration: configuration)
    }

    @Test("Download concurrency is bounded")
    func concurrencyBounded() async {
        let provider = FakeImageProvider()
        let scheduler = ManualScheduler()
        let buffer = makeBuffer(provider, scheduler, configuration: .init(prefetchAhead: 6, maxConcurrentLoads: 2))
        let items = ids(7)
        buffer.setWindow(needed: items[0], ahead: Array(items.dropFirst()), behind: [], onScreen: nil)
        await waitUntil { provider.pendingIDs.count == 2 }
        #expect(Set(provider.pendingIDs) == [items[0], items[1]], "needed image first, then playback order")

        for id in items {
            await provider.succeed(id)
        }
        await waitUntil { buffer.currentStats.ready == 7 }
        #expect(provider.maxInFlight == 2)
    }

    @Test("Decoded memory stays within the byte budget")
    func byteBudget() async {
        let provider = FakeImageProvider(byteCost: 40_000)
        let scheduler = ManualScheduler()
        let buffer = makeBuffer(provider, scheduler, configuration: .init(
            prefetchAhead: 8, keepBehind: 0, maxConcurrentLoads: 3, maxDecodedBytes: 120_000
        ))
        let items = ids(9)
        buffer.setWindow(needed: items[0], ahead: Array(items.dropFirst()), behind: [], onScreen: nil)
        for _ in 0..<5 {
            for id in provider.pendingIDs {
                provider.resolve(id, with: .success(provider.makeImage()))
            }
            await settle()
            let stats = buffer.currentStats
            #expect(stats.decodedBytes <= 120_000)
            #expect(stats.ready + stats.loading <= 3)
        }
        #expect(buffer.currentStats.ready == 3)
    }

    @Test("The needed image preempts a prefetch when all slots are busy")
    func neededPreemptsPrefetch() async {
        let provider = FakeImageProvider()
        let scheduler = ManualScheduler()
        let buffer = makeBuffer(provider, scheduler, configuration: .init(prefetchAhead: 3, maxConcurrentLoads: 2))
        let items = ids(4)
        buffer.setWindow(needed: nil, ahead: [items[1], items[2]], behind: [], onScreen: nil)
        await waitUntil { provider.pendingIDs.count == 2 }

        buffer.setWindow(needed: items[3], ahead: [items[1], items[2]], behind: [], onScreen: nil)
        await waitUntil { Set(provider.pendingIDs) == [items[3], items[1]] }
        #expect(buffer.status(for: items[2]) == .queued)
        #expect(provider.cancelledCount == 1)
    }

    @Test("Images leaving the window are evicted and their requests cancelled")
    func eviction() async {
        let provider = FakeImageProvider()
        let scheduler = ManualScheduler()
        let buffer = makeBuffer(provider, scheduler, configuration: .init(prefetchAhead: 1, keepBehind: 1))
        let items = ids(6)
        buffer.setWindow(needed: items[0], ahead: [items[1]], behind: [], onScreen: nil)
        await provider.succeed(items[0])
        await waitUntil { buffer.status(for: items[0]) == .ready }

        buffer.setWindow(needed: items[4], ahead: [items[5]], behind: [items[3]], onScreen: nil)
        #expect(buffer.status(for: items[0]) == .absent)
        #expect(buffer.status(for: items[1]) == .absent)
        await waitUntil { !provider.hasPending(items[1]) }
        #expect(buffer.bufferedIDs.isEmpty)
    }

    @Test("Memory pressure keeps only protected images")
    func memoryPressure() async {
        let provider = FakeImageProvider(autoComplete: true)
        let scheduler = ManualScheduler()
        let buffer = makeBuffer(provider, scheduler, configuration: .init(prefetchAhead: 3, keepBehind: 2))
        let items = ids(6)
        buffer.setWindow(needed: items[2], ahead: [items[3], items[4], items[5]], behind: [items[1], items[0]], onScreen: items[1])
        await waitUntil { buffer.currentStats.ready == 6 }
        buffer.handleMemoryPressure()
        #expect(buffer.bufferedIDs == [items[1], items[2]])
        #expect(buffer.configuration.prefetchAhead == 2)
    }

    @Test("Late results after reset are counted as stale and dropped")
    func staleAfterReset() async {
        let provider = FakeImageProvider()
        provider.honorsCancellation = false
        let scheduler = ManualScheduler()
        let buffer = makeBuffer(provider, scheduler, configuration: .init())
        let id = AssetID("x")
        buffer.setWindow(needed: id, ahead: [], behind: [], onScreen: nil)
        await waitUntil { provider.hasPending(id) }
        buffer.reset()
        provider.resolve(id, with: .success(provider.makeImage()), includeCancelled: true)
        await waitUntil { buffer.currentStats.staleCallbacks == 1 }
        #expect(buffer.status(for: id) == .absent)
    }

    @Test("Retry exhaustion ends in failed; an explicit retry starts fresh")
    func retryExhaustion() async {
        let provider = FakeImageProvider()
        let scheduler = ManualScheduler()
        let buffer = makeBuffer(provider, scheduler, configuration: .init(retryDelays: [.seconds(1), .seconds(3)]))
        let id = AssetID("x")
        buffer.setWindow(needed: id, ahead: [], behind: [], onScreen: nil)
        await provider.fail(id, networkError)
        await waitUntil { if case .waitingToRetry = buffer.status(for: id) { true } else { false } }
        scheduler.advance(by: .seconds(1))
        await provider.fail(id, networkError)
        await waitUntil { if case .waitingToRetry = buffer.status(for: id) { true } else { false } }
        scheduler.advance(by: .seconds(3))
        await provider.fail(id, networkError)
        await waitUntil { buffer.status(for: id) == .failed(networkError) }
        #expect(buffer.currentStats.retries == 2)

        scheduler.advance(by: .seconds(100))
        #expect(provider.requestCount(for: id) == 3, "no silent infinite retrying")

        buffer.retry(id)
        await provider.succeed(id)
        await waitUntil { buffer.status(for: id) == .ready }
        #expect(buffer.recentRequests.last?.outcome == .succeeded)
    }
}
