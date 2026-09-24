import Testing
@testable import AlbumLoopCore

@Suite("PlaybackSequence")
struct PlaybackSequenceTests {
    @Test("Sequential order follows the snapshot and loops only after the full album")
    func sequentialFullCycle() {
        let items = ids(600)
        var sequence = PlaybackSequence(items: items, order: .sequential, loops: true, seed: 1)
        var played = [sequence.currentID]
        for _ in 1..<600 {
            #expect(sequence.advance() == .advanced)
            played.append(sequence.currentID)
        }
        #expect(played == items)
        #expect(sequence.advance() == .wrapped(completedCycle: 1))
        #expect(sequence.currentID == items[0])
        #expect(sequence.cycle == 2)
    }

    @Test("Without looping the sequence ends and keeps its position")
    func endsWithoutLoop() {
        var sequence = PlaybackSequence(items: ids(3), order: .sequential, loops: false, seed: 1)
        _ = sequence.advance()
        _ = sequence.advance()
        #expect(sequence.advance() == .ended)
        #expect(sequence.position == 2)
        #expect(sequence.upcoming(5).isEmpty)
    }

    @Test("Shuffle never repeats a photo within a cycle", arguments: [1, 2, 3, 42, 999] as [UInt64])
    func shuffleIsPermutation(seed: UInt64) {
        let items = ids(250)
        var sequence = PlaybackSequence(items: items, order: .shuffled, loops: true, seed: seed)
        for cycle in 1...3 {
            var seen: [AssetID] = [sequence.currentID]
            while case .advanced = sequence.advance() {
                seen.append(sequence.currentID)
            }
            #expect(seen.count == items.count, "cycle \(cycle)")
            #expect(Set(seen) == Set(items), "cycle \(cycle)")
        }
    }

    @Test("Shuffle avoids an immediate repeat across the cycle boundary")
    func shuffleBoundary() {
        for seed in UInt64(0)..<300 {
            var sequence = PlaybackSequence(items: ids(4), order: .shuffled, loops: true, seed: seed)
            for _ in 0..<5 {
                while !sequence.isAtCycleEnd { _ = sequence.advance() }
                let last = sequence.currentID
                _ = sequence.advance()
                #expect(sequence.currentID != last, "seed \(seed)")
            }
        }
    }

    @Test("Shuffle keeps navigable history for the current cycle")
    func shuffleHistory() {
        var sequence = PlaybackSequence(items: ids(30), order: .shuffled, loops: true, seed: 7)
        var forward: [AssetID] = [sequence.currentID]
        for _ in 0..<10 {
            _ = sequence.advance()
            forward.append(sequence.currentID)
        }
        var backward: [AssetID] = [sequence.currentID]
        while sequence.retreat() {
            backward.append(sequence.currentID)
        }
        #expect(backward == forward.reversed())
        #expect(sequence.retreat() == false)
    }

    @Test("Upcoming items continue into the next cycle and match what actually plays")
    func upcomingAcrossBoundary() {
        var sequence = PlaybackSequence(items: ids(5), order: .shuffled, loops: true, seed: 11)
        while !sequence.isAtCycleEnd { _ = sequence.advance() }
        let predicted = sequence.upcoming(3)
        #expect(predicted.count == 3)
        var actual: [AssetID] = []
        for _ in 0..<3 {
            _ = sequence.advance()
            actual.append(sequence.currentID)
        }
        #expect(predicted == actual)
    }

    @Test("Upcoming never looks more than one cycle ahead")
    func upcomingBounded() {
        let sequence = PlaybackSequence(items: ids(3), order: .sequential, loops: true, seed: 1)
        #expect(sequence.upcoming(10).count == 3)
        #expect(sequence.recent(5).isEmpty)
    }

    @Test("Rebuilding for an edited album keeps the cycle number")
    func rebuild() {
        var sequence = PlaybackSequence(items: ids(3), order: .sequential, loops: true, seed: 1)
        _ = sequence.advance(); _ = sequence.advance(); _ = sequence.advance()
        let rebuilt = sequence.rebuilt(with: ids(5, prefix: "b"), pairable: [], avoidingFirst: nil)
        #expect(rebuilt.cycle == 2)
        #expect(rebuilt.count == 5)
        #expect(rebuilt.position == 0)
    }
}
