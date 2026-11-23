// What a relay's media bodies took to arrive, counted only while bytes were arriving. A host reads it
// as the rate of the link, so the time an origin spends producing a segment before its first byte
// (an encoder slower than real time, a source read, a node starting) must never count as link time.
import Foundation
import Testing

@testable import AetherEngine

@Suite("Relay media transfer timing")
struct RelayTransferMeterTests {

    /// A clock the test moves by hand, in milliseconds.
    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var ms: Int64 = 0
        var now: Int64 {
            lock.lock(); defer { lock.unlock() }
            return ms
        }
        func set(_ value: Int64) {
            lock.lock(); ms = value; lock.unlock()
        }
    }

    private static let chunk = 64 * 1024

    private func receive(_ meter: RelayTransferMeter, _ transfer: RelayTransferMeter.Transfer,
                         at ms: Int64, clock: ManualClock, bytes: Int = chunk) {
        clock.set(ms)
        meter.received(bytes, on: transfer)
    }

    @Test("Segments that arrive in fast bursts after long waits for the origin count no link time")
    func burstsAfterServerWaitsCountNothing() {
        // The Silo server answers a transcode segment only once the encoder has written all of it, so
        // a slow encode is a silent request followed by a body at the link's full rate. Each body
        // arrives in well under the 1 s minimum, so none of them is a sample of the link.
        let clock = ManualClock()
        let meter = RelayTransferMeter(clock: { clock.now })
        for segment in 0..<6 {
            let transfer = meter.begin()
            let firstByte = Int64(segment) * 6_000 + 5_500
            for slice in 0..<16 {
                receive(meter, transfer, at: firstByte + Int64(slice) * 10, clock: clock)
            }
        }
        #expect(meter.totals == .init(bytes: 0, receivingMs: 0))
    }

    @Test("A body that keeps arriving for a second or more is counted from its first byte to its last")
    func slowTransferCounts() {
        let clock = ManualClock()
        let meter = RelayTransferMeter(clock: { clock.now })
        let transfer = meter.begin()
        receive(meter, transfer, at: 10_000, clock: clock)
        receive(meter, transfer, at: 10_600, clock: clock)
        #expect(meter.totals == .init(bytes: 0, receivingMs: 0), "under a second is no sample yet")
        receive(meter, transfer, at: 11_200, clock: clock)
        // The bytes of the first chunk arrived before anything timed them, as Android's
        // PlaybackThroughputMeter counts it.
        #expect(meter.totals == .init(bytes: Int64(2 * Self.chunk), receivingMs: 1_200))
        receive(meter, transfer, at: 12_000, clock: clock)
        #expect(meter.totals == .init(bytes: Int64(3 * Self.chunk), receivingMs: 2_000))
    }

    @Test("Time in which two bodies were arriving at once counts once")
    func overlapCountsOnce() {
        let clock = ManualClock()
        let meter = RelayTransferMeter(clock: { clock.now })
        let video = meter.begin()
        let audio = meter.begin()
        receive(meter, video, at: 0, clock: clock)
        receive(meter, audio, at: 500, clock: clock)
        receive(meter, video, at: 1_000, clock: clock)
        receive(meter, audio, at: 1_500, clock: clock)
        receive(meter, video, at: 2_000, clock: clock)
        receive(meter, audio, at: 2_500, clock: clock)
        #expect(meter.totals == .init(bytes: Int64(4 * Self.chunk), receivingMs: 2_500))
    }

    @Test("A short body between long ones adds nothing, and a later long one still counts")
    func shortBodyBetweenLongOnes() {
        let clock = ManualClock()
        let meter = RelayTransferMeter(clock: { clock.now })
        let first = meter.begin()
        receive(meter, first, at: 0, clock: clock)
        receive(meter, first, at: 1_000, clock: clock)
        let short = meter.begin()
        receive(meter, short, at: 4_000, clock: clock)
        receive(meter, short, at: 4_900, clock: clock)
        let last = meter.begin()
        receive(meter, last, at: 9_000, clock: clock)
        receive(meter, last, at: 10_500, clock: clock)
        #expect(meter.totals == .init(bytes: Int64(2 * Self.chunk), receivingMs: 2_500))
    }

    @Test("Only a media body is timed: a playlist or subtitle rendition is not, whatever type it is served as",
          arguments: [
              ("https://o/v/seg1.m4s", 200, "video/mp4", true),
              ("https://o/v/seg1.ts", 200, "video/mp2t; charset=binary", true),
              ("https://o/a/seg1.aac", 200, "audio/aac", true),
              ("https://o/v/seg1.m4s", 200, nil, true),
              ("https://o/v/init.mp4", 200, "application/mp4", true),
              ("https://o/v/seg1.m4s", 404, "video/mp4", false),
              ("https://o/v/main.m3u8", 200, "application/vnd.apple.mpegurl", false),
              // A long VOD playlist arriving over a second must not read as a sample of the link.
              ("https://o/v/main.m3u8", 200, "audio/mpegurl", false),
              ("https://o/v/main.m3u8", 200, "application/octet-stream", false),
              ("https://o/v/main", 200, "audio/x-mpegurl", false),
              // A server extracting a subtitle track streams it for as long as the extract takes.
              ("https://o/s/seg1.vtt", 200, "text/vtt", false),
              ("https://o/s/seg1.vtt", 200, "application/octet-stream", false),
              ("https://o/s/seg1.webvtt", 200, nil, false),
          ] as [(String, Int, String?, Bool)])
    func timesOnlyMediaBodies(url: String, status: Int, contentType: String?, timed: Bool) throws {
        let url = try #require(URL(string: url))
        #expect(RelayTransferMeter.timesBody(url: url, status: status, contentType: contentType) == timed)
    }
}
