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

/// Production scheduler backed by `ContinuousClock` and `Task.sleep`.
@MainActor
public final class ContinuousScheduler: Scheduling {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public var now: Duration { clock.now - origin }

    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledWork {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            // Cancellation can land after the sleep finished but before this resumes.
            guard !Task.isCancelled else { return }
            action()
        }
        return ScheduledWork { task.cancel() }
    }
}
