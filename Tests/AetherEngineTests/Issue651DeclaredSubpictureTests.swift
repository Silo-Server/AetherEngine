import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// #651: a DVD title whose IFO declares its subpicture streams opens them before the probe, joins
/// their fragments the way libavformat's `dvdsub` parser would, and needs no long probe to find them.
@Suite("DVD subpicture streams declared from the IFO (#651)")
struct Issue651DeclaredSubpictureTests {

    // MARK: - Assembler

    private func timing(_ pts: Int64) -> DVDSubpictureAssembler.Timing {
        .init(pts: pts, dts: pts, pos: 0, duration: 0)
    }

    private func ingest(_ a: inout DVDSubpictureAssembler, _ bytes: [UInt8], _ pts: Int64) -> DVDSubpictureAssembler.Unit? {
        bytes.withUnsafeBytes { a.ingest($0, timing: timing(pts)) }
    }

    /// A unit of `size` bytes whose first two bytes state that size.
    private func unit(_ size: Int) -> [UInt8] {
        [UInt8(size >> 8), UInt8(size & 0xff)] + (2..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) }
    }

    @Test("a unit in one fragment passes through")
    func singleFragment() {
        var a = DVDSubpictureAssembler()
        let bytes = unit(100)
        #expect(ingest(&a, bytes, 900) == .init(data: bytes, timing: timing(900)))
        #expect(!a.isAssembling)
    }

    @Test("fragments join into one unit carrying the first fragment's timing")
    func joinsFragments() {
        var a = DVDSubpictureAssembler()
        let bytes = unit(5000)
        #expect(ingest(&a, Array(bytes[0..<2000]), 900) == nil)
        #expect(ingest(&a, Array(bytes[2000..<4000]), Int64.min) == nil)
        #expect(ingest(&a, Array(bytes[4000...]), Int64.min) == .init(data: bytes, timing: timing(900)))
    }

    @Test("a zero 16-bit size reads the 32-bit size behind it")
    func thirtyTwoBitSize() {
        var a = DVDSubpictureAssembler()
        let size = 70_000
        var bytes: [UInt8] = [0, 0, 0, 1, 0x11, 0x70]
        bytes += [UInt8](repeating: 0xAB, count: size - bytes.count)
        #expect(ingest(&a, Array(bytes[0..<40_000]), 1) == nil)
        #expect(ingest(&a, Array(bytes[40_000...]), Int64.min)?.data.count == size)
    }

    @Test("a fragment that overruns the stated size drops the unit")
    func overrunDrops() {
        var a = DVDSubpictureAssembler()
        let bytes = unit(3000)
        #expect(ingest(&a, Array(bytes[0..<2000]), 1) == nil)
        #expect(ingest(&a, [UInt8](repeating: 0, count: 2000), Int64.min) == nil)
        #expect(!a.isAssembling)
        // The next unit starts clean.
        #expect(ingest(&a, unit(50), 2)?.timing.pts == 2)
    }

    @Test("a reset drops a half-joined unit")
    func resetDrops() {
        var a = DVDSubpictureAssembler()
        #expect(ingest(&a, Array(unit(3000)[0..<2000]), 1) == nil)
        a.reset()
        #expect(ingest(&a, unit(40), 7)?.timing.pts == 7)
    }

    @Test("a first fragment too short to state a size is dropped")
    func shortHeaderDrops() {
        var a = DVDSubpictureAssembler()
        #expect(ingest(&a, [0x00], 1) == nil)
        #expect(ingest(&a, [0x00, 0x40, 1], 1) == nil)
        #expect(!a.isAssembling)
    }

    // Audit NET-104 / DMX-106: the 32-bit form reserved whatever it stated, up to 4 GiB, and then
    // swallowed every later fragment of the stream.
    @Test("a 32-bit size past 1 MiB drops the unit without reserving it")
    func hostileThirtyTwoBitSizeDrops() {
        var a = DVDSubpictureAssembler()
        let bytes: [UInt8] = [0, 0, 0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0xAB, count: 2000)
        #expect(ingest(&a, bytes, 1) == nil)
        #expect(!a.isAssembling)
        #expect(a.reservedCapacity < 128 * 1024)
        #expect(ingest(&a, unit(40), 2)?.timing.pts == 2)
    }

    @Test("a unit of exactly 1 MiB still joins, reserving about 64 KiB up front")
    func megabyteUnitJoins() {
        var a = DVDSubpictureAssembler()
        let size = 1 << 20
        var bytes: [UInt8] = [0, 0, 0x00, 0x10, 0x00, 0x00]
        bytes += [UInt8](repeating: 0x5A, count: size - bytes.count)
        #expect(ingest(&a, Array(bytes[0..<2048]), 1) == nil)
        // The allocator rounds a 64 KiB request up; the point is that 1 MiB is not reserved.
        #expect(a.reservedCapacity < 128 * 1024)
        #expect(ingest(&a, Array(bytes[2048...]), Int64.min)?.data.count == size)
    }

    @Test("a 60 KB unit across 30 fragments yields one unit")
    func sixtyKilobytesInThirtyFragments() {
        var a = DVDSubpictureAssembler()
        let bytes = unit(60_000)
        var units: [DVDSubpictureAssembler.Unit] = []
        for k in 0..<30 {
            let fragment = Array(bytes[(k * 2000)..<((k + 1) * 2000)])
            if let joined = ingest(&a, fragment, k == 0 ? 5 : Int64.min) { units.append(joined) }
        }
        #expect(units == [.init(data: bytes, timing: timing(5))])
    }

    // MARK: - IFO

    /// A VTS IFO without a PGCIT declaring `count` subpictures, the first `withLanguage` of them with
    /// a language.
    private func vtsIFO(subpictures count: Int, withLanguage: Int) -> [UInt8] {
        var ifo = [UInt8](repeating: 0, count: ISO9660Fixture.sectorSize)
        ifo.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        ifo[0x255] = UInt8(count)
        for n in 0..<withLanguage {
            let s = 0x256 + n * 6
            ifo[s] = 0x01
            ifo[s + 2] = UInt8(ascii: "e")
            ifo[s + 3] = UInt8(ascii: "n")
        }
        return ifo
    }

    @Test("every declared subpicture is a stream id, with a language or without")
    func parsesDeclaredIDs() {
        #expect(DVDIFOParser.parseSubpictureStreamIDs(vtsIFO(subpictures: 3, withLanguage: 1)) == [0x20, 0x21, 0x22])
        #expect(DVDIFOParser.parseSubpictureStreamIDs(vtsIFO(subpictures: 0, withLanguage: 0)) == [])
        #expect(DVDIFOParser.parseSubpictureStreamIDs([UInt8](repeating: 0, count: 2048)) == nil)
    }

    @Test("a title without a VTS IFO declares nothing, which is not the same as declaring no streams")
    func unreadableIFOIsNil() throws {
        let image = ISO9660Fixture.make(files: [.init(name: "VTS_01_1.VOB", length: 2048)])
        let info = try #require(try DiscReader.wrap(DataIOReader(data: image)))
        #expect(try #require(info.selectedTitle).dvdSubpictureStreamIDs == nil)
    }

    // MARK: - Through the demuxer

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    private let packHeader: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x89, 0xC3, 0xF8]

    private func ptsBytes(_ pts: Int64) -> [UInt8] {
        [UInt8(0x21 | ((pts >> 29) & 0x0E)), UInt8((pts >> 22) & 0xFF),
         UInt8(((pts >> 14) & 0xFE) | 1), UInt8((pts >> 7) & 0xFF), UInt8(((pts << 1) & 0xFE) | 1)]
    }

    /// One pack holding one private_stream_1 PES for subpicture substream `substream`.
    private func subpicturePack(substream: UInt8, payload: [UInt8], pts: Int64?) -> [UInt8] {
        let header: [UInt8] = pts.map { [0x81, 0x80, 5] + ptsBytes($0) } ?? [0x81, 0x00, 0]
        let body = header + [substream] + payload
        return packHeader + [0, 0, 1, 0xBD] + be16(body.count) + body
    }

    @Test("a declared stream is a track before its first packet, and its fragments arrive joined")
    func demuxerDeclaresAndJoins() throws {
        // One sector in all: the fixture writes a single sector per file.
        let spu = unit(1200)
        var vob: [UInt8] = []
        vob += subpicturePack(substream: 0x20, payload: Array(spu[0..<400]), pts: 90_000)
        vob += subpicturePack(substream: 0x20, payload: Array(spu[400..<800]), pts: nil)
        vob += subpicturePack(substream: 0x20, payload: Array(spu[800...]), pts: nil)
        vob += [0, 0, 1, 0xB9]
        vob += [UInt8](repeating: 0, count: ISO9660Fixture.sectorSize - vob.count)

        let image = ISO9660Fixture.make(files: [
            .init(name: "VIDEO_TS.IFO", length: 2048),
            .init(name: "VTS_01_0.IFO", length: ISO9660Fixture.sectorSize,
                  content: vtsIFO(subpictures: 2, withLanguage: 2)),
            .init(name: "VTS_01_1.VOB", length: vob.count, content: vob),
        ])
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: image), formatHint: nil)

        // 0x21 never carries a packet in this title, and is a track anyway.
        let ids = (0..<32).compactMap { demuxer.stream(at: Int32($0))?.pointee.id }
        #expect(ids.contains(0x20) && ids.contains(0x21), "stream ids: \(ids)")

        var joined: [(data: [UInt8], pts: Int64)] = []
        while let packet = try demuxer.readPacket() {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            if demuxer.stream(at: packet.pointee.stream_index)?.pointee.id == 0x20 {
                joined.append((Array(UnsafeBufferPointer(start: packet.pointee.data,
                                                         count: Int(packet.pointee.size))),
                               packet.pointee.pts))
            }
            trackedPacketFree(&p)
        }
        #expect(joined.count == 1)
        #expect(joined.first?.data == spu)
        #expect(joined.first?.pts == 90_000)
    }
}
