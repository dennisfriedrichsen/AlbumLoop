import Foundation

/// Deterministic, seedable random number generator (SplitMix64) so shuffle
/// order is reproducible in tests.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// The complete, immutable-per-cycle playback order for one slideshow.
///
/// The sequence is a snapshot of every eligible asset identifier taken when
/// playback starts. It knows nothing about downloads: its length is the album
/// length, regardless of how many images happen to be loaded.
///
/// Playback moves in *slides*. A slide is normally one photo; when pairing is
/// enabled, two adjacent pairable photos (e.g. both vertical) share a slide.
/// Pairing is computed once per cycle from the cycle's photo order, so moving
/// back and forth always produces the same slides.
public struct PlaybackSequence: Sendable {
    public enum Order: String, Sendable, CaseIterable {
        case sequential
        case shuffled
    }

    /// Result of moving forward one slide.
    public enum Step: Equatable, Sendable {
        /// Moved to the next slide in the current cycle.
        case advanced
        /// The cycle finished and a new cycle started at the first slide.
        case wrapped(completedCycle: Int)
        /// The cycle finished and looping is off. Position is unchanged.
        case ended
    }

    public let items: [AssetID]
    public let order: Order
    public var loops: Bool
    /// Photos that may share a slide with an adjacent pairable photo.
    public let pairable: Set<AssetID>

    /// 1-based cycle number.
    public private(set) var cycle = 1
    /// 0-based index of the current slide within the cycle.
    public private(set) var slideIndex = 0

    /// Permutation of `items` indices for the current cycle.
    private var cycleOrder: [Int]
    /// Slides of the current cycle, as ranges of positions in `cycleOrder`.
    private var cycleSlides: [Range<Int>]
    /// Pre-generated order and slides for the next cycle, so upcoming photos
    /// can be prefetched across the loop boundary.
    private var nextCycleOrder: [Int]
    private var nextCycleSlides: [Range<Int>]
    private var rng: SplitMix64

    public init(items: [AssetID], order: Order, loops: Bool, seed: UInt64, pairable: Set<AssetID> = []) {
        precondition(!items.isEmpty, "A playback sequence needs at least one item")
        self.items = items
        self.order = order
        self.loops = loops
        self.pairable = pairable
        self.rng = SplitMix64(seed: seed)
        let identity = Array(items.indices)
        switch order {
        case .sequential:
            cycleOrder = identity
            nextCycleOrder = identity
        case .shuffled:
            var generator = rng
            let first = identity.shuffled(using: &generator)
            rng = generator
            cycleOrder = first
            nextCycleOrder = []
        }
        cycleSlides = []
        nextCycleSlides = []
        cycleSlides = makeSlides(for: cycleOrder)
        if order == .shuffled {
            nextCycleOrder = makeNextShuffledOrder()
        }
        nextCycleSlides = makeSlides(for: nextCycleOrder)
    }

    /// Number of photos (not slides) in the sequence.
    public var count: Int { items.count }
    /// Number of slides in the current cycle.
    public var slideCount: Int { cycleSlides.count }

    /// 0-based photo position (within the cycle) of the current slide's first photo.
    public var position: Int { cycleSlides[slideIndex].lowerBound }
    /// The photos on the current slide (one, or two when paired).
    public var currentIDs: [AssetID] { cycleSlides[slideIndex].map { items[cycleOrder[$0]] } }
    /// The first photo on the current slide.
    public var currentID: AssetID { currentIDs[0] }

    public var isAtCycleStart: Bool { slideIndex == 0 }
    public var isAtCycleEnd: Bool { slideIndex == cycleSlides.count - 1 }

    /// The identifiers of the current cycle in playback order.
    public var currentCycleIDs: [AssetID] { cycleOrder.map { items[$0] } }

