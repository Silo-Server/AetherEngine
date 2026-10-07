import Foundation
import Testing
@testable import AetherEngine

/// Audit HLS-101: only the session's first live producer was wired to the provider, so a producer
/// that replaced a dead one (live reopen, the in-place muxerFailed rebuild, the AE#222 live rebuild)
/// cut segments into the cache that the playlist never listed. The playlist ended where the dead
/// producer stopped, and "live reopen succeeded" was logged over a frozen picture.
@Suite("A live playlist keeps growing after an in-engine recovery", .serialized)
struct LiveRecoveryPlaylistGrowthTests {

    private final class Observed: @unchecked Sendable {
        private let lock = NSLock()
        private weak var _engine: HLSVideoEngine?
        private var _countAtFirstReopen: Int?
        private var _sourceResets = 0

        func watch(_ engine: HLSVideoEngine) { lock.withLock { _engine = engine } }

        /// Runs inside the reopen, after the dead pump's own segments were reported.
        func noteReopen() {
            let engine = lock.withLock { _engine }
            let count = engine?.liveSegmentCountSnapshot
            lock.withLock { if _countAtFirstReopen == nil { _countAtFirstReopen = count } }
        }

        func noteSourceReset() { lock.withLock { _sourceResets += 1 } }

        var countAtFirstReopen: Int? { lock.withLock { _countAtFirstReopen } }
        var sourceResets: Int { lock.withLock { _sourceResets } }
    }

    private static func openLiveDemuxer() throws -> Demuxer {
        let dem = Demuxer()
        try dem.open(reader: TinyTransportStreamFixture.LiveReader(),
                     formatHint: "mpegts", isLive: true)
        return dem
    }

    @Test("segments a reopened live producer cuts reach the playlist", .timeLimit(.minutes(1)))
    func reopenedProducerGrowsThePlaylist() async throws {
        let observed = Observed()
        let engine = HLSVideoEngine(
            url: URL(string: "aether-custom://source")!,
            dvModeAvailable: false,
            isLiveSession: true,
            liveCutTargetSeconds: 1,
            preopenedDemuxer: try Self.openLiveDemuxer(),
            sourceReopenableByURL: false,
            customSourceReopenFactory: {
                observed.noteReopen()
                return (reader: TinyTransportStreamFixture.LiveReader(), formatHint: "mpegts")
            })
        observed.watch(engine)
        _ = try engine.start()
        defer { engine.stop() }

        // The reader ends after one pass, which is the source loss; the factory is the reconnect.
        try await waitFor { observed.countAtFirstReopen != nil }
        let beforeLoss = try #require(observed.countAtFirstReopen)
        #expect(beforeLoss > 0, "the first producer never reported a segment")

        try await waitFor { (engine.liveSegmentCountSnapshot ?? 0) > beforeLoss }
    }

    @Test("a producer rebuilt in place reports into the same playlist", .timeLimit(.minutes(1)))
    func rebuiltProducerReportsIntoThePlaylist() async throws {
        let observed = Observed()
        let engine = HLSVideoEngine(
            url: URL(string: "aether-custom://source")!,
            dvModeAvailable: false,
            isLiveSession: true,
            liveCutTargetSeconds: 1,
            preopenedDemuxer: try Self.openLiveDemuxer(),
            sourceReopenableByURL: false)
        engine.onLiveSourceReset = { observed.noteSourceReset() }
        _ = try engine.start()
        defer { engine.stop() }

        try await waitFor { observed.sourceResets > 0 }
        let failed = try #require(engine.producer)
        engine.rebuildLiveProducerInPlace(failed: failed)
        let rebuilt = try #require(engine.producer)
        #expect(rebuilt !== failed)
        #expect(rebuilt.liveResidentCapProvider != nil)

        let continuation = try #require(engine.provider?.liveContinuationPoint())
        let report = try #require(rebuilt.onLiveSegmentFinalized, "the rebuilt producer reports to nobody")
        report(continuation.nextIndex, 1.0, continuation.outputEndSeconds, true)
        #expect(engine.liveSegmentCountSnapshot == continuation.nextIndex + 1)
    }
}
