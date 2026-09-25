import Testing
@testable import StillroomCore

/// Test harness: a controller wired to a fake provider and a manual clock.
@MainActor
final class Harness {
    let scheduler = ManualScheduler()
    let provider: FakeImageProvider
    let controller: SlideshowController

    init(
        autoComplete: Bool = false,
        configuration: ImageBuffer.Configuration = ImageBuffer.Configuration(
            prefetchAhead: 3,
            keepBehind: 2,
            maxConcurrentLoads: 2,
            maxDecodedBytes: 100_000_000,
            retryDelays: [.seconds(2), .seconds(6)],
            // Long by default so tests that hold a download for minutes don't trip the watchdog.
            stallTimeout: .seconds(10_000),
            attemptTimeout: .seconds(20_000)
        ),
        seed: UInt64 = 5
    ) {
        provider = FakeImageProvider(autoComplete: autoComplete)
        controller = SlideshowController(
            provider: provider,
            scheduler: scheduler,
            targetPixelSize: PixelSize(width: 100, height: 100),
            bufferConfiguration: configuration,
            seedSource: { seed }
        )
    }

    func start(_ items: [AssetID], order: PlaybackSequence.Order = .sequential, loops: Bool = true) {
        controller.start(
            assetIDs: items,
            settings: SlideshowSettings(slideDuration: .seconds(8), order: order, loops: loops)
        )
    }

    func tick(_ seconds: Double) {
        scheduler.advance(by: .milliseconds(Int(seconds * 1000)))
    }

    /// Waits until `id` is on screen at 0-based `position`.
    func waitForShowing(_ id: AssetID, position: Int? = nil, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(sourceLocation: sourceLocation) {
            self.controller.phase == .showing && self.controller.displayed?.id == id
                && (position == nil || self.controller.displayed?.position == position)
        }
    }
}

@Suite("SlideshowController")
@MainActor
struct SlideshowControllerTests {
    // MARK: Complete playback

    @Test("An album larger than the buffer plays completely before repeating")
    func largeAlbumPlaysCompletely() async {
        let h = Harness(autoComplete: true)
        let items = ids(40)
        h.start(items)
        var shown: [AssetID] = []
        for step in 0..<41 {
            let expected = items[step % items.count]
            await h.waitForShowing(expected, position: step % items.count)
            shown.append(h.controller.displayed!.id)
            #expect(h.controller.total == 40)
            let stats = h.controller.imageBuffer!.currentStats
            #expect(stats.ready <= 1 + 3 + 2, "buffer held \(stats.ready) images at step \(step)")
            h.tick(8)
        }
        #expect(Array(shown.prefix(40)) == items)
        #expect(shown[40] == items[0])
        #expect(h.controller.cycle == 2)
        #expect(h.controller.lastCycleReport?.displayed == 40)
        #expect(h.controller.lastCycleReport?.isComplete == true)
    }

    @Test("Shuffle plays every photo exactly once per cycle")
    func shuffleCycle() async {
        let h = Harness(autoComplete: true, seed: 1234)
        let items = ids(25)
        h.start(items, order: .shuffled)
        let order = h.controller.currentCycleIDs
        #expect(order != items, "a 25-item shuffle should not be the identity")
        var shown: [AssetID] = []
        for step in 0..<25 {
            await h.waitForShowing(order[step], position: step)
            shown.append(h.controller.displayed!.id)
            h.tick(8)
        }
        #expect(Set(shown) == Set(items))
        #expect(shown.count == 25)
        await waitUntil { h.controller.cycle == 2 && h.controller.phase == .showing }
        #expect(h.controller.displayed?.id != shown.last, "no immediate repeat across the boundary")
    }

    @Test("Without looping playback finishes after the last photo")
    func finishesWithoutLoop() async {
        let h = Harness(autoComplete: true)
        let items = ids(3)
        h.start(items, loops: false)
        for step in 0..<3 {
            await h.waitForShowing(items[step], position: step)
            h.tick(8)
        }
        #expect(h.controller.phase == .finished)
        #expect(h.controller.displayed?.id == items[2])
        #expect(h.controller.lastCycleReport?.isComplete == true)
        h.tick(100)
        #expect(h.controller.phase == .finished)
        #expect(h.controller.wantsDisplayAwake == false)
    }

