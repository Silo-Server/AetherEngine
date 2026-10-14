import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// A drain behind the playhead decodes through `subtitleDrainUrgentLeadSeconds` in one tick.
///
/// Reported from a Silo user's typeset anime: after a seek or a resume, signs stayed missing for the
/// rest of a passage. Tracked typesetting re-times every sign on every frame, 430 to 620 events a
/// second in the reproduction fixture, and the steady cap of 256 packets per 0.5 s tick decodes 512
/// a second. A reset starts 15 s behind the landing, so the drain needed 25 ticks to reach the
/// playhead, and in a passage denser than its throughput it never did (`decodedThrough=52.09` with
/// the playhead near 58, 30 s after a resume at 28.3).
struct SubtitleDrainCatchUpTests {

    // MARK: - Tick cap

    @Test("a window that starts past the urgent horizon keeps the steady cap")
    func steadyCapPastTheHorizon() {
        let pts = (0..<1_000).map { 100 + Double($0) / 100 }
        #expect(SubtitleOverlayDrainer.tickCap(count: pts.count, cap: 256, urgentThrough: 99,
                                               catchUpCap: 16_384) { pts[$0] } == 256)
    }

    @Test("a window behind the horizon takes every packet due by it")
    func catchUpTakesEverythingDue() {
        let pts = (0..<5_000).map { Double($0) / 100 }   // 0 ..< 50 s, 100 a second
        #expect(SubtitleOverlayDrainer.tickCap(count: pts.count, cap: 256, urgentThrough: 30,
                                               catchUpCap: 16_384) { pts[$0] } == 3_001)
        #expect(SubtitleOverlayDrainer.tickCap(count: pts.count, cap: 256, urgentThrough: 30,
                                               catchUpCap: 2_000) { pts[$0] } == 2_000,
                "the catch-up cap bounds one tick")
        #expect(SubtitleOverlayDrainer.tickCap(count: pts.count, cap: 4_000, urgentThrough: 30,
                                               catchUpCap: 16_384) { pts[$0] } == 4_000,
                "a steady cap above the urgent count stands")
    }

    @Test("bitmap and teletext tracks keep the steady cap")
    func bitmapAndTeletextKeepTheSteadyCap() {
        let pts = (0..<5_000).map { Double($0) / 100 }
        #expect(SubtitleOverlayDrainer.tickCap(count: pts.count, cap: 256, urgentThrough: 30,
                                               catchUpCap: 16_384, catchesUp: false) { pts[$0] } == 256)
        #expect(EmbeddedSubtitleDecoder.drainCatchesUp(AV_CODEC_ID_ASS))
        #expect(EmbeddedSubtitleDecoder.drainCatchesUp(AV_CODEC_ID_SUBRIP))
        #expect(!EmbeddedSubtitleDecoder.drainCatchesUp(AV_CODEC_ID_HDMV_PGS_SUBTITLE))
        #expect(!EmbeddedSubtitleDecoder.drainCatchesUp(AV_CODEC_ID_DVB_TELETEXT))
    }

    @Test("a non-positive cap still disables bounding")
    func nonPositiveCapPassesThrough() {
        #expect(SubtitleOverlayDrainer.tickCap(count: 3, cap: 0, urgentThrough: 10,
                                               catchUpCap: 16_384) { Double($0) } == 0)
    }

    // MARK: - Batched insert

    @Test("a batch merge leaves exactly what one insertCueSorted per cue would",
          arguments: [UInt64(1), 7, 271, 4_096, 65_537])
    func batchMatchesPerCueInsert(seed: UInt64) {
        var random = SplitMix(seed: seed)
        func randomCue() -> SubtitleCue {
            // Few starts and few texts, so re-decodes and shared starts are common. A rich-text cue
            // flattens to the same text as a plain one, which is what dedupe compares.
            let start = Double(random.next() % 40) / 4
            let text = "line \(random.next() % 6)"
            let body: SubtitleCue.Body = random.next() % 3 == 0
                ? .richText([SubtitleTextRun(text: text, color: nil, isItalic: true)])
                : .text(text)
            return SubtitleCue(id: -1, startTime: start, endTime: start + 1, body: body)
        }
        func kind(_ cue: SubtitleCue) -> String {
            if case .richText = cue.body { return "rich" }
            return "plain"
        }
        var nextID = 0
        var retained: [SubtitleCue] = []
        for _ in 0..<60 { AetherEngine.insertCueSorted(randomCue(), into: &retained, nextID: &nextID) }

        let incoming = (0..<200).map { _ in randomCue() }
        var sequential = retained
        var sequentialID = nextID
        let sequentialTaken = incoming.map {
            AetherEngine.insertCueSorted($0, into: &sequential, nextID: &sequentialID)
        }

        var batched = retained
        var batchedID = nextID
        var batch = SubtitleCueInsertBatch()
        let batchedTaken = incoming.map { batch.add($0, existing: batched, nextID: &batchedID) }
        batch.merge(into: &batched)

        #expect(batchedTaken == sequentialTaken)
        #expect(batchedID == sequentialID)
        #expect(batched.map(\.id) == sequential.map(\.id))
        #expect(batched.map(\.startTime) == sequential.map(\.startTime))
        #expect(batched.map(\.text) == sequential.map(\.text))
        #expect(batched.map(kind) == sequential.map(kind), "each cue keeps its own body")
    }

    @Test("bitmap cues and trimming events stay on the per-cue path")
    func onlyPlainTextEventsBatch() {
        let text = SubtitleCue(id: 0, startTime: 1, endTime: 2, body: .text("a"))
        #expect(SubtitleCueInsertBatch.accepts(.init(cues: [text], isPGS: false, pgsTrimAt: nil)))
        #expect(!SubtitleCueInsertBatch.accepts(.init(cues: [text], isPGS: true, pgsTrimAt: nil)))
        #expect(!SubtitleCueInsertBatch.accepts(.init(cues: [], isPGS: false, pgsTrimAt: 1)))
        var teletext = EmbeddedSubtitleDecoder.SubtitleEvent(cues: [text], isPGS: false, pgsTrimAt: nil)
        teletext.textTrimAt = 1
        #expect(!SubtitleCueInsertBatch.accepts(teletext))
    }

    // MARK: - Drain tick

    /// The #587 fixture's SubRip stream, used as the decoder for packets this test stores itself.
    private static let subripStreamIndex: Int32 = 1

    @MainActor
    private func engineWithDenseText(through seconds: Double, perSecond: Int, playhead: Double)
        throws -> (AetherEngine, Demuxer) {
        let data = try #require(Data(base64Encoded: Issue587PreserveASSMarkupCodecGateTests.base64.joined()))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        let store = SubtitlePacketStore()
        let interval = 1 / Double(perSecond)
        for index in 0..<Int(seconds * Double(perSecond)) {
            store.append(streamIndex: Self.subripStreamIndex, ptsSeconds: Double(index) * interval,
                         durationSeconds: 1.0 / 24, payload: Data("sign \(index)".utf8))
        }
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = store
        engine.isSubtitleActive = true
        engine.subtitleDrainTargets[.primary] = Self.subripStreamIndex
        engine.subtitleDrainDecoderFactoryForTesting = { index in
            guard let stream = demuxer.stream(at: index) else { return nil }
            return EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 16, sourceVideoHeight: 16)
        }
        engine.clock.sourceTime = playhead
        return (engine, demuxer)
    }

    @MainActor
    @Test("a resume into a dense passage publishes the landing's cues in its first tick")
    func resumeIntoDensePassageCatchesUpAtOnce() throws {
        // 600 events a second, landing at 30 s: backscan from 15 s plus the urgent lead is about
        // 16 200 packets, within one catch-up tick.
        let (engine, demuxer) = try engineWithDenseText(through: 60, perSecond: 600, playhead: 30)
        defer { demuxer.close() }

        engine.subtitleDrainTick()

        let cues = engine.subtitleCues
        #expect(cues.contains { $0.startTime <= 30 && 30 < $0.endTime }, "the line on screen at the landing")
        let newest = try #require(cues.map(\.startTime).max())
        #expect(newest >= 30 + AetherEngine.subtitleDrainUrgentLeadSeconds - 0.01,
                "decoded through the urgent horizon, not 256 packets into the backscan")
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.startTime <= $1.startTime })
    }

    @MainActor
    @Test("a drain ahead of the urgent horizon still decodes the steady cap per tick")
    func aheadOfTheHorizonKeepsTheSteadyCap() throws {
        let (engine, demuxer) = try engineWithDenseText(through: 90, perSecond: 600, playhead: 0)
        defer { demuxer.close() }

        engine.subtitleDrainTick()   // catch-up: through 12 s
        let caughtUp = engine.subtitleCues.count
        #expect(caughtUp >= Int(AetherEngine.subtitleDrainUrgentLeadSeconds * 600))
        engine.subtitleDrainTick()   // steady: the cursor is past the horizon
        #expect(engine.subtitleCues.count - caughtUp <= AetherEngine.subtitleDrainMaxPacketsPerTick)
    }

    @MainActor
    @Test("a prefetch ahead of the pump does not pin the drain at the pump's edge")
    func prefetchAheadOfThePumpIsNotAHole() throws {
        // The prefetch stores the whole minute first; the pump re-reads the first 4.38 s behind it,
        // and those duplicates take fresh sequences. Without coverage the seam reads as a #362 hole.
        func drainedThrough(recordsCoverage: Bool) throws -> Double {
            let (engine, demuxer) = try engineWithDenseText(through: 60, perSecond: 100, playhead: 0.36)
            defer { demuxer.close() }
            let store = try #require(engine.softwareSubtitlePacketStore)
            for index in 0...438 {
                store.append(streamIndex: Self.subripStreamIndex, ptsSeconds: Double(index) * (1 / 100.0),
                             durationSeconds: 1.0 / 24, payload: Data("sign \(index)".utf8))
            }
            if recordsCoverage {
                store.notePrefetchRead(from: 0, through: 60)
                store.noteHarvestAnchor(.pump, at: 0)
                store.noteHarvestReach(.pump, through: 4.38)
            }
            engine.subtitleDrainTick()
            return engine.subtitleCues.map(\.startTime).max() ?? -1
        }
        #expect(try drainedThrough(recordsCoverage: false) <= 4.38, "unproven ground still holds")
        #expect(try drainedThrough(recordsCoverage: true)
                >= 0.36 + AetherEngine.subtitleDrainUrgentLeadSeconds - 0.01)
    }

    @MainActor
    @Test("a hold set on unproven ground releases once a reader's run proves the span read")
    func holdReleasesWhenCoverageArrives() throws {
        let (engine, demuxer) = try engineWithDenseText(through: 60, perSecond: 100, playhead: 0.36)
        defer { demuxer.close() }
        let store = try #require(engine.softwareSubtitlePacketStore)
        for index in 0...438 {
            store.append(streamIndex: Self.subripStreamIndex, ptsSeconds: Double(index) * (1 / 100.0),
                         durationSeconds: 1.0 / 24, payload: Data("sign \(index)".utf8))
        }
        engine.subtitleDrainTick()
        let held = try #require(engine.subtitleDrainCursors[.primary]?.harvestGapAt, "held at the seam")
        #expect(abs(held - 4.38) < 1e-9)

        store.notePrefetchRead(from: 0, through: 60)
        engine.subtitleDrainTick()
        #expect(engine.subtitleDrainCursors[.primary]?.harvestGapAt == nil)
        #expect((engine.subtitleCues.map(\.startTime).max() ?? -1)
                >= 0.36 + AetherEngine.subtitleDrainUrgentLeadSeconds - 0.01)
    }

    @MainActor
    @Test("a seek back merges the landing's cues in front of those retained from later")
    func seekBackMergesInFrontOfRetainedCues() throws {
        let (engine, demuxer) = try engineWithDenseText(through: 60, perSecond: 100, playhead: 50)
        defer { demuxer.close() }
        engine.subtitleDrainTick()
        let later = engine.subtitleCues
        #expect(later.contains { $0.startTime >= 50 })

        // A seek back to 20 s: the drain resets onto a window that has no retained cues yet.
        engine.clock.sourceTime = 20
        engine.subtitleDrainTick()

        let cues = engine.subtitleCues
        #expect(cues.contains { $0.startTime <= 20 && 20 < $0.endTime })
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.startTime <= $1.startTime })
        #expect(Set(cues.map(\.id)).count == cues.count, "every retained cue keeps a unique id")
        #expect(Set(later.map(\.id)).isSubset(of: Set(cues.map(\.id))), "the later cues are retained")
    }
}

/// Deterministic generator so a failing seed reproduces.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension SubtitlePacketStore {
    /// The forward prefetch positioned at `from`, read its first packet there, and read on through
    /// `through`.
    func notePrefetchRead(from: Double, through: Double) {
        noteHarvestAnchor(.prefetch, at: from)
        noteHarvestProgress(.prefetch, through: from)
        noteHarvestReach(.prefetch, through: through)
    }
}
