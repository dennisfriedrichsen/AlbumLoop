import Foundation
import os

/// Local structured logging. Asset identifiers are logged only as short hashes,
/// image contents are never logged, and nothing leaves the device.
///
/// Messages go to the unified system log and, once `DiagnosticFileLog.shared`
/// is configured, to a small rotating file in the app's caches so problems
/// can be diagnosed after the fact (copy it off with `devicectl`).
public enum AlbumLoopLog {
    public static let subsystem = "com.dennisfriedrichsen.AlbumLoop"
    public static let library = AlbumLoopLogger(category: "library")
    public static let loading = AlbumLoopLogger(category: "loading")
    public static let playback = AlbumLoopLogger(category: "playback")
}

public struct AlbumLoopLogger: Sendable {
    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: AlbumLoopLog.subsystem, category: category)
    }

    /// Messages must contain only counts, timings, hashed asset tokens, and error text.
    public func debug(_ message: String) {
        logger.debug("\(message)")
    }

    public func info(_ message: String) {
        logger.info("\(message)")
        DiagnosticFileLog.shared.append("I", category, message)
    }

    public func notice(_ message: String) {
        logger.notice("\(message)")
        DiagnosticFileLog.shared.append("N", category, message)
    }

    public func error(_ message: String) {
        logger.error("\(message)")
        DiagnosticFileLog.shared.append("E", category, message)
    }
}

/// Bounded on-device log file: `albumloop.log`, rotated to `albumloop.1.log`
/// at `maxBytes`, so at most about twice that is ever stored.
public final class DiagnosticFileLog: @unchecked Sendable {
    public static let shared = DiagnosticFileLog()
    public static let fileName = "albumloop.log"

    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "AlbumLoop.DiagnosticFileLog")
    private var directory: URL?
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let maxBytes: UInt64 = 400_000
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Starts writing to `directory`. Until called, messages only go to the system log.
    public func configure(directory: URL) {
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            self.openFile()
        }
    }

    func append(_ level: String, _ category: String, _ message: String) {
        let date = Date()
        queue.async {
            guard let handle = self.handle else { return }
            let line = "\(self.formatter.string(from: date)) \(level) [\(category)] \(message)\n"
            let data = Data(line.utf8)
            try? handle.write(contentsOf: data)
            self.size += UInt64(data.count)
            if self.size > self.maxBytes {
                self.rotate()
            }
        }
    }

    private var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    private func openFile() {
        guard let url = fileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        guard let directory, let url = fileURL else { return }
        try? handle?.close()
        handle = nil
        let old = directory.appendingPathComponent("albumloop.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        openFile()
    }
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
