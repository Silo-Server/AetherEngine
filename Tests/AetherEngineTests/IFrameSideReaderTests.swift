// Tests/AetherEngineTests/IFrameSideReaderTests.swift
import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}
private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// Every keyframe of the fixture's video stream as (pts-or-dts index timestamp, bytes), read
/// linearly on an independent demuxer: the reference the side reader is checked against.
private func referenceKeyframes(_ name: String) throws -> (index: [Int64], packets: [Int64: Data]) {
    let dem = Demuxer()
    try dem.open(url: fixtureURL(name))
    defer { dem.close() }
    let video = dem.videoStreamIndex
    var packets: [Int64: Data] = [:]
    while let pkt = try dem.readPacket() {
        var owned: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&owned) }
        guard pkt.pointee.stream_index == video, (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0,
              let bytes = pkt.pointee.data else { continue }
        let data = Data(bytes: bytes, count: Int(pkt.pointee.size))
        packets[pkt.pointee.dts] = data
        packets[pkt.pointee.pts] = data
    }
    return (dem.indexedKeyframes(streamIndex: video).sorted(), packets)
}

@Suite("I-frame side reader", .serialized)
struct IFrameSideReaderTests {
    private func reader(_ name: String) -> IFrameSideReader {
        IFrameSideReader(openDemuxer: {
            let dem = Demuxer()
            try dem.open(url: fixtureURL(name), profile: .iFrameSideDemuxer)
            return dem
        })
    }

    /// mp4 indexes its keyframes by DTS and Matroska by PTS (`PlanBoundaryAxis`), so both containers
    /// are read: the side reader must return the segment's own keyframe on either ladder.
    @Test("the payload at an indexed keyframe is that keyframe, in any request order",
          arguments: ["restart-witness-av.mp4", "restart-witness-subs.mkv"])
    func readsTheIndexedKeyframe(fixture: String) throws {
        guard fixtureExists(fixture) else { return }
        let ref = try referenceKeyframes(fixture)
        try #require(ref.index.count >= 2, "\(fixture) needs at least two indexed keyframes")
        let r = reader(fixture)
        defer { r.interrupt(); r.close() }
        for ts in ref.index.prefix(3).reversed() {
            let payload = try #require(r.payload(startPts: ts))
            #expect(payload == ref.packets[ts], "\(fixture): keyframe at \(ts) differs")
        }
    }

    @Test("a reader that cannot open answers nil every time, without retrying the open per call")
    func openFailureIsSticky() {
        var opens = 0
        let r = IFrameSideReader(openDemuxer: {
            opens += 1
            throw NSError(domain: "test", code: 1)
        })
        #expect(r.payload(startPts: 0) == nil)
        #expect(r.payload(startPts: 100) == nil)
        #expect(opens == 1)
    }

    @Test("after interrupt every call answers nil",
          .enabled(if: fixtureExists("restart-witness-av.mp4")))
    func interruptEndsIt() throws {
        let ref = try referenceKeyframes("restart-witness-av.mp4")
        let r = reader("restart-witness-av.mp4")
        #expect(r.payload(startPts: ref.index[0]) != nil)
        r.interrupt()
        #expect(r.payload(startPts: ref.index[0]) == nil)
        r.close()
    }

    @Test("the I-frame side profile reads like the still extractor under its own log name")
    func profile() {
        let p = DemuxerOpenProfile.iFrameSideDemuxer
        #expect(p.readerLabel == "iframe")
        #expect(p.avioPrefetch == DemuxerOpenProfile.stillExtraction.avioPrefetch)
        #expect(p.probesize == DemuxerOpenProfile.stillExtraction.probesize)
        #expect(DemuxerOpenProfile.labelsWithoutCompositionRepair.contains("iframe"))
        #expect(DemuxerOpenProfile.labelsWithoutCompositionRepair.contains("extract"))
    }
}
