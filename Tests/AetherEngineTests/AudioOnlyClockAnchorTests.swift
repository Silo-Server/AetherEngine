import Testing
import Foundation
import CoreMedia
@testable import AetherEngine

/// Audit DEC-102: the audio-only FFmpeg host anchored its clock at the load position and ignored the
/// first sample's timestamp. A source whose timestamps start far past that (an Ogg radio stream's granule
/// position, an audio-only TS that joined mid-broadcast) then stamped every buffer hours ahead of a clock
/// that started at 0, the back-pressure gate parked the loop against the gap, and the session played
/// silence. The software video host resolved the same question with `SWClockAnchorPolicy`; this host now
/// shares it.
@Suite("Audio-only clock anchor (DEC-102)", .serialized)
struct AudioOnlyClockAnchorTests {

    // MARK: - The decision

    @Test("a first sample an hour past the load anchor moves the anchor and records the session zero")
    func farFirstSampleAnchorsAtTheSample() {
        let first = CMTime(seconds: 3600, preferredTimescale: 90000)
        let resolved = AudioPlaybackHost.clockAnchor(initialClockTime: .zero, firstPTS: first)
        #expect(resolved.anchor.seconds == 3600)
        #expect(resolved.sessionZeroSeconds == 3600)
        #expect(AudioPlaybackHost.publishedTime(raw: 3600, sessionZeroSeconds: resolved.sessionZeroSeconds) == 0)
        #expect(AudioPlaybackHost.publishedTime(raw: 3612.5, sessionZeroSeconds: resolved.sessionZeroSeconds) == 12.5)
    }

    @Test("a resume whose first sample is where it was asked to be keeps the load anchor verbatim")
    func alignedResumeKeepsTheAnchor() {
        let initial = CMTime(seconds: 1000, preferredTimescale: 90000)
        let resolved = AudioPlaybackHost.clockAnchor(
            initialClockTime: initial, firstPTS: CMTime(seconds: 1000.4, preferredTimescale: 90000))
        #expect(resolved.anchor == initial)
        #expect(resolved.sessionZeroSeconds == 0)
        #expect(AudioPlaybackHost.publishedTime(raw: 1003, sessionZeroSeconds: 0) == 1003)
    }

    @Test("an invalid first timestamp keeps the load anchor")
    func invalidFirstSampleKeepsTheAnchor() {
        let resolved = AudioPlaybackHost.clockAnchor(initialClockTime: .zero, firstPTS: .invalid)
        #expect(resolved.anchor == .zero)
        #expect(resolved.sessionZeroSeconds == 0)
    }

    @Test("a seek target on the published axis round-trips through the source axis")
    func seekTargetRoundTrips() {
        let zero = 3600.0
        let source = SWClockAnchorPolicy.sourceSeconds(forSession: 42, sessionZeroSeconds: zero)
        #expect(source == 3642)
        #expect(AudioPlaybackHost.publishedTime(raw: source, sessionZeroSeconds: zero) == 42)
    }

    // MARK: - End to end, on a real demuxer

