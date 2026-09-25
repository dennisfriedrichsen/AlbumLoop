import Foundation

/// A cancellable handle for work scheduled with a `Scheduling` implementation.
@MainActor
public final class ScheduledWork {
    private var cancelHandler: (() -> Void)?
    public private(set) var isCancelled = false

    public init(cancel: @escaping () -> Void) {
        self.cancelHandler = cancel
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelHandler?()
        cancelHandler = nil
    }
}

/// Time source and timer factory. Injected so tests control time exactly.
@MainActor
public protocol Scheduling: AnyObject {
    /// Monotonic time since an arbitrary origin.
    var now: Duration { get }

    /// Runs `action` on the main actor after `delay` unless cancelled first.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledWork
}

/// Production scheduler: `ContinuousClock` for time, the main dispatch queue for timers.
///
/// Timers deliberately don't use `Task.sleep`: its wake-up goes through Swift's
/// cooperative thread pool, which is only two threads on an Apple TV HD. If
/// other work ever blocks those threads, slide timers and the download watchdog
/// must still fire so playback can recover.
@MainActor
public final class ContinuousScheduler: Scheduling {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public var now: Duration { clock.now - origin }

    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                action()
            }
        }
        let components = delay.components
        let nanoseconds = max(0, components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: item)
        return ScheduledWork { item.cancel() }
    }
}