    // MARK: Delays and ordering

    @Test("A delayed download holds the current photo without resetting or truncating")
    func delayedDownloadHolds() async {
        let h = Harness()
        let items = ids(20)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0], position: 0)

        h.tick(8)
        #expect(h.controller.phase == .loading)
        #expect(h.controller.displayed?.id == items[0], "current photo stays on screen")
        #expect(h.controller.targetPosition == 1)

        h.tick(300)
        await settle()
        #expect(h.controller.phase == .loading)
        #expect(h.controller.targetPosition == 1)
        #expect(h.controller.total == 20)
        #expect(h.controller.wantsDisplayAwake)

        await h.provider.succeed(items[1])
        await h.waitForShowing(items[1], position: 1)

        // The slide timer starts when the photo is displayed, not when it was due.
        h.tick(7.9)
        #expect(h.controller.targetPosition == 1)
        h.tick(0.1)
        #expect(h.controller.targetPosition == 2)
    }

    @Test("Out-of-order completion does not reorder playback")
    func outOfOrderCompletion() async {
        let h = Harness()
        let items = ids(6)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])

        await waitUntil { Set(h.provider.pendingIDs) == [items[1], items[2]] }
        await h.provider.succeed(items[2])
        await waitUntil { h.controller.imageBuffer?.status(for: items[2]) == .ready }
        #expect(h.controller.displayed?.id == items[0])
        await h.provider.succeed(items[3])
        await h.provider.succeed(items[1])
        await waitUntil { h.controller.imageBuffer?.status(for: items[1]) == .ready }

        var shown = [h.controller.displayed!.id]
        for step in 1...3 {
            h.tick(8)
            await h.waitForShowing(items[step], position: step)
            shown.append(h.controller.displayed!.id)
        }
        #expect(shown == Array(items.prefix(4)))
    }

    // MARK: Pause and navigation

    @Test("Pause stops advancement but prefetching continues")
    func pauseKeepsPrefetching() async {
        let h = Harness()
        let items = ids(5)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])

        h.tick(3)
        h.controller.pause()
        #expect(h.controller.wantsDisplayAwake == false)
        h.tick(500)
        #expect(h.controller.targetPosition == 0)

        await h.provider.succeed(items[1])
        await waitUntil { h.controller.imageBuffer?.status(for: items[1]) == .ready }
        #expect(h.controller.displayed?.id == items[0])

        h.controller.resume()
        h.tick(4.9)
        #expect(h.controller.targetPosition == 0, "resumes with the remaining 5 s")
        h.tick(0.1)
        await h.waitForShowing(items[1], position: 1)
    }

    @Test("Manual navigation while loading is predictable")
    func navigationDuringLoading() async {
        let h = Harness()
        let items = ids(8)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])

        h.controller.next()
        h.controller.next()
        #expect(h.controller.targetPosition == 2)
        #expect(h.controller.phase == .loading)
        #expect(h.controller.displayed?.id == items[0])

        // Photo 1 finishing late must not jump the display backwards.
        await h.provider.succeed(items[1])
        await waitUntil { h.controller.imageBuffer?.status(for: items[1]) == .ready }
        #expect(h.controller.displayed?.id == items[0])
        #expect(h.controller.targetPosition == 2)

        await h.provider.succeed(items[2])
        await h.waitForShowing(items[2], position: 2)

        h.controller.previous()
        await h.waitForShowing(items[1], position: 1)
        h.controller.previous()
        #expect(h.controller.targetPosition == 0)
        h.controller.previous()
        #expect(h.controller.targetPosition == 0, "previous stops at the start of the cycle")
    }

    @Test("Manual navigation while paused stays paused")
    func navigationWhilePaused() async {
        let h = Harness(autoComplete: true)
        let items = ids(4)
        h.start(items)
        await h.waitForShowing(items[0])
        h.controller.pause()
        h.controller.next()
        await h.waitForShowing(items[1], position: 1)
        h.tick(60)
        #expect(h.controller.targetPosition == 1)
        #expect(h.controller.isPaused)
    }

    // MARK: Failures

    @Test("Retries back off, then stall with the current photo held; Retry recovers")
    func retriesThenStall() async {
        let h = Harness()
        let items = ids(5)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        h.tick(8)

        await h.provider.fail(items[1], networkError)
        await waitUntil { h.controller.isRetryingTarget }
        h.tick(2)
        await h.provider.fail(items[1], networkError)
        await waitUntil { h.controller.isRetryingTarget }
        h.tick(6)
        await h.provider.fail(items[1], networkError)
        await waitUntil { h.controller.phase == .stalled(networkError) }

        #expect(h.provider.requestCount(for: items[1]) == 3)
        #expect(h.controller.displayed?.id == items[0], "stall holds the current photo")
        #expect(h.controller.targetPosition == 1, "a failure never resets playback")
        h.tick(120)
        #expect(h.controller.targetPosition == 1, "no automatic advance while stalled")

        h.controller.retryCurrent()
        #expect(h.controller.phase == .loading)
        await h.provider.succeed(items[1])
        await h.waitForShowing(items[1], position: 1)
    }

    @Test("Explicit skips are recorded and reported at the end of the cycle")
    func explicitSkipReported() async {
        let h = Harness(configuration: ImageBuffer.Configuration(retryDelays: [], stallTimeout: .seconds(10_000)))
        let items = ids(3)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        h.tick(8)
        await h.provider.fail(items[1], networkError)
        await waitUntil { h.controller.phase == .stalled(networkError) }

        h.controller.skipCurrent()
        #expect(h.controller.targetPosition == 2, "skip moves forward, never back to the start")
        await h.provider.succeed(items[2])
        await h.waitForShowing(items[2], position: 2)
        h.tick(8)

        let report = h.controller.lastCycleReport
        #expect(report?.displayed == 2)
        #expect(report?.skippedUnavailable == [items[1]])
        #expect(report?.isComplete == false)
        #expect(h.controller.cycle == 2)
        #expect(h.controller.targetPosition == 0)
    }

    @Test("Deleted photos are skipped automatically and reported as removed")
    func deletedAssetSkipped() async {
        let h = Harness()
        let items = ids(4)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        await h.provider.fail(items[1], ImageLoadFailure(.notFound, "gone"))
        await waitUntil { h.controller.imageBuffer?.status(for: items[1]) == .failed(ImageLoadFailure(.notFound, "gone")) }
        h.tick(8)
        #expect(h.controller.targetPosition == 2)
        #expect(h.provider.requestCount(for: items[1]) == 1, "not-found is not retried")
        #expect(h.controller.diagnostics.removedThisCycle == 1)
    }

    @Test("If nothing can load, playback fails with a message instead of looping")
    func nothingLoads() async {
        let h = Harness(configuration: ImageBuffer.Configuration(retryDelays: [], stallTimeout: .seconds(10_000)))
        let items = ids(2)
        h.start(items)
        await h.provider.fail(items[0], networkError)
        await waitUntil { h.controller.phase == .stalled(networkError) }
        #expect(h.controller.displayed == nil)
        h.controller.next() // Next while stalled is an explicit skip.
        await h.provider.fail(items[1], networkError)
        await waitUntil { h.controller.phase == .stalled(networkError) }
        h.controller.skipCurrent()
        guard case .failed = h.controller.phase else {
            Issue.record("Expected failed phase, got \(h.controller.phase)")
            return
        }
        #expect(h.controller.lastCycleReport?.skippedUnavailable == items)
    }

    @Test("A download with no progress is treated as stalled and retried")
    func stallWatchdog() async {
        let h = Harness(configuration: ImageBuffer.Configuration(
            retryDelays: [.seconds(1)],
            stallTimeout: .seconds(10),
            attemptTimeout: .seconds(1000)
        ))
        let items = ids(3)
        h.start(items)
        await waitUntil { h.provider.hasPending(items[0]) }
        h.tick(5)
        h.provider.sendProgress(items[0], 0.5)
        await waitUntil { h.controller.targetProgress == 0.5 }
        h.tick(9)
        #expect(h.provider.requestCount(for: items[0]) == 1, "progress postponed the stall")
        h.tick(1.5)
        await waitUntil { h.controller.isRetryingTarget }
        h.tick(1)
        await waitUntil { h.provider.requestCount(for: items[0]) == 2 }
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
    }

    @Test("Network recovery retries a stalled photo without losing position")
    func networkRecovery() async {
        let h = Harness(configuration: ImageBuffer.Configuration(retryDelays: [], stallTimeout: .seconds(10_000)))
        let items = ids(10)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        h.controller.next()
        h.controller.next()
        h.controller.next()
        h.controller.networkAvailabilityChanged(false)
        await h.provider.fail(items[3], networkError)
        await waitUntil { h.controller.phase == .stalled(networkError) }

        h.controller.networkAvailabilityChanged(true)
        #expect(h.controller.phase == .loading)
        await h.provider.succeed(items[3])
        await h.waitForShowing(items[3], position: 3)
    }

    @Test("A photo that failed while prefetching gets fresh retries when playback reaches it")
    func prefetchFailureRetriedOnArrival() async {
        let h = Harness(configuration: ImageBuffer.Configuration(retryDelays: [], stallTimeout: .seconds(10_000)))
        let items = ids(4)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        await h.provider.fail(items[1], networkError)
        await waitUntil { h.controller.imageBuffer?.status(for: items[1]) == .failed(networkError) }
        #expect(h.controller.phase == .showing, "a prefetch failure doesn't interrupt the current slide")

        h.tick(8)
        #expect(h.controller.phase == .loading, "not stalled on arrival")
        await h.provider.succeed(items[1])
        await h.waitForShowing(items[1], position: 1)
        #expect(h.provider.requestCount(for: items[1]) == 2)
    }

    @Test("Loading time and attempt number are reported while waiting, and reset on display")
    func loadingElapsedAndAttempt() async {
        let h = Harness()
        let items = ids(3)
        h.start(items)
        await waitUntil { h.provider.hasPending(items[0]) }
        #expect(h.controller.targetLoadingElapsed == .zero)
        #expect(h.controller.targetAttempt == 1)
        h.tick(5)
        #expect(h.controller.targetLoadingElapsed == .seconds(5))

        await h.provider.fail(items[0], networkError)
        await waitUntil { h.controller.isRetryingTarget }
        h.tick(2)
        await waitUntil { h.controller.targetAttempt == 2 && !h.controller.isRetryingTarget }
        #expect(h.controller.targetLoadingElapsed == .seconds(7), "elapsed keeps counting across retries")

        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        #expect(h.controller.targetLoadingElapsed == nil)
        #expect(h.controller.targetAttempt == 0)
    }

    // MARK: Stale callbacks

    @Test("Late callbacks from a previous session are ignored")
    func staleCallbackFromPreviousSession() async {
        let h = Harness()
        h.provider.honorsCancellation = false
        let albumA = ids(3, prefix: "a")
        // Album B shares a photo with album A.
        let albumB = [albumA[0], AssetID("b1"), AssetID("b2")]
        h.start(albumA)
        await waitUntil { h.provider.hasPending(albumA[0]) }

        h.start(albumB)
        await waitUntil { h.provider.requestCount(for: albumA[0]) == 2 }
        // Deliver the old session's result late.
        #expect(h.provider.resolve(albumA[0], with: .success(h.provider.makeImage()), includeCancelled: true))
        await settle()
        #expect(h.controller.displayed == nil, "an old session's result must not satisfy the new session")
        #expect(h.controller.phase == .loading)

        await h.provider.succeed(albumA[0])
        await h.waitForShowing(albumA[0], position: 0)
        #expect(h.controller.currentCycleIDs == albumB)
    }

    @Test("Late callbacks for photos navigated away from are ignored")
    func staleCallbackAfterNavigation() async {
        let h = Harness(configuration: ImageBuffer.Configuration(
            prefetchAhead: 1, keepBehind: 0, maxConcurrentLoads: 2, stallTimeout: .seconds(10_000)
        ))
        h.provider.honorsCancellation = false
        let items = ids(6)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        await waitUntil { h.provider.hasPending(items[1]) }

        h.controller.next()
        h.controller.next()
        h.controller.next()
        #expect(h.controller.targetPosition == 3)
        await waitUntil { h.controller.imageBuffer?.status(for: items[1]) == .absent }

        #expect(h.provider.resolve(items[1], with: .success(h.provider.makeImage()), includeCancelled: true))
        await waitUntil { (h.controller.imageBuffer?.currentStats.staleCallbacks ?? 0) >= 1 }
        #expect(h.controller.displayed?.id == items[0])
        #expect(h.controller.imageBuffer?.status(for: items[1]) == .absent)
        #expect(h.controller.targetPosition == 3)
    }

    // MARK: Album edits and lifecycle

    @Test("Album edits apply at the next cycle, never mid-cycle")
    func albumEditDeferred() async {
        let h = Harness(autoComplete: true)
        let items = ids(3)
        h.start(items)
        await h.waitForShowing(items[0])
        let edited = ids(5, prefix: "b")
        h.controller.albumContentsChanged(edited)
        #expect(h.controller.total == 3)
        #expect(h.controller.currentCycleIDs == items)

        for step in 1..<3 {
            h.tick(8)
            await h.waitForShowing(items[step], position: step)
        }
        h.tick(8)
        await h.waitForShowing(edited[0], position: 0)
        #expect(h.controller.total == 5)
        #expect(h.controller.cycle == 2)
    }

    @Test("Backgrounding pauses and cancels prefetching; foregrounding resumes")
    func backgroundLifecycle() async {
        let h = Harness()
        let items = ids(6)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        await waitUntil { h.provider.pendingIDs.count == 2 }

        h.controller.enterBackground()
        #expect(h.controller.isPaused)
        await waitUntil { h.provider.pendingIDs.isEmpty }
        h.tick(60)
        #expect(h.controller.targetPosition == 0)

        h.controller.enterForeground()
        #expect(h.controller.isPaused == false)
        await waitUntil { h.provider.pendingIDs.count == 2 }
    }

    @Test("Stopping cancels every outstanding request")
    func stopCancels() async {
        let h = Harness()
        let items = ids(6)
        h.start(items)
        await waitUntil { h.provider.pendingIDs.count == 2 }
        h.controller.stop()
        await waitUntil { h.provider.pendingIDs.isEmpty }
        #expect(h.controller.phase == .idle)
        #expect(h.scheduler.pendingCount == 0)
    }

    // MARK: Resume

    @Test("Resuming starts at the saved photo and counts earlier photos as shown")
    func resumeAtPhoto() async {
        let harness = Harness(autoComplete: true)
        let items = ids(5)
        harness.controller.start(
            assetIDs: items,
            settings: SlideshowSettings(slideDuration: .seconds(8), order: .sequential, loops: true),
            resumeAt: items[3]
        )
        await harness.waitForShowing(items[3], position: 3)
        harness.tick(8)
        await harness.waitForShowing(items[4], position: 4)
        harness.tick(8)
        await harness.waitForShowing(items[0], position: 0)
        #expect(harness.controller.lastCycleReport?.isComplete == true)
    }

    @Test("A saved seed reproduces the shuffle order")
    func resumeShuffleSeed() {
        let harness = Harness(seed: 77)
        let items = ids(30)
        harness.start(items, order: .shuffled)
        let order = harness.controller.currentCycleIDs
        #expect(harness.controller.seed == 77)

        let other = Harness(seed: 1)
        other.controller.start(
            assetIDs: items,
            settings: SlideshowSettings(order: .shuffled),
            resumeAt: order[10],
            seed: 77
        )
        #expect(other.controller.currentCycleIDs == order)
        #expect(other.controller.targetPosition == 10)
    }
}
