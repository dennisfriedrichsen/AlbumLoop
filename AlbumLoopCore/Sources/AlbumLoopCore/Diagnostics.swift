import Foundation
import os

/// Local structured logging. Asset identifiers are logged only as short hashes
/// and nothing leaves the device.
public enum AlbumLoopLog {
    public static let subsystem = "com.dennisfriedrichsen.AlbumLoop"
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let loading = Logger(subsystem: subsystem, category: "loading")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
}

/// Outcome of one image-request attempt, kept for the diagnostics overlay.
public struct RequestRecord: Sendable, Identifiable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case succeeded
        case failed(ImageLoadFailure)
        case cancelled
    }

    public let id: UInt64
    public let assetToken: String
    public let attempt: Int
    public let duration: Duration
    public let outcome: Outcome
}

/// Point-in-time counters from the image buffer.
public struct BufferStats: Sendable, Equatable {
    public var ready = 0
    public var loading = 0
    /// Queued or waiting for a retry backoff.
    public var pending = 0
    public var failed = 0
    public var decodedBytes = 0
    public var byteBudget = 0
    public var retries = 0
    public var staleCallbacks = 0
    public var completedRequests = 0
    public var failedRequests = 0

    public init() {}
}

/// Everything the diagnostics overlay shows about the active slideshow.
public struct PlaybackDiagnostics: Sendable, Equatable {
    public var sessionID = 0
    public var cycle = 1
    /// 1-based position of the slide playback is on.
    public var position = 0
    public var total = 0
    public var displayedThisCycle = 0
    public var skippedThisCycle = 0
    public var removedThisCycle = 0
    public var buffer = BufferStats()
    public var recentRequests: [RequestRecord] = []

    public init() {}
}

/// What happened during one full pass through the album.
public struct CycleReport: Sendable, Equatable {
    public var cycle: Int
    public var total: Int
    public var displayed: Int
    /// Photos the user explicitly skipped because they could not be loaded.
    public var skippedUnavailable: [AssetID]
    /// Photos that no longer exist in the library.
    public var removedFromLibrary: [AssetID]

    /// Photos never displayed this cycle for any other reason (e.g. manual navigation past them).
    public var notDisplayed: Int {
        max(0, total - displayed - skippedUnavailable.count - removedFromLibrary.count)
    }

    public var isComplete: Bool { displayed == total }

    /// Every photo in the cycle was skipped as unavailable or had been removed;
    /// nothing was shown and nothing was merely passed by navigation.
    public var nothingCouldLoad: Bool { displayed == 0 && notDisplayed == 0 }

    public var summary: String {
        var parts = ["Displayed \(displayed) of \(total) photos"]
        if !skippedUnavailable.isEmpty { parts.append("\(skippedUnavailable.count) skipped (couldn’t load)") }
        if !removedFromLibrary.isEmpty { parts.append("\(removedFromLibrary.count) no longer in library") }
        if notDisplayed > 0 { parts.append("\(notDisplayed) passed by navigation") }
        return parts.joined(separator: " · ")
    }
}
