import Testing
@testable import AlbumLoopCore

@Suite("Side-by-side pairing")
struct PairingSequenceTests {
    @Test("Adjacent pairable photos share a slide; others stay single")
    func greedyPairs() {
        let items = ids(6)
        let pairable: Set<AssetID> = [items[1], items[2], items[3], items[5]]
        var sequence = PlaybackSequence(items: items, order: .sequential, loops: true, seed: 1, pairable: pairable)
        #expect(sequence.slideCount == 5)
        var slides = [sequence.currentIDs]
        var positions = [sequence.position]
        while case .advanced = sequence.advance() {
            slides.append(sequence.currentIDs)
            positions.append(sequence.position)
        }
        #expect(slides == [[items[0]], [items[1], items[2]], [items[3]], [items[4]], [items[5]]])
        #expect(positions == [0, 1, 3, 4, 5])
    }

    @Test("Going back produces the same slides")
    func stableBackNavigation() {
        let items = ids(8)
        var sequence = PlaybackSequence(items: items, order: .shuffled, loops: true, seed: 3, pairable: Set(items))
        var forward = [sequence.currentIDs]
        while !sequence.isAtCycleEnd {
            _ = sequence.advance()
            forward.append(sequence.currentIDs)
        }
        var backward = [sequence.currentIDs]
        while sequence.retreat() {
            backward.append(sequence.currentIDs)
        }
        #expect(backward == forward.reversed())
        #expect(forward.allSatisfy { $0.count == 2 })
    }

    @Test("Paired shuffle still shows every photo exactly once per cycle", arguments: [1, 7, 99] as [UInt64])
    func pairedShuffleIsPermutation(seed: UInt64) {
        let items = ids(31)
        let pairable = Set(items.enumerated().filter { $0.offset % 3 != 0 }.map(\.element))
        var sequence = PlaybackSequence(items: items, order: .shuffled, loops: true, seed: seed, pairable: pairable)
        for _ in 1...3 {
            var seen = sequence.currentIDs
            while case .advanced = sequence.advance() {
                seen += sequence.currentIDs
            }
            #expect(seen.count == items.count)
            #expect(Set(seen) == Set(items))
        }
    }

    @Test("Prefetch windows are measured in photos around the whole slide")
    func windowsAroundPair() {
        let items = ids(6)
        var sequence = PlaybackSequence(items: items, order: .sequential, loops: false, seed: 1, pairable: [items[2], items[3]])
        _ = sequence.advance()
        _ = sequence.advance()
        #expect(sequence.currentIDs == [items[2], items[3]])
        #expect(sequence.upcoming(2) == [items[4], items[5]])
        #expect(sequence.recent(2) == [items[1], items[0]])
    }
}

@Suite("Side-by-side pairing in playback")
@MainActor
struct PairingPlaybackTests {
    @Test("A pair appears only when both photos are ready, and the counter covers both")
    func pairWaitsForBoth() async {
        let h = Harness()
        let items = ids(5)
        h.controller.start(
            assetIDs: items,
            pairable: [items[1], items[2]],
            settings: SlideshowSettings(slideDuration: .seconds(8))
        )
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        h.tick(8)
        #expect(h.controller.targetPosition == 1)
        #expect(h.controller.targetSlideSize == 2)

        await h.provider.succeed(items[2])
        await waitUntil { h.controller.imageBuffer?.status(for: items[2]) == .ready }
        #expect(h.controller.phase == .loading, "half a pair is not shown")
        #expect(h.controller.displayed?.id == items[0])

        await h.provider.succeed(items[1])
        await waitUntil { h.controller.displayed?.ids == [items[1], items[2]] }
        #expect(h.controller.phase == .showing)

        await h.provider.succeed(items[3])
        h.tick(8)
        await h.waitForShowing(items[3], position: 3)
        #expect(h.controller.targetSlideSize == 1)

        h.controller.previous()
        await waitUntil { h.controller.displayed?.ids == [items[1], items[2]] }
        #expect(h.controller.targetPosition == 1)
    }

    @Test("If one photo of a pair fails, Skip shows the other alone and records the skip")
    func skipHalfOfPair() async {
        let h = Harness(configuration: ImageBuffer.Configuration(retryDelays: [], stallTimeout: .seconds(10_000)))
        let items = ids(3)
        h.controller.start(
            assetIDs: items,
            pairable: [items[0], items[1]],
            settings: SlideshowSettings(slideDuration: .seconds(8))
        )
        await h.provider.succeed(items[0])
        await h.provider.fail(items[1], networkError)
        await waitUntil { h.controller.phase == .stalled(networkError) }
        #expect(h.controller.displayed == nil)

        h.controller.skipCurrent()
        await waitUntil { h.controller.displayed?.ids == [items[0]] }
        #expect(h.controller.phase == .showing)

        await h.provider.succeed(items[2])
        h.tick(8)
        await h.waitForShowing(items[2], position: 2)
        h.tick(8)
        let report = h.controller.lastCycleReport
        #expect(report?.displayed == 2)
        #expect(report?.skippedUnavailable == [items[1]])
    }

    @Test("Slide elapsed time drives panning: runs while showing, freezes on pause, holds at the end")
    func slideElapsed() async {
        let h = Harness()
        let items = ids(3)
        h.start(items)
        await h.provider.succeed(items[0])
        await h.waitForShowing(items[0])
        #expect(h.controller.slideElapsed == .zero)
        h.tick(3)
        #expect(h.controller.slideElapsed == .seconds(3))
        h.controller.pause()
        h.tick(100)
        #expect(h.controller.slideElapsed == .seconds(3))
        h.controller.resume()
        h.tick(2)
        #expect(h.controller.slideElapsed == .seconds(5))
        h.tick(3)
        #expect(h.controller.phase == .loading)
        #expect(h.controller.slideElapsed == .seconds(8), "holds the end position while the next slide loads")
    }
}
