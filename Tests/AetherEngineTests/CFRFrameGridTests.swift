// AE#886: a constant-rate track on Matroska's 1 ms time base is muxed on its exact frame grid.
import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("CFRFrameGrid (AE#886)")
struct CFRFrameGridTests {
    private let ms = AVRational(num: 1, den: 1000)

    /// What mkvmerge writes for frame `n` of a track starting at `origin` ms.
    private func matroskaPts(_ n: Int64, rate: Double, origin: Int64 = 0) -> Int64 {
        origin + Int64((Double(n) * 1000 / rate).rounded())
    }

    @Test("23.976 on 1 ms gets 1/24000 with 1001 ticks a frame")
    func grid23976() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        #expect(grid.outputTimeBase.num == 1 && grid.outputTimeBase.den == 24000)
        #expect(grid.frameTicks == 1001)
    }

    @Test("24, 29.97, 30, 59.94 and 60 get a grid; 25 and 50 fit 1 ms and do not")
    func whichRatesGetAGrid() {
        func frame(_ num: Int32, _ den: Int32) -> Int64? {
            CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: num, den: den), startPts: 0)?.frameTicks
        }
        #expect(frame(24, 1) == 1000)
        #expect(frame(30000, 1001) == 1001)
        #expect(frame(30, 1) == 1000)
        #expect(frame(60000, 1001) == 1001)
        #expect(frame(60, 1) == 1000)
        #expect(frame(25, 1) == nil)
        #expect(frame(50, 1) == nil)
    }

    @Test("A fine time base, an odd rate or a missing rate gets no grid")
    func noGrid() {
        let rate = AVRational(num: 24000, den: 1001)
        #expect(CFRFrameGrid.make(sourceTimeBase: AVRational(num: 1, den: 90000), frameRate: rate, startPts: 0) == nil)
        #expect(CFRFrameGrid.make(sourceTimeBase: AVRational(num: 1, den: 16000), frameRate: rate, startPts: 0) == nil)
        #expect(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 2397, den: 100), startPts: 0) == nil)
        #expect(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 0, den: 1), startPts: 0) == nil)
    }

    @Test("24.000 and 23.976 are never confused")
    func ratesStayApart() throws {
        let grid24 = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24, den: 1), startPts: 0))
        let grid23 = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        #expect(grid24.frameTicks == 1000)
        #expect(grid23.frameTicks == 1001)
    }

    @Test("Millisecond-rounded 23.976 frames land on exact 1001-tick steps across two hours")
    func snapsRoundedFrames() throws {
        let rate = 24000.0 / 1001.0
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        for n in stride(from: Int64(0), to: 172_800, by: 7) {
            #expect(grid.snap(matroskaPts(n, rate: rate)) == n * 1001)
        }
    }

    @Test("The origin is the stream's start time")
    func originFromStartTime() throws {
        let rate = 24000.0 / 1001.0
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 1400))
        for n: Int64 in [0, 1, 2, 3, 1000, 50_001] {
            #expect(grid.snap(matroskaPts(n, rate: rate, origin: 1400)) == 1400 * 24 + n * 1001)
        }
    }

    @Test("A timestamp more than one source tick off the grid keeps its own time")
    func offGridPassesThrough() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        // Frame 1 is 41.708 ms; one source tick is 24 output ticks.
        #expect(grid.snap(41) == 1001)
        #expect(grid.snap(42) == 1001)
        #expect(grid.snap(43) == nil)
        #expect(grid.snap(20) == nil)
        #expect(grid.snap(Int64.min) == nil)
    }

    @Test("A packet keeps reorder order, its DTS never passes its PTS, and the shift moves both")
    func placePacket() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        let b = try #require(grid.place(pts: 125, dts: 83, duration: 42, shift: 0))
        #expect(b.pts == 3003 && b.dts == 2002 && b.duration == 1001)
        // DTS repaired off the grid (lastValidDts + 1) stays where the rescale puts it.
        let head = try #require(grid.place(pts: 42, dts: 2, duration: 41, shift: 0))
        #expect(head.pts == 1001 && head.dts == 48)
        // A DTS that rounds onto the PTS slot or past it is held at the PTS.
        let flat = try #require(grid.place(pts: 42, dts: 43, duration: 42, shift: 0))
        #expect(flat.dts <= flat.pts)
        // Item axis = source - shift; the grid is decided on the source axis.
        let shifted = try #require(grid.place(pts: 125 - 1400, dts: 83 - 1400, duration: 42, shift: 1400))
        #expect(shifted.pts == 3003 - 1400 * 24 && shifted.dts == 2002 - 1400 * 24)
        #expect(grid.place(pts: 20, dts: 20, duration: 42, shift: 0) == nil)
    }

    /// What the producer writes for each packet of a stream in decode order: the old duration (the
    /// source-TB telescope through `place` or the plain rescale) and the new one (`durationToNext`).
    private func written(
        _ grid: CFRFrameGrid, _ packets: [(pts: Int64, dts: Int64)]
    ) -> [(dts: Int64, oldDuration: Int64, newDuration: Int64)] {
        packets.indices.map { i in
            let p = packets[i]
            let next = i + 1 < packets.count ? packets[i + 1] : nil
            let sourceDuration = next.map { $0.dts - p.dts } ?? 42
            let dts = grid.writtenDts(pts: p.pts, dts: p.dts, shift: 0)
            let old = grid.place(pts: p.pts, dts: p.dts, duration: sourceDuration, shift: 0)?.duration
                ?? grid.rescale(sourceDuration)
            let new = next.flatMap {
                grid.durationToNext(writtenDts: dts, nextPts: $0.pts, nextDts: $0.dts, shift: 0, capTicks: 10_000)
            } ?? old
            return (dts, old, new)
        }
    }

    /// Overshoots past the next written DTS, in output ticks. movenc logs each one that falls on a
    /// fragment boundary as `Packet duration: -N` and drops that keyframe's PTS.
    private func overshoots(_ rows: [(dts: Int64, oldDuration: Int64, newDuration: Int64)],
                            useNew: Bool) -> [Int64] {
        zip(rows, rows.dropFirst()).compactMap { cur, next in
            let end = cur.dts + (useNew ? cur.newDuration : cur.oldDuration)
            return end > next.dts ? end - next.dts : nil
        }
    }

    @Test("AE#886: a held packet's duration ends on the next packet's written DTS")
    func durationEndsOnNextWrittenDts() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        // On the grid (DTS slot 2002), then an off-grid keyframe whose DTS rescales to 2496.
        let rows = written(grid, [(pts: 125, dts: 83), (pts: 147, dts: 104)])
        #expect(rows[1].dts == 2496)
        #expect(rows[0].dts + rows[0].oldDuration > rows[1].dts)   // what the device logged
        #expect(rows[0].newDuration == 2496 - 2002)
        // No successor, or one that does not move forward: nil, the caller keeps its duration.
        #expect(grid.durationToNext(writtenDts: 2002, nextPts: 125, nextDts: 83, shift: 0, capTicks: 10_000) == nil)
        #expect(grid.durationToNext(writtenDts: Int64.min, nextPts: 147, nextDts: 104, shift: 0, capTicks: 10_000) == nil)
        // A gap past the cap (a wrap, a discontinuity) is not a duration either.
        #expect(grid.durationToNext(writtenDts: 0, nextPts: 50_000, nextDts: 50_000, shift: 0, capTicks: 10_000) == nil)
    }

    @Test("AE#886: a stream that leaves and rejoins the grid never overshoots a written DTS")
    func mixedGridStreamNeverOvershoots() throws {
        let rate = 24000.0 / 1001.0
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        // Frames 0..<400 on the grid, then an edit moves the next 400 by 2 ms (off the grid by more
        // than one source tick), then the grid again. Decode order with one B-frame per pair
        // (I P B P B ...), DTS one frame behind PTS as mkvmerge and the demuxer's repair produce.
        var packets: [(pts: Int64, dts: Int64)] = []
        func pts(_ n: Int64) -> Int64 { matroskaPts(n, rate: rate) + ((400..<800).contains(n) ? 2 : 0) }
        for n in Int64(0)..<1200 {
            let display: Int64 = n == 0 ? 0 : (n % 2 == 1 ? n + 1 : n - 1)
            packets.append((pts: pts(display) + matroskaPts(1, rate: rate), dts: pts(n)))
        }
        let rows = written(grid, packets)
        #expect(!overshoots(rows, useNew: false).isEmpty)
        #expect(overshoots(rows, useNew: true).isEmpty)
        // On-grid stretches keep exact one-frame durations.
        #expect(rows[10].newDuration == 1001)
        #expect(rows[1000].newDuration == 1001)
    }

    @Test("A duration that is not one frame is rescaled, not replaced")
    func durationKeptWhenNotAFrame() throws {
        let grid = try #require(CFRFrameGrid.make(sourceTimeBase: ms, frameRate: AVRational(num: 24000, den: 1001), startPts: 0))
        #expect(grid.place(pts: 42, dts: 42, duration: 84, shift: 0)?.duration == Int64(84 * 24))
        #expect(grid.place(pts: 42, dts: 42, duration: 0, shift: 0)?.duration == 0)
    }
}