    @MainActor
    @Test("an audio-only TS that starts an hour in is anchored at its first sample, and seeks stay on its axis")
    func hourOffsetTransportStream() async throws {
        let stream = Self.makeMP2TransportStream(startPTSSeconds: 3600, frames: 200)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: stream), formatHint: "mpegts")
        let host = AudioPlaybackHost()
        try await host.load(demuxer: demuxer, startPosition: nil, audioSourceStreamIndex: nil)
        defer { host.stop() }

        host.play()
        try await waitFor { host.isClockArmedForTesting }

        #expect(abs(host.sessionZeroForTesting - 3600) < 1, "zero \(host.sessionZeroForTesting)")
        let clock = try #require(host.clockSecondsForTesting)
        #expect(clock >= 3599 && clock < 3700, "the clock has to sit where the samples are, not at 0: \(clock)")

        await host.seek(to: 1.0)
        let seeked = try #require(host.clockSecondsForTesting)
        #expect(abs(seeked - 3601) < 2, "a seek to 1.0 s of the published axis is 3601 s of the source: \(seeked)")
        #expect(host.currentTime == 1.0)
    }

    // MARK: - Fixture: MPEG-1 Layer II in MPEG-TS

    /// `frames` silent 48 kHz mono Layer II frames (24 ms each, zero allocation bits decode to silence),
    /// one PES packet each, the first stamped at `startPTSSeconds`. No PCR: the demuxer takes audio
    /// timestamps from the PES headers.
    private static func makeMP2TransportStream(startPTSSeconds: Double, frames: Int) -> Data {
        let pmtPID: UInt16 = 0x1000, audioPID: UInt16 = 0x0100
        var counters: [UInt16: UInt8] = [:]
        var out = Data()

        var pat = Data([0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01])
        pat.append(contentsOf: [UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)])
        out.append(psi(pid: 0, section: section(tableID: 0x00, body: pat), counters: &counters))

        var pmt = Data([0x00, 0x01, 0xC1, 0x00, 0x00])
        pmt.append(contentsOf: [UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF), 0xF0, 0x00])
        pmt.append(contentsOf: [0x03, UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF), 0xF0, 0x00])
        out.append(psi(pid: pmtPID, section: section(tableID: 0x02, body: pmt), counters: &counters))

        var frame = Data(count: 192)
        frame.replaceSubrange(0..<4, with: [0xFF, 0xFD, 0x44, 0xC0])
        let startTicks = Int64(startPTSSeconds * 90_000)
        for i in 0..<frames {
            let pts = startTicks + Int64(i) * 2160   // 24 ms
            out.append(pes(pid: audioPID, payload: frame, pts: pts, counters: &counters))
        }
        return out
    }

    private static func section(tableID: UInt8, body: Data) -> Data {
        let length = body.count + 4
        var s = Data([tableID, UInt8(0xB0 | ((length >> 8) & 0x0F)), UInt8(length & 0xFF)])
        s.append(body)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in s {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        for shift in stride(from: 24, through: 0, by: -8) { s.append(UInt8((crc >> UInt32(shift)) & 0xFF)) }
        return s
    }

    private static func psi(pid: UInt16, section: Data, counters: inout [UInt16: UInt8]) -> Data {
        var payload = Data([0x00])
        payload.append(section)
        payload.append(contentsOf: [UInt8](repeating: 0xFF, count: 184 - payload.count))
        return packet(pid: pid, pusi: true, payload: payload, counters: &counters)
    }

    private static func pes(pid: UInt16, payload: Data, pts: Int64, counters: inout [UInt16: UInt8]) -> Data {
        var packetData = Data([0x00, 0x00, 0x01, 0xC0])
        let length = 3 + 5 + payload.count
        packetData.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF), 0x80, 0x80, 0x05])
        packetData.append(contentsOf: [
            UInt8(0x21 | ((pts >> 29) & 0x0E)),
            UInt8((pts >> 22) & 0xFF),
            UInt8(0x01 | ((pts >> 14) & 0xFE)),
            UInt8((pts >> 7) & 0xFF),
            UInt8(0x01 | ((pts << 1) & 0xFE)),
        ])
        packetData.append(payload)
        var out = Data()
        var offset = 0
        var first = true
        while offset < packetData.count {
            let take = min(184, packetData.count - offset)
            out.append(packet(pid: pid, pusi: first, payload: packetData.subdata(in: offset..<(offset + take)),
                              counters: &counters))
            offset += take
            first = false
        }
        return out
    }

    private static func packet(pid: UInt16, pusi: Bool, payload: Data, counters: inout [UInt16: UInt8]) -> Data {
        let counter = counters[pid, default: 0]
        var p = Data([0x47, UInt8((pusi ? 0x40 : 0x00) | Int(pid >> 8)), UInt8(pid & 0xFF)])
        let stuffing = 184 - payload.count
        if stuffing == 0 {
            p.append(0x10 | counter)
        } else {
            p.append(0x30 | counter)
            p.append(UInt8(stuffing - 1))
            if stuffing >= 2 {
                p.append(0x00)
                p.append(contentsOf: [UInt8](repeating: 0xFF, count: stuffing - 2))
            }
        }
        p.append(payload)
        counters[pid] = (counter &+ 1) & 0x0F
        return p
    }
}
