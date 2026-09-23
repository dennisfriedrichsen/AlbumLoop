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
public struct PlaybackSequence: Sendable {
    public enum Order: String, Sendable, CaseIterable {
        case sequential
        case shuffled
    }

    /// Result of moving forward one slide.
    public enum Step: Equatable, Sendable {
        /// Moved to the next slide in the current cycle.
        case advanced
        /// The cycle finished and a new cycle started at position 0.
        case wrapped(completedCycle: Int)
        /// The cycle finished and looping is off. Position is unchanged.
        case ended
    }

    public let items: [AssetID]
    public let order: Order
    public var loops: Bool

    /// 1-based cycle number.
    public private(set) var cycle = 1
    /// 0-based index into the current cycle's order.
    public private(set) var position = 0

    /// Permutation of `items` indices for the current cycle.
    private var cycleOrder: [Int]
    /// Pre-generated permutation for the next cycle, so upcoming slides can be
    /// prefetched across the loop boundary.
    private var nextCycleOrder: [Int]
    private var rng: SplitMix64

    public init(items: [AssetID], order: Order, loops: Bool, seed: UInt64) {
        precondition(!items.isEmpty, "A playback sequence needs at least one item")
        self.items = items
        self.order = order
        self.loops = loops
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
            nextCycleOrder = makeNextShuffledOrder()
        }
    }

    public var count: Int { items.count }
    public var currentID: AssetID { items[cycleOrder[position]] }
    public var isAtCycleStart: Bool { position == 0 }
    public var isAtCycleEnd: Bool { position == cycleOrder.count - 1 }

    /// The identifiers of the current cycle in playback order.
    public var currentCycleIDs: [AssetID] { cycleOrder.map { items[$0] } }

    /// Moves forward one slide, wrapping into a new cycle if looping.
    public mutating func advance() -> Step {
        if position < cycleOrder.count - 1 {
            position += 1
            return .advanced
        }
        guard loops else { return .ended }
        let completed = cycle
        cycle += 1
        position = 0
        cycleOrder = nextCycleOrder
        if order == .shuffled {
            nextCycleOrder = makeNextShuffledOrder()
        }
        return .wrapped(completedCycle: completed)
    }

    /// Moves back one slide within the current cycle. Returns false at the cycle start.
    public mutating func retreat() -> Bool {
        guard position > 0 else { return false }
        position -= 1
        return true
    }

    /// The next `limit` identifiers in playback order, continuing into the next
    /// cycle when looping. Never includes the current slide.
    public func upcoming(_ limit: Int) -> [AssetID] {
        guard limit > 0 else { return [] }
        var result: [AssetID] = []
        var index = position + 1
        while result.count < limit {
            if index < cycleOrder.count {
                result.append(items[cycleOrder[index]])
            } else if loops, index - cycleOrder.count < nextCycleOrder.count {
                result.append(items[nextCycleOrder[index - cycleOrder.count]])
            } else {
                break
            }
            // Never prefetch more than one full cycle ahead.
            if index - position >= count { break }
            index += 1
        }
        return result
    }

    /// Up to `limit` previously shown positions in this cycle, most recent first.
    public func recent(_ limit: Int) -> [AssetID] {
        guard limit > 0, position > 0 else { return [] }
        let lower = max(0, position - limit)
        return (lower..<position).reversed().map { items[cycleOrder[$0]] }
    }

    /// Replaces the item snapshot at a cycle boundary (for example after the
    /// album was edited). Keeps the cycle number and settings; starts at position 0.
    /// For shuffle, avoids repeating `lastShown` as the first slide when possible.
    public func rebuilt(with newItems: [AssetID], avoidingFirst lastShown: AssetID?) -> PlaybackSequence {
        var copy = PlaybackSequence(items: newItems, order: order, loops: loops, seed: rng.peekSeed)
        copy.cycle = cycle
        if order == .shuffled, let lastShown, copy.count > 1, copy.currentID == lastShown {
            copy.cycleOrder.swapAt(0, 1)
        }
        return copy
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
