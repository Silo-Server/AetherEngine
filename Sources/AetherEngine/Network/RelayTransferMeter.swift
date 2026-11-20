import Foundation

/// Silo fork: how long a relay's media bodies spent arriving, and what arrived, counted only while
/// bytes were arriving. `LiveTelemetry.relayMediaReceivedBytes` / `relayMediaReceivingMs` publish it.
///
/// On the native remote HLS route AVPlayer reads from the relay on 127.0.0.1, and its access log times
/// each request from when it was sent. An origin that produces a segment before it answers (an
/// encoder slower than real time, subtitle burn-in, a source read, a transcode node starting) holds
/// that request silent for seconds and then delivers the body at the link's full rate, so the access
/// log's `observedBitrate` reads the origin's work as a slow link. Here a body is timed from its first
/// byte to its last instead, on the relay's own URLSession, so the wait before the first byte never
/// counts.
///
/// A body that arrives in under `minimumReceivingMs` does not count, in bytes or in time: a short body
/// on a warm connection, such as one HLS segment, arrives at the connection's burst rate, which can be
/// twice what the link sustains. The bytes of a body's first chunk do not count either, because they
/// arrived before anything timed them. Time in which several bodies were arriving counts once. Both
/// rules match Silo Android's `PlaybackThroughputMeter`, so the two clients report the same quantity.
/// A pause inside a body does count, which keeps the rate a lower bound.
final class RelayTransferMeter: @unchecked Sendable {
    struct Totals: Equatable, Sendable {
        var bytes: Int64 = 0
        var receivingMs: Int64 = 0
    }

    /// A body that receives for less than this does not count.
    static let minimumReceivingMs: Int64 = 1_000

    /// One body being received. Its fields are the meter's, read and written under its lock.
    final class Transfer {
        fileprivate var firstMs: Int64?
        fileprivate var lastMs: Int64 = 0
        /// Bytes after the first chunk.
        fileprivate var bytes: Int64 = 0
        /// How far this body is already counted, once it is.
        fileprivate var countedThroughMs: Int64?
        fileprivate var countedBytes: Int64 = 0
    }

    private let clock: @Sendable () -> Int64
    private let lock = NSLock()
    private var counted = Totals()
    /// The spans already counted, merged, oldest first. Only recent ones can overlap a new span, so
    /// the list is trimmed to `coverageMemoryMs` behind the latest end.
    private var covered: [(start: Int64, end: Int64)] = []
    private static let coverageMemoryMs: Int64 = 600_000

    init(clock: @escaping @Sendable () -> Int64 = RelayTransferMeter.uptimeMs) {
        self.clock = clock
    }

    static func uptimeMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    func begin() -> Transfer { Transfer() }

    /// Whether a response's body is media the player plays from, and so timed. A playlist is not, by
    /// the same test the relay rewrites it by (a long VOD playlist can be served as `audio/mpegurl`).
    /// A subtitle rendition is not either: a server extracting a track streams it for as long as the
    /// extract takes, so its arrival says how fast the server works, not how fast the link is.
    static func timesBody(url: URL, status: Int, contentType: String?) -> Bool {
        guard (200..<300).contains(status),
              !HLSOriginRelay.looksLikePlaylist(url: url, contentType: contentType)
        else { return false }
        let path = url.path.lowercased()
        if subtitleSuffixes.contains(where: { path.hasSuffix($0) }) { return false }
        let type = (contentType ?? "application/octet-stream")
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return type.hasPrefix("video/") || type.hasPrefix("audio/")
            || type == "application/mp4" || type == "application/octet-stream"
    }

    private static let subtitleSuffixes = [".vtt", ".webvtt", ".srt", ".ttml"]

    /// `bytes` of a body arrived now. Called on the session's delegate queue as each chunk lands.
    func received(_ bytes: Int, on transfer: Transfer) {
        guard bytes > 0 else { return }
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        guard let first = transfer.firstMs else {
            transfer.firstMs = now
            transfer.lastMs = now
            return
        }
        transfer.bytes += Int64(bytes)
        transfer.lastMs = max(transfer.lastMs, now)
        guard transfer.lastMs - first >= Self.minimumReceivingMs else { return }
        let from = transfer.countedThroughMs ?? first
        counted.receivingMs += cover(from: from, to: transfer.lastMs)
        counted.bytes += transfer.bytes - transfer.countedBytes
        transfer.countedThroughMs = transfer.lastMs
        transfer.countedBytes = transfer.bytes
    }

    /// Everything counted so far on this relay.
    var totals: Totals {
        lock.lock()
        defer { lock.unlock() }
        return counted
    }

    /// Adds `start...end` to the covered spans and returns how much of it was not covered yet.
    private func cover(from start: Int64, to end: Int64) -> Int64 {
        guard end > start else { return 0 }
        var added = end - start
        var merged = (start: start, end: end)
        var kept: [(start: Int64, end: Int64)] = []
        kept.reserveCapacity(covered.count + 1)
        for span in covered {
            if span.end < merged.start || span.start > merged.end {
                kept.append(span)
                continue
            }
            added -= min(span.end, end) - max(span.start, start)
            merged = (min(merged.start, span.start), max(merged.end, span.end))
        }
        kept.append(merged)
        kept.sort { $0.start < $1.start }
        let horizon = (kept.last?.end ?? end) - Self.coverageMemoryMs
        covered = kept.filter { $0.end >= horizon }
        return max(0, added)
    }
}
