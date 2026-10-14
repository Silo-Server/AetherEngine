import Testing
import Foundation
@testable import AetherEngine

/// #362, second mechanism: a hole in the harvest, read as a silence in the source.
///
/// After a seek the pump restarts behind the landing and fills forward, while the store still holds
/// an island the previous run harvested further ahead. The drain window then reads as "packets,
/// hole, packets", and decoding straight across it carries the cursor to the far side. The cursor
/// only ever moves forward, so the hole's packets, which land a second later, are never read: a
/// stretch of the film has no subtitles at all, and the set before the hole is closed at the island
/// instead of at its own clear (report: eleven authored sets delivered as two).
///
/// The gap's SIZE cannot tell a hole from an authored silence, and a threshold on it does real
/// damage: a PGS set is separated from its own clear by its display duration, so a 3 s rule stopped
/// the tick at every authored line and delivery fell to a sixth of the sets in a fixture run.
/// Harvest ORDER tells them apart, because a run reads forwards: within one run PTS and sequence
/// rise together, and a PTS-ascending pair whose sequence descends is two runs meeting over a span
/// neither has read.
@Suite("#362: a hole in the harvest is not a silence in the source")
struct Issue362HarvestHoleTests {

    /// The reported shape: 275 s and 280 s freshly harvested by the restarted pump (sequences 40,
    /// 41), 295 s and 300 s left by the run that served the earlier landing (sequences 8, 9). The
    /// packets between 280 and 295 have not been read by anyone.
    private let pts: [Double] = [275.023, 280.023, 295.023, 300.023]
    private let sequence: [UInt64] = [40, 41, 8, 9]

