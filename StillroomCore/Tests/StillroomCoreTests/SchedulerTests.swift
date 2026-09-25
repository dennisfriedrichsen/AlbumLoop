import Foundation
import Synchronization
import Testing
@testable import StillroomCore

@Suite("ContinuousScheduler")
@MainActor
struct SchedulerTests {
    /// Regression test for the Apple TV HD freeze (2026-09-24): two hung Vision
    /// calls blocked both cooperative threads, and `Task.sleep`-based timers
    /// (slide timer, download watchdog) never fired again.
    @Test("Timers fire even while every cooperative thread is blocked")
    func timersSurvivePoolStarvation() async {
        let scheduler = ContinuousScheduler()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let started = Mutex(0)
        for _ in 0..<(cores + 2) {
            Task.detached {
                started.withLock { $0 += 1 }
                usleep(2_000_000) // Deliberately block a cooperative thread.
            }
        }
        // Wait (on the main thread) until the pool is saturated.
        let deadline = Date().addingTimeInterval(2)
        while started.withLock({ $0 }) < cores, Date() < deadline {
            usleep(1_000)
        }

        let clock = ContinuousClock()
        let begin = clock.now
        let firedAfter = Mutex<Duration?>(nil)
        await withCheckedContinuation { continuation in
            _ = scheduler.schedule(after: .milliseconds(100)) {
                // Measure when the timer fires; resuming this test task itself
                // goes through the (deliberately) blocked pool.
                firedAfter.withLock { $0 = clock.now - begin }
                continuation.resume()
            }
        }
        let elapsed = firedAfter.withLock { $0 } ?? .seconds(99)
        #expect(elapsed < .milliseconds(1_000), "timer fired after \(elapsed) with the cooperative pool blocked")
    }

    @Test("Cancelled work never runs")
    func cancellation() async {
        let scheduler = ContinuousScheduler()
        var fired = false
        let work = scheduler.schedule(after: .milliseconds(50)) { fired = true }
        work.cancel()
        await withCheckedContinuation { continuation in
            _ = scheduler.schedule(after: .milliseconds(150)) { continuation.resume() }
        }
        #expect(fired == false)
    }
}