    /// Moves forward one slide, wrapping into a new cycle if looping.
    public mutating func advance() -> Step {
        if slideIndex < cycleSlides.count - 1 {
            slideIndex += 1
            return .advanced
        }
        guard loops else { return .ended }
        let completed = cycle
        cycle += 1
        slideIndex = 0
        cycleOrder = nextCycleOrder
        cycleSlides = nextCycleSlides
        if order == .shuffled {
            nextCycleOrder = makeNextShuffledOrder()
            nextCycleSlides = makeSlides(for: nextCycleOrder)
        }
        return .wrapped(completedCycle: completed)
    }

    /// Moves back one slide within the current cycle. Returns false at the cycle start.
    public mutating func retreat() -> Bool {
        guard slideIndex > 0 else { return false }
        slideIndex -= 1
        return true
    }

    /// The next `limit` photo identifiers after the current slide, in playback
    /// order, continuing into the next cycle when looping.
    public func upcoming(_ limit: Int) -> [AssetID] {
        guard limit > 0 else { return [] }
        let last = cycleSlides[slideIndex].upperBound - 1
        var result: [AssetID] = []
        var index = last + 1
        while result.count < limit {
            if index < cycleOrder.count {
                result.append(items[cycleOrder[index]])
            } else if loops, index - cycleOrder.count < nextCycleOrder.count {
                result.append(items[nextCycleOrder[index - cycleOrder.count]])
            } else {
                break
            }
            // Never prefetch more than one full cycle ahead.
            if index - last >= count { break }
            index += 1
        }
        return result
    }

    /// Up to `limit` photos shown before the current slide in this cycle, most recent first.
    public func recent(_ limit: Int) -> [AssetID] {
        let first = cycleSlides[slideIndex].lowerBound
        guard limit > 0, first > 0 else { return [] }
        let lower = max(0, first - limit)
        return (lower..<first).reversed().map { items[cycleOrder[$0]] }
    }

    /// Replaces the item snapshot at a cycle boundary (for example after the
    /// album was edited). Keeps the cycle number and settings; starts at the first slide.
    /// For shuffle, avoids repeating `lastShown` as the first photo when possible.
    public func rebuilt(
        with newItems: [AssetID],
        pairable newPairable: Set<AssetID>,
        avoidingFirst lastShown: AssetID?
    ) -> PlaybackSequence {
        var copy = PlaybackSequence(
            items: newItems,
            order: order,
            loops: loops,
            seed: rng.peekSeed,
            pairable: newPairable
        )
        copy.cycle = cycle
        if order == .shuffled, let lastShown, copy.count > 1, copy.currentID == lastShown {
            copy.cycleOrder.swapAt(0, 1)
            copy.cycleSlides = copy.makeSlides(for: copy.cycleOrder)
        }
        return copy
    }

    /// Greedily groups adjacent pairable photos into two-photo slides.
    private func makeSlides(for order: [Int]) -> [Range<Int>] {
        var slides: [Range<Int>] = []
        slides.reserveCapacity(order.count)
        var index = 0
        while index < order.count {
            if !pairable.isEmpty, index + 1 < order.count,
               pairable.contains(items[order[index]]), pairable.contains(items[order[index + 1]]) {
                slides.append(index..<(index + 2))
                index += 2
            } else {
                slides.append(index..<(index + 1))
                index += 1
            }
        }
        return slides
    }

    private mutating func makeNextShuffledOrder() -> [Int] {
        var generator = rng
        var next = Array(items.indices).shuffled(using: &generator)
        // Avoid showing the same photo twice in a row across the cycle boundary.
        if next.count > 1, let last = cycleOrder.last, next[0] == last {
            let swapIndex = Int.random(in: 1..<next.count, using: &generator)
            next.swapAt(0, swapIndex)
        }
        rng = generator
        return next
    }
}

private extension SplitMix64 {
    /// Derives a seed for a rebuilt sequence without disturbing this generator.
    var peekSeed: UInt64 {
        var copy = self
        return copy.next()
    }
}
