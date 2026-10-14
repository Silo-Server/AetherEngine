import Foundation
import Testing
@testable import AetherEngine

/// Audit SUB-103 / SUB-111: `appendLocked` copied the whole per-stream array on every append (40k
/// appends took 10.9 s), the same-PTS duplicate check walked the whole run, the aggregate pass shifted
/// the array once per evicted packet, and display sets still in assembly sat outside every cap.
struct SubtitlePacketStoreScalingTests {

    private func payload(_ index: Int, size: Int = 24) -> Data {
        var data = Data(repeating: 0x41, count: size)
        withUnsafeBytes(of: UInt64(index).littleEndian) { data.replaceSubrange(0..<8, with: $0) }
        return data
    }

    @Test("40k ascending appends stay linear")
    func ascendingAppendsAreLinear() {
        let store = SubtitlePacketStore()
        let started = ContinuousClock.now
        for index in 0..<40_000 {
            store.append(streamIndex: 3, ptsSeconds: Double(index), durationSeconds: 1, payload: payload(index))
        }
        let elapsed = ContinuousClock.now - started
        #expect(store.frontier(streamIndex: 3) == 39_999)
        #expect(store.entries(streamIndex: 3, from: 0, through: 1e9).count == 40_000)
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    @Test("20k distinct packets on one timestamp stay linear and keep harvest order")
    func samePTSBurstIsLinear() {
        let store = SubtitlePacketStore()
        let started = ContinuousClock.now
        for index in 0..<20_000 {
            store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 1, payload: payload(index))
        }
        let elapsed = ContinuousClock.now - started
        let stored = store.entries(streamIndex: 3, from: 10, through: 10)
        #expect(stored.count == 20_000)
        #expect(stored.map(\.payload) == (0..<20_000).map { payload($0) })
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    @Test("a byte-identical packet re-harvested into a long same-PTS run collapses and takes the fresh sequence")
    func duplicateInALongRunCollapses() {
        let store = SubtitlePacketStore()
        for index in 0..<50 {
            store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 1, payload: payload(index))
        }
        let before = store.entries(streamIndex: 3, from: 10, through: 10)
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 1, payload: payload(17))
        let after = store.entries(streamIndex: 3, from: 10, through: 10)
        #expect(after.count == 50)
        #expect(after[17].payload == payload(17))
        #expect(after[17].sequence > before.map(\.sequence).max()!)
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 1, payload: payload(50))
        let grown = store.entries(streamIndex: 3, from: 10, through: 10)
        #expect(grown.count == 51)
        #expect(grown.last?.payload == payload(50))
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 1, payload: payload(50))
        #expect(store.entries(streamIndex: 3, from: 10, through: 10).count == 51)
    }

    @Test("the duplicate check still finds a packet after eviction moved the run")
    func duplicateSurvivesEviction() {
        let store = SubtitlePacketStore(perStreamByteCap: 40 * 24, aggregateByteCap: 1 << 20)
        for index in 0..<60 {
            store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 1, payload: payload(index))
        }
        let stored = store.entries(streamIndex: 3, from: 10, through: 10)
        #expect(store.totalRetainedBytes <= 40 * 24)
        #expect(stored.last?.payload == payload(59))
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 1, payload: payload(59))
        #expect(store.entries(streamIndex: 3, from: 10, through: 10).count == stored.count)
    }

    @Test("the per-stream cap holds after every append and evicts oldest first")
    func perStreamCapHolds() {
        let store = SubtitlePacketStore(perStreamByteCap: 10_000, aggregateByteCap: 1 << 20)
        for index in 0..<500 {
            store.append(streamIndex: 4, ptsSeconds: Double(index), durationSeconds: 1, payload: payload(index, size: 100))
            #expect(store.totalRetainedBytes <= 10_000)
        }
        let pts = store.entries(streamIndex: 4, from: 0, through: 1e9).map(\.ptsSeconds)
        #expect(pts.last == 499)
        #expect(pts == pts.sorted())
        #expect(pts.count > 80)
    }

    @Test("aggregate eviction of a long cold stream is linear")
    func aggregateEvictionIsLinear() {
        let store = SubtitlePacketStore(perStreamByteCap: 1 << 30, aggregateByteCap: 40_000 * 24)
        for index in 0..<40_000 {
            store.append(streamIndex: 1, ptsSeconds: Double(index), durationSeconds: 1, payload: payload(index))
        }
        let started = ContinuousClock.now
        for index in 0..<40_000 {
            store.append(streamIndex: 2, ptsSeconds: Double(index), durationSeconds: 1, payload: payload(index))
        }
        let elapsed = ContinuousClock.now - started
        #expect(store.totalRetainedBytes <= 40_000 * 24)
        #expect(store.frontier(streamIndex: 2) == 39_999)
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    @Test("a window read is found by search and matches the filter it replaced")
    func windowReadMatchesAFilter() {
        let store = SubtitlePacketStore()
        for index in 0..<200 {
            store.append(streamIndex: 3, ptsSeconds: Double(index / 2), durationSeconds: 1, payload: payload(index))
        }
        for (from, through) in [(0.0, 0.0), (10.0, 20.0), (-5.0, 3.0), (99.0, 500.0), (50.5, 50.9), (20.0, 10.0)] {
            let got = store.entries(streamIndex: 3, from: from, through: through).map(\.payload)
            let expected = (0..<200).filter { Double($0 / 2) >= from && Double($0 / 2) <= through }.map { payload($0) }
            #expect(got == expected, "window \(from)...\(through)")
        }
        #expect(store.firstPTS(streamIndex: 3, after: 10) == 11)
        #expect(store.firstPTS(streamIndex: 3, after: 99) == nil)
    }

    // MARK: - SUB-111 part 2: display sets in assembly count toward the aggregate cap

    private func pgsSegment(_ type: UInt8, bodyLen: Int) -> Data {
        var data = Data([type, UInt8((bodyLen >> 8) & 0xFF), UInt8(bodyLen & 0xFF)])
        data.append(Data(repeating: type, count: bodyLen))
        return data
    }

    @Test("END-less display sets on many streams do not escape the aggregate cap")
    func pendingSetsCountTowardTheAggregateCap() {
        let cap = 64 * 1024
        let store = SubtitlePacketStore(perStreamByteCap: cap, aggregateByteCap: cap)
        let streams = 100
        for stream in 0..<streams {
            for chunk in [pgsSegment(0x16, bodyLen: 11), pgsSegment(0x15, bodyLen: 2_000)] {
                store.harvestChunk(streamIndex: Int32(stream), ptsSeconds: chunk[0] == 0x16 ? 10 : nil,
                                   durationSeconds: 0, flags: 0, payload: chunk, assembleSplitDisplaySets: true)
            }
            #expect(store.totalRetainedBytes <= cap)
        }
        var completed = 0
        for stream in 0..<streams {
            store.harvestChunk(streamIndex: Int32(stream), ptsSeconds: nil, durationSeconds: 0, flags: 0,
                               payload: pgsSegment(0x80, bodyLen: 0), assembleSplitDisplaySets: true)
            if !store.entries(streamIndex: Int32(stream), from: 0, through: 100).isEmpty { completed += 1 }
        }
        #expect(completed > 0)
        #expect(completed < streams)
        #expect(store.totalRetainedBytes <= cap)
    }

    @Test("a display set in assembly on a protected stream survives the pressure and completes")
    func protectedPendingSetSurvives() {
        let cap = 64 * 1024
        let store = SubtitlePacketStore(perStreamByteCap: cap, aggregateByteCap: cap)
        store.setProtectedStreams([7])
        store.harvestChunk(streamIndex: 7, ptsSeconds: 10, durationSeconds: 0, flags: 0,
                           payload: pgsSegment(0x16, bodyLen: 11), assembleSplitDisplaySets: true)
        for stream in 100..<160 {
            for chunk in [pgsSegment(0x16, bodyLen: 11), pgsSegment(0x15, bodyLen: 2_000)] {
                store.harvestChunk(streamIndex: Int32(stream), ptsSeconds: chunk[0] == 0x16 ? 10 : nil,
                                   durationSeconds: 0, flags: 0, payload: chunk, assembleSplitDisplaySets: true)
            }
        }
        store.harvestChunk(streamIndex: 7, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: pgsSegment(0x80, bodyLen: 0), assembleSplitDisplaySets: true)
        #expect(store.entries(streamIndex: 7, from: 0, through: 100).count == 1)
    }

    @Test("clear forgets the assembly bytes too")
    func clearResetsThePendingAccounting() {
        let store = SubtitlePacketStore()
        store.harvestChunk(streamIndex: 7, ptsSeconds: 10, durationSeconds: 0, flags: 0,
                           payload: pgsSegment(0x16, bodyLen: 500), assembleSplitDisplaySets: true)
        #expect(store.totalRetainedBytes > 0)
        store.clear()
        #expect(store.totalRetainedBytes == 0)
    }
}