    private func cut(from index: Int = 0, resumeFrom: (pts: Double, sequence: UInt64)? = nil,
                     playhead: Double = 231) -> (index: Int, at: Double, sequence: UInt64)? {
        SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count - index,
            ptsAt: { pts[$0 + index] },
            sequenceAt: { sequence[$0 + index] },
            resumeFrom: resumeFrom,
            notBefore: playhead)
    }

    // MARK: - The reported case

    @Test("the tick stops where the harvest order breaks, not where the gap is widest")
    func stopsAtTheRunBoundary() {
        let boundary = cut()
        #expect(boundary?.index == 2)          // 275 and 280 decode, the island does not
        #expect(boundary?.at == 280.023)       // the hold sits on the last packet of this run
        #expect(boundary?.sequence == 41)
    }

    @Test("a hole that opens AT the cursor is still seen, which is where the report's window was")
    func holeAtTheCursor() {
        // The window a steady tick reads starts past the cursor, so when the hole opens right there
        // the window holds nothing but the island and no pair inside it can reveal anything. The
        // cursor's own harvest sequence is the missing half of the comparison: without it the tick
        // decodes the island, moves the cursor to 295 s and the four packets in between are lost
        // for the rest of the session.
        let islandOnly = SubtitleOverlayDrainer.harvestGapCut(
            count: 2, ptsAt: { [295.023, 300.023][$0] }, sequenceAt: { [8, 9][$0] },
            resumeFrom: (280.023, 41), notBefore: 231)
        #expect(islandOnly?.index == 0)        // nothing may decode this tick
        #expect(islandOnly?.at == 280.023)
    }

    @Test("with no pair and no cursor sequence there is nothing to claim, so nothing is held")
    func noSequenceNoHold() {
        // A cursor parked on a window boundary rather than on a packet carries sequence 0. It says
        // nothing about provenance and must not be read as "everything after me is old".
        let unknown = SubtitleOverlayDrainer.harvestGapCut(
            count: 2, ptsAt: { [295.023, 300.023][$0] }, sequenceAt: { [8, 9][$0] },
            resumeFrom: (280.023, 0), notBefore: 231)
        #expect(unknown == nil)
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 0, ptsAt: { _ in 0 }, sequenceAt: { _ in 0 },
            resumeFrom: nil, notBefore: 0) == nil)
    }

    // MARK: - What must survive it

    @Test("an authored silence is one run and never stops the tick, however long it is")
    func authoredSilenceIsNotAHole() {
        // The case a size threshold got wrong. Ninety seconds of no dialogue, harvested in order by
        // one run: nothing is missing, nothing is coming, and a tick that waited here would stall
        // delivery for its whole budget on perfectly healthy content.
        let quiet: [Double] = [275.023, 279.023, 369.023, 373.023]
        let inOrder: [UInt64] = [40, 41, 42, 43]
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 4, ptsAt: { quiet[$0] }, sequenceAt: { inOrder[$0] },
            resumeFrom: (270.023, 39), notBefore: 231) == nil)
    }

    @Test("a set and its own clear are a run boundary apart in time and never in order")
    func displayDurationIsNotAHole() {
        // Why the threshold rule had to go: a 4 s set is 4 s from its clear by construction, so a
        // 3 s rule fired on every authored line. In harvest order the two are adjacent.
        let set: [Double] = [280.023, 284.023, 285.023, 289.023]
        let inOrder: [UInt64] = [40, 41, 42, 43]
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 4, ptsAt: { set[$0] }, sequenceAt: { inOrder[$0] },
            resumeFrom: nil, notBefore: 231) == nil)
    }

    @Test("a hole behind the playhead is history and is decoded straight across")
    func holeBehindThePlayheadIsNotHeld() {
        // Waiting there delays the landing line for content the viewer has already passed, which is
        // the one thing #143's reconstruction pass must never be made to do.
        #expect(cut(playhead: 290) == nil)
    }

    // MARK: - Resuming

    @Test("the hold resumes when the filling run reaches it, and only then")
    func holdResumesOnFreshHarvest() {
        // The near side is no longer in the window, so what answers is the first entry's
        // provenance: newer than the sequence held at means the run has read through to here.
        #expect(!SubtitleOverlayDrainer.harvestGapHoldResumes(firstSequence: 8, heldSequence: 41))
        #expect(SubtitleOverlayDrainer.harvestGapHoldResumes(firstSequence: 42, heldSequence: 41))
        #expect(!SubtitleOverlayDrainer.harvestGapHoldResumes(firstSequence: nil, heldSequence: 41))
    }

    @Test("a re-harvested packet takes a fresh sequence, which is what releases the hold")
    func reharvestRefreshesTheSequence() {
        // The pump re-reads what it passes, island included, and the collapse of that duplicate is
        // the moment the span behind it is known to be read. Keeping the old sequence would leave a
        // boundary the drain waits at until its budget expires, every time.
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 295.023, durationSeconds: 0, payload: Data(count: 30))
        store.append(streamIndex: 3, ptsSeconds: 280.023, durationSeconds: 0, payload: Data(count: 900))
        let first = store.entries(streamIndex: 3, from: 0, through: 400)
        #expect(first.first(where: { $0.ptsSeconds == 295.023 })!.sequence
                < first.first(where: { $0.ptsSeconds == 280.023 })!.sequence)

        store.append(streamIndex: 3, ptsSeconds: 295.023, durationSeconds: 0, payload: Data(count: 30))
        let refreshed = store.entries(streamIndex: 3, from: 0, through: 400)
        #expect(refreshed.count == 2)   // the duplicate collapsed, it did not stack
        #expect(refreshed.first(where: { $0.ptsSeconds == 295.023 })!.sequence
                > refreshed.first(where: { $0.ptsSeconds == 280.023 })!.sequence)
    }

    @Test("a seam over ground some run has read is a re-harvest, not a hole")
    func readSeamIsNotAHole() {
        // The forward prefetch stored 0-60 s first; the pump re-read 0-4.38 s behind it, and each of
        // those duplicates took a fresh sequence. The order breaks at 4.38 over ground the prefetch
        // has read, and that seam moves with the pump on every tick.
        let pts = [4.0, 4.38, 4.40, 4.42]
        let sequence: [UInt64] = [900, 901, 400, 401]
        func seamCut(isRead: @escaping (Double, Double) -> Bool) -> (index: Int, at: Double, sequence: UInt64)? {
            SubtitleOverlayDrainer.harvestGapCut(count: pts.count, ptsAt: { pts[$0] },
                                                 sequenceAt: { sequence[$0] }, resumeFrom: nil,
                                                 notBefore: 0, isRead: isRead)
        }
        #expect(seamCut { _, _ in true } == nil)
        #expect(seamCut { _, _ in false }?.index == 2, "without proof the order rule stands")
        #expect(cut()?.index == 2, "the reported hole is unread ground, so it still holds")
    }

    @Test("only a current run proves a span read; an empty ledger refuses no landing but proves nothing")
    func proofNeedsOneCurrentRun() {
        let store = SubtitlePacketStore()
        #expect(store.hasReadSpan(from: 1, through: 2))
        #expect(!store.provesReadSpan(streamIndex: 3, from: 1, through: 2))
        store.notePrefetchRead(from: 0, through: 60)
        #expect(store.provesReadSpan(streamIndex: 3, from: 4.38, through: 4.40))
        #expect(!store.provesReadSpan(streamIndex: 3, from: 59, through: 61))
    }

    @Test("a real hole inside the seam tolerance is not proven read")
    func seamToleranceProvesNothing() {
        // One prefetch run read to 4.38 and stopped; the next started at 4.60. The ledger's seam
        // tolerance joins them for `hasReadSpan`, but nobody read the 0.22 s between.
        let store = SubtitlePacketStore()
        store.notePrefetchRead(from: 0, through: 4.38)
        store.notePrefetchRead(from: 4.60, through: 30)
        #expect(store.hasReadSpan(from: 4.38, through: 4.60))
        #expect(!store.provesReadSpan(streamIndex: 3, from: 4.38, through: 4.60))
        #expect(store.provesReadSpan(streamIndex: 3, from: 4.60, through: 30))
    }

    @Test("the pump's reach is a claim from the playhead, not proof of reading")
    func pumpReachProvesNothing() {
        // During a slow seek the playhead, and with it the pump's stated reach, can move past what
        // the pump has stored.
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.pump, at: 0)
        store.noteHarvestReach(.pump, through: 60)
        #expect(store.hasReadSpan(from: 4.38, through: 4.40))
        #expect(!store.provesReadSpan(streamIndex: 3, from: 4.38, through: 4.40))
    }

    @Test("ground the store has evicted is not proven read, however it was covered")
    func evictedGroundProvesNothing() {
        let store = SubtitlePacketStore()
        store.notePrefetchRead(from: 0, through: 60)
        for pts in [1.0, 2.0, 3.0, 40.0] {
            store.append(streamIndex: 3, ptsSeconds: pts, durationSeconds: 0, payload: Data(count: 8))
        }
        store.prune(before: 2.5)
        #expect(!store.provesReadSpan(streamIndex: 3, from: 1.5, through: 30))
        #expect(store.provesReadSpan(streamIndex: 3, from: 2.5, through: 30))
        #expect(store.provesReadSpan(streamIndex: 4, from: 1.5, through: 30), "eviction is per stream")
        // A new prefetch run reads the ground again and stores what the prune removed.
        store.noteHarvestAnchor(.prefetch, at: 0)
        for pts in [1.0, 2.0] { harvest(store, at: pts) }
        store.noteHarvestProgress(.prefetch, through: 30)
        #expect(store.entries(streamIndex: 3, from: 0, through: 30).map(\.ptsSeconds) == [1, 2, 3])
        #expect(store.provesReadSpan(streamIndex: 3, from: 1.5, through: 30))
    }

    @Test("a prefetch run proves reading only from the first position it read")
    func proofStartsAtTheFirstRead() {
        // Asked for 100 s, the seek landed at 120 s: a byte estimate that overshot, or Matroska
        // clamping to the anchor stream's first indexed cue. Its first packet there must not prove
        // 100-120 s read.
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.prefetch, at: 100)
        harvest(store, at: 120)
        store.noteHarvestProgress(.prefetch, through: 130)
        #expect(store.hasReadSpan(from: 100, through: 120), "the generous ledger still counts it")
        #expect(!store.provesReadSpan(streamIndex: 3, from: 100, through: 120))
        #expect(store.provesReadSpan(streamIndex: 3, from: 121, through: 129))

        // Landing before the anchor proves from the anchor on.
        store.noteHarvestAnchor(.prefetch, at: 200)
        harvest(store, at: 198)
        store.noteHarvestProgress(.prefetch, through: 230)
        #expect(store.provesReadSpan(streamIndex: 3, from: 200, through: 220))
        #expect(!store.provesReadSpan(streamIndex: 3, from: 199, through: 220), "nothing before the anchor")
    }

    @Test("a seam is judged by the proof captured with the entries it sits in")
    func proofIsCapturedWithItsEntries() {
        let store = SubtitlePacketStore()
        store.notePrefetchRead(from: 0, through: 100)
        let (_, proof) = store.entriesWithReadProof(streamIndex: 3, from: 0, through: 200)
        // The prefetch reads on and stores 101-119 after the copy was taken.
        for pts in [105.0, 110.0] { harvest(store, at: pts) }
        store.noteHarvestProgress(.prefetch, through: 120)
        #expect(store.provesReadSpan(streamIndex: 3, from: 100, through: 120))
        #expect(!proof.proves(from: 100, through: 120), "the copy lacks what was read after it")
        #expect(proof.proves(from: 50, through: 100))
    }

    @Test("a display set still in assembly is read but not stored, so it proves nothing")
    func pendingDisplaySetCapsTheProof() {
        let store = SubtitlePacketStore()
        store.notePrefetchRead(from: 0, through: 100)
        let pcs = Data([0x16, 0x00, 0x01, 0x00]), end = Data([0x80, 0x00, 0x00])
        func chunk(_ payload: Data, writer: SubtitlePacketStore.Writer = .prefetch) {
            store.harvestChunk(streamIndex: 3, ptsSeconds: 110, durationSeconds: 0, flags: 0,
                               payload: payload, assembleSplitDisplaySets: true, writer: writer)
        }
        chunk(pcs)
        chunk(pcs, writer: .pump)
        store.noteHarvestProgress(.prefetch, through: 120)
        #expect(store.provesReadSpan(streamIndex: 3, from: 100, through: 109))
        #expect(!store.provesReadSpan(streamIndex: 3, from: 100, through: 120))
        chunk(end)
        #expect(store.provesReadSpan(streamIndex: 3, from: 100, through: 120),
                "stored once its END arrives; the pump's own set in assembly does not matter")
    }

    @Test("a display set in assembly that memory pressure drops still bounds the proof")
    func evictedPendingSetBoundsTheProof() {
        let store = SubtitlePacketStore(perStreamByteCap: 10_000, aggregateByteCap: 1_000)
        store.notePrefetchRead(from: 0, through: 100)
        let pcs = Data([0x16, 0x02, 0x55]) + Data(count: 597)
        store.harvestChunk(streamIndex: 3, ptsSeconds: 110, durationSeconds: 0, flags: 0,
                           payload: pcs, assembleSplitDisplaySets: true, writer: .prefetch)
        store.noteHarvestProgress(.prefetch, through: 120)
        // Another stream's packet pushes the store over its budget; stream 3 is the cold one.
        store.append(streamIndex: 4, ptsSeconds: 115, durationSeconds: 0, payload: Data(count: 600))
        #expect(store.totalRetainedBytes <= 1_000)
        #expect(!store.provesReadSpan(streamIndex: 3, from: 100, through: 120),
                "the dropped set was read but never stored")
    }

    @Test("a display set dropped unfinished or oversize still bounds the proof")
    func droppedPendingSetsBoundTheProof() {
        let pcs = Data([0x16, 0x00, 0x01, 0x00]), end = Data([0x80, 0x00, 0x00])
        func chunk(_ store: SubtitlePacketStore, _ payload: Data, at pts: Double) {
            store.harvestChunk(streamIndex: 3, ptsSeconds: pts, durationSeconds: 0, flags: 0,
                               payload: payload, assembleSplitDisplaySets: true, writer: .prefetch)
        }
        // The next composition opens before this one's END arrives.
        let replaced = SubtitlePacketStore()
        replaced.notePrefetchRead(from: 0, through: 100)
        chunk(replaced, pcs, at: 110)
        chunk(replaced, pcs + end, at: 120)
        replaced.noteHarvestProgress(.prefetch, through: 130)
        #expect(!replaced.provesReadSpan(streamIndex: 3, from: 100, through: 130))
        #expect(replaced.provesReadSpan(streamIndex: 3, from: 111, through: 130))

        // A set over the assembly budget is dropped too.
        let oversize = SubtitlePacketStore()
        oversize.notePrefetchRead(from: 0, through: 100)
        chunk(oversize, Data([0x16, 0xFF, 0xFF]) + Data(count: SubtitlePacketStore.maxPendingDisplaySetBytes), at: 110)
        oversize.noteHarvestProgress(.prefetch, through: 130)
        #expect(!oversize.provesReadSpan(streamIndex: 3, from: 100, through: 130))

        // The END that tips a set over the budget can share its packet with a whole next set.
        let tail = SubtitlePacketStore()
        tail.notePrefetchRead(from: 0, through: 100)
        chunk(tail, Data([0x16, 0xFF, 0xFF]) + Data(count: SubtitlePacketStore.maxPendingDisplaySetBytes - 4), at: 110)
        chunk(tail, end + pcs + end, at: 120)
        tail.noteHarvestProgress(.prefetch, through: 130)
        #expect(!tail.provesReadSpan(streamIndex: 3, from: 111, through: 130), "the set at 120 s was dropped")
        #expect(tail.provesReadSpan(streamIndex: 3, from: 121, through: 130))
    }

    @Test("a subtitle packet the prefetch read but did not store bounds the proof")
    func unstoredPrefetchReadsBoundTheProof() {
        // A continuation chunk with no set open: the prefetch landed between a PCS and its END.
        let midSet = SubtitlePacketStore()
        midSet.notePrefetchRead(from: 0, through: 100)
        midSet.harvestChunk(streamIndex: 3, ptsSeconds: 110, durationSeconds: 0, flags: 0,
                            payload: Data([0x15, 0x00, 0x01, 0x00]), assembleSplitDisplaySets: true,
                            writer: .prefetch)
        midSet.noteHarvestProgress(.prefetch, through: 130)
        #expect(!midSet.provesReadSpan(streamIndex: 3, from: 100, through: 130))
        #expect(midSet.provesReadSpan(streamIndex: 3, from: 111, through: 130))

        // A packet dropped for want of a time base, at a position nobody knows.
        let noTimeBase = SubtitlePacketStore()
        noTimeBase.notePrefetchRead(from: 0, through: 130)
        noTimeBase.notePrefetchDroppedPacket(streamIndex: 3)
        #expect(!noTimeBase.provesReadSpan(streamIndex: 3, from: 100, through: 130))
        #expect(noTimeBase.provesReadSpan(streamIndex: 4, from: 100, through: 130), "only that stream")
        noTimeBase.notePrefetchRead(from: 0, through: 130)
        #expect(noTimeBase.provesReadSpan(streamIndex: 3, from: 100, through: 130), "a new run reads it again")

        // A packet without a PTS is dropped at a position nobody knows either.
        let noPTS = SubtitlePacketStore()
        noPTS.notePrefetchRead(from: 0, through: 130)
        noPTS.harvestChunk(streamIndex: 3, ptsSeconds: nil, durationSeconds: 0, flags: 0, payload: Data(count: 8),
                           assembleSplitDisplaySets: false, writer: .prefetch)
        #expect(!noPTS.provesReadSpan(streamIndex: 3, from: 100, through: 130))

        // A landing between a PCS and its END: that composition began before the run.
        let landing = SubtitlePacketStore()
        landing.noteHarvestAnchor(.prefetch, at: 100)
        landing.harvestChunk(streamIndex: 3, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                             payload: Data([0x15, 0x00, 0x01, 0x00]), assembleSplitDisplaySets: true,
                             writer: .prefetch)
        landing.noteHarvestProgress(.prefetch, through: 100)
        landing.noteHarvestReach(.prefetch, through: 130)
        #expect(landing.provesReadSpan(streamIndex: 3, from: 100, through: 130))
    }

    private func harvest(_ store: SubtitlePacketStore, at pts: Double) {
        store.harvestChunk(streamIndex: 3, ptsSeconds: pts, durationSeconds: 0, flags: 0,
                           payload: Data(count: 8), assembleSplitDisplaySets: false, writer: .prefetch)
    }

    @Test("the store stamps harvest order, ascending, across streams")
    func sequenceIsMonotonic() {
        let store = SubtitlePacketStore()
        for (index, pts) in [10.0, 20.0, 30.0].enumerated() {
            store.append(streamIndex: Int32(index % 2), ptsSeconds: pts, durationSeconds: 0,
                         payload: Data(count: 8))
        }
        let a = store.entries(streamIndex: 0, from: 0, through: 100)
        let b = store.entries(streamIndex: 1, from: 0, through: 100)
        #expect(a.map(\.sequence) == [1, 3])
        #expect(b.map(\.sequence) == [2])
    }
}
