// Tests/AetherEngineTests/IFrameRenditionTests.swift
import Foundation
import Testing
@testable import AetherEngine

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _reads: [Int64] = []
    private var _closed = 0, _interrupted = 0, _waits = 0
    var failing: Set<Int64> = []
    func read(_ e: IFrameRendition.Entry) -> Data? {
        lock.lock(); defer { lock.unlock() }
        _reads.append(e.startPts)
        return failing.contains(e.startPts) ? nil : Data("key\(e.startPts)".utf8)
    }
    func noteClose() { lock.lock(); _closed += 1; lock.unlock() }
    func noteInterrupt() { lock.lock(); _interrupted += 1; lock.unlock() }
    func noteWait() { lock.lock(); _waits += 1; lock.unlock() }
    var reads: [Int64] { lock.lock(); defer { lock.unlock() }; return _reads }
    var closed: Int { lock.lock(); defer { lock.unlock() }; return _closed }
    var interrupted: Int { lock.lock(); defer { lock.unlock() }; return _interrupted }
    var waits: Int { lock.lock(); defer { lock.unlock() }; return _waits }
}

struct IFrameRenditionTests {
    private func make(_ rec: Recorder, count: Int = 5) -> (IFrameRendition, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iframe-rendition-\(UUID().uuidString)", isDirectory: true)
        let entries = (0..<count).map {
            IFrameRendition.Entry(startPts: Int64($0) * 1000, startSeconds: Double($0) * 4, durationSeconds: 4)
        }
        let rendition = IFrameRendition(
            entries: entries,
            cache: IFramePayloadCache(directory: dir, byteLimit: 1 << 20),
            readPayload: rec.read,
            buildFragment: { payload, index, entry in
                // The fragment names the payload it was built from and the time it was stamped with.
                IFrameFragmentBuilder.Output(
                    initSegment: Data("init".utf8),
                    fragment: payload + Data("@\(index):\(entry.startSeconds)".utf8))
            },
            waitForLink: rec.noteWait,
            interruptReads: rec.noteInterrupt,
            closeReader: rec.noteClose)
        return (rendition, dir)
    }

    @Test("a fragment is the entry's own keyframe stamped with the entry's time")
    func ownKeyframe() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.fragment(at: 2) == Data("key2000@2:8.0".utf8))
    }

    @Test("a second request for the same index reads the source once")
    func cachesPayload() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 3)
        _ = r.fragment(at: 3)
        #expect(rec.reads == [3000])
    }

    @Test("the init arrives without any fragment having been requested, by building entry 0")
    func initBuildsFirstEntry() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.initSegment() == Data("init".utf8))
        #expect(rec.reads == [0])
        #expect(r.initSegment() == Data("init".utf8))
        #expect(rec.reads == [0])
    }

    @Test("a failed read is answered with the nearest cached keyframe, stamped as the asked index")
    func substitutesNearestPayloadWhenReadFails() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 1)
        rec.failing = [3000]
        #expect(r.fragment(at: 3) == Data("key1000@3:12.0".utf8))
    }

    @Test("a failed read with nothing cached is nil")
    func nothingToSubstitute() {
        let rec = Recorder()
        rec.failing = [2000]
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.fragment(at: 2) == nil)
    }

    @Test("an index outside the plan is nil and reads nothing", arguments: [-1, 5, 9999])
    func outOfRangeIndexIsNil(index: Int) {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        #expect(r.fragment(at: index) == nil)
        #expect(rec.reads.isEmpty)
    }

    @Test("the link wait runs before a source read and not before a cache hit")
    func waitsOnlyBeforeReads() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 0)
        _ = r.fragment(at: 0)
        #expect(rec.waits == 1)
    }

    @Test("after shutdown every call is nil, the reader is interrupted and closed exactly once")
    func answersNilAfterShutdown() {
        let rec = Recorder()
        let (r, dir) = make(rec); defer { try? FileManager.default.removeItem(at: dir) }
        _ = r.fragment(at: 0)
        r.shutdown()
        r.shutdown()
        #expect(r.fragment(at: 1) == nil)
        #expect(r.initSegment() == nil)
        #expect(rec.reads == [0])
        #expect(rec.interrupted == 1)
        #expect(rec.closed == 1)
    }

    @Test("concurrent requests are served one at a time and all complete")
    func concurrentRequests() async {
        let rec = Recorder()
        let (r, dir) = make(rec, count: 40); defer { r.shutdown(); try? FileManager.default.removeItem(at: dir) }
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<40 { group.addTask { r.fragment(at: i) != nil } }
            for await ok in group { #expect(ok) }
        }
        #expect(Set(rec.reads).count == 40)
    }
}
