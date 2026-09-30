import Foundation
import Testing
@testable import AetherEngine

/// The DVR ring's public behaviour, pinned independently of how it stores bytes: append and read by
/// sequence, the sequence bounds an evicting ring reports, keyframe-aligned eviction order, the
/// rewind lookups and the still run the scrub thumbnail decodes from. Written against the
/// file-per-packet ring first and kept unchanged across the chunk-spool rewrite (audit PERF-101).
@Suite("DVR ring behaviour")
struct PacketRingBufferBehaviourTests {

    private func makeScratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbbehave-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func payload(_ i: Int, count: Int = 16) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: i &+ $0) })
    }

    /// One second of 25 fps video per GOP with an audio packet after every video packet.
    private func fill(_ ring: PacketRingBuffer, seconds: Int, gopSeconds: Int = 2) throws {
        var index = 0
        for frame in 0..<(seconds * 25) {
            let pts = Double(frame) / 25
            let key = frame % (gopSeconds * 25) == 0
            try ring.append(pts: pts, isKeyframe: key, isVideo: true, bytes: payload(index))
            index += 1
            try ring.append(pts: pts, isKeyframe: false, isVideo: false, bytes: payload(index, count: 4))
            index += 1
        }
    }

    @Test("Packets read back by sequence with their flags and bytes, audio and video interleaved")
    func readsBackBySequence() throws {
        let ring = try PacketRingBuffer(windowSeconds: 3600, scratch: makeScratch())
        defer { ring.close() }
        try ring.append(pts: 10, isKeyframe: true, isVideo: true, bytes: Data([1, 2, 3]))
        try ring.append(pts: 10, isKeyframe: false, isVideo: false, bytes: Data([4]))
        try ring.append(pts: 10.04, isKeyframe: false, isVideo: true, bytes: Data())
        try ring.append(pts: 10.08, isKeyframe: false, isVideo: true, bytes: Data([9, 9]))

        #expect(ring.seqBounds.first == 0)
        #expect(ring.seqBounds.end == 4)
        let v = try #require(ring.packet(atSeq: 0))
        #expect(v.pts == 10 && v.isKeyframe && v.isVideo && v.bytes == Data([1, 2, 3]))
        let a = try #require(ring.packet(atSeq: 1))
        #expect(a.pts == 10 && !a.isKeyframe && !a.isVideo && a.bytes == Data([4]))
        let empty = try #require(ring.packet(atSeq: 2))
        #expect(empty.bytes.isEmpty && empty.isVideo)
        #expect(ring.packet(atSeq: 3)?.bytes == Data([9, 9]))
        #expect(ring.packet(atSeq: 4) == nil, "not appended yet")
        #expect(ring.packet(atSeq: -1) == nil)
    }

    @Test("Eviction keeps the retained span on a video keyframe and advances the first sequence")
    func evictionIsKeyframeAlignedAndMonotonic() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: makeScratch())
        defer { ring.close() }
        var lastFirst = 0
        for second in 0..<60 {
            for frame in 0..<25 {
                let n = second * 25 + frame
                try ring.append(pts: Double(n) / 25, isKeyframe: n % 50 == 0, isVideo: true, bytes: payload(n))
                let bounds = ring.seqBounds
                #expect(bounds.first >= lastFirst, "firstSeq never moves backwards")
                #expect(bounds.end == n + 1)
                lastFirst = bounds.first
            }
        }
        let bounds = ring.seqBounds
        #expect(bounds.first > 0)
        let first = try #require(ring.packet(atSeq: bounds.first))
        #expect(first.isKeyframe && first.isVideo, "the retained span opens on a keyframe")
        #expect(first.bytes == payload(bounds.first))
        #expect(ring.packet(atSeq: bounds.first - 1) == nil, "the evicted prefix reads as gone")
        #expect(ring.packet(atSeq: bounds.end - 1)?.bytes == payload(bounds.end - 1))

        let edge = Double(60 * 25 - 1) / 25
        let oldest = try #require(ring.oldestPts)
        #expect(oldest <= edge - 10, "never evicts inside the window")
        #expect(oldest > edge - 10 - 2.0 - 0.001, "evicts up to the last keyframe at or before the cutoff")
    }

    @Test("Nothing is evicted while the retained history fits the window, and an infinite window keeps everything")
    func wholeWindowIsKept() throws {
        let short = try PacketRingBuffer(windowSeconds: 100, scratch: makeScratch())
        defer { short.close() }
        try fill(short, seconds: 30)
        #expect(short.seqBounds.first == 0)
        #expect(short.seqBounds.end == 30 * 25 * 2)

        let forever = try PacketRingBuffer(windowSeconds: .infinity, scratch: makeScratch())
        defer { forever.close() }
        try fill(forever, seconds: 30)
        #expect(forever.seqBounds.first == 0)
        #expect(forever.seqBounds.end == 30 * 25 * 2)
    }

    @Test("Rewind lookups: newest keyframe at or before a target, earliest keyframe as the floor")
    func rewindLookups() throws {
        let ring = try PacketRingBuffer(windowSeconds: 3600, scratch: makeScratch())
        defer { ring.close() }
        // The session joined mid-GOP: two non-key packets precede the first keyframe.
        try ring.append(pts: 4.8, isKeyframe: false, isVideo: true, bytes: Data([0]))
        try ring.append(pts: 4.9, isKeyframe: false, isVideo: false, bytes: Data([1]))
        try ring.append(pts: 5.0, isKeyframe: true, isVideo: true, bytes: Data([2]))
        try ring.append(pts: 5.1, isKeyframe: false, isVideo: true, bytes: Data([3]))
        try ring.append(pts: 7.0, isKeyframe: true, isVideo: true, bytes: Data([4]))
        try ring.append(pts: 7.1, isKeyframe: false, isVideo: true, bytes: Data([5]))

        #expect(ring.firstKeyframeSeq() == 2, "the floor skips the mid-GOP leading entries")
        #expect(ring.seq(forKeyframeAtOrBefore: 6.0) == 2)
        #expect(ring.seq(forKeyframeAtOrBefore: 7.0) == 4)
        #expect(ring.seq(forKeyframeAtOrBefore: 99) == 4)
        #expect(ring.seq(forKeyframeAtOrBefore: 4.95) == nil, "before every keyframe")
        #expect(try ring.keyframePts(atOrBefore: 6.0) == 5.0)
        #expect(try ring.keyframePts(atOrBefore: 4.0) == nil)
        #expect(ring.oldestPts == 4.8)
    }

    @Test("Rewind lookups stay correct after eviction has moved the first sequence")
    func rewindLookupsAfterEviction() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: makeScratch())
        defer { ring.close() }
        try fill(ring, seconds: 60, gopSeconds: 2)
        let bounds = ring.seqBounds
        #expect(bounds.first > 0)
        let floor = try #require(ring.firstKeyframeSeq())
        #expect(floor >= bounds.first)
        let floorPacket = try #require(ring.packet(atSeq: floor))
        #expect(floorPacket.isKeyframe && floorPacket.isVideo)
        #expect(ring.seq(forKeyframeAtOrBefore: floorPacket.pts - 0.5) == nil)
        #expect(ring.seq(forKeyframeAtOrBefore: floorPacket.pts) == floor)
        let newest = try #require(ring.seq(forKeyframeAtOrBefore: .infinity))
        let newestPacket = try #require(ring.packet(atSeq: newest))
        #expect(newestPacket.isKeyframe && newestPacket.pts > 55)
    }

    @Test("packets(fromPts:) replays from the first video keyframe, audio included")
    func replayStartsOnAVideoKeyframe() throws {
        let ring = try PacketRingBuffer(windowSeconds: 3600, scratch: makeScratch())
        defer { ring.close() }
        try ring.append(pts: 1.0, isKeyframe: false, isVideo: false, bytes: Data([1]))
        try ring.append(pts: 1.1, isKeyframe: false, isVideo: true, bytes: Data([2]))
        try ring.append(pts: 1.2, isKeyframe: true, isVideo: true, bytes: Data([3]))
        try ring.append(pts: 1.2, isKeyframe: false, isVideo: false, bytes: Data([4]))
        try ring.append(pts: 1.3, isKeyframe: false, isVideo: true, bytes: Data([5]))

        let replay = try ring.packets(fromPts: 1.0)
        #expect(replay.map { $0.bytes.first } == [3, 4, 5])
        #expect(try ring.packets(fromPts: 1.25).isEmpty, "a start after the keyframe has no video keyframe to open on")
        #expect(try ring.packets(fromPts: 99).isEmpty)
    }

    @Test("A still run opens on the keyframe, carries video only, and respects its bounds")
    func stillRunShape() throws {
        let ring = try PacketRingBuffer(windowSeconds: 3600, scratch: makeScratch())
        defer { ring.close() }
        try fill(ring, seconds: 10, gopSeconds: 2)

        let run = try #require(ring.stillRun(target: 5.0, maxPackets: 500, maxSpanSeconds: 30, reorderTail: 0))
        #expect(run.first?.isKeyframe == true)
        #expect(run.allSatisfy { $0.isVideo })
        #expect(run.first?.pts == 4.0)
        #expect(run.last?.pts == 5.0)
        #expect(run.count == 26)

        let tailed = try #require(ring.stillRun(target: 5.0, maxPackets: 500, maxSpanSeconds: 30, reorderTail: 2))
        #expect(tailed.count == 28)

        #expect(ring.stillRun(target: 5.0, maxPackets: 10, maxSpanSeconds: 30, reorderTail: 0) == nil)
        #expect(ring.stillRun(target: 5.0, maxPackets: 500, maxSpanSeconds: 0.5, reorderTail: 0) == nil)
        #expect(ring.stillRun(target: -1, maxPackets: 500, maxSpanSeconds: 30, reorderTail: 0) == nil)

        let atEdge = try #require(ring.stillRun(target: 99, maxPackets: 500, maxSpanSeconds: 300, reorderTail: 0))
        #expect(atEdge.last?.pts == 9.96, "a target beyond the newest packet clamps to it")
    }

    @Test("close() clears the index at once and is idempotent")
    func closeIsImmediateAndIdempotent() throws {
        let ring = try PacketRingBuffer(windowSeconds: 60, scratch: makeScratch())
        try fill(ring, seconds: 4)
        #expect(ring.seqBounds.end > 0)
        ring.close()
        #expect(ring.seqBounds.first == ring.seqBounds.end)
        #expect(ring.packet(atSeq: 0) == nil)
        #expect(ring.oldestPts == nil)
        ring.close()
    }
}
