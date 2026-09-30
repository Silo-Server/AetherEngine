import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit DEC-106, the DVR ring's audio path. `seekLiveDVR` flushes the audio output and only then moves
/// the ring cursor, so the feeder or the look-ahead pump can be holding a packet read at the old cursor.
/// Its decoded buffers used to be enqueued unconditionally, and after a rewind a buffer from before the
/// seek carries a HIGHER stamp than the new clock: it parks at the head of the fresh queue and mutes the
/// audio for the length of the rewind.
@Suite("DVR ring audio follows the flush epoch (DEC-106)")
struct RingAudioFlushEpochTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000, channels = 2
        let pcm = Data(count: Int(Double(sampleRate) * seconds) * channels * 2)
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    @Test("a ring audio packet decided on before a flush yields no buffer after it, one decided after does")
    func ringPacketsFollowTheEpoch() throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 4)))
        defer { demuxer.close() }
        let audioIndex = demuxer.audioStreamIndex
        let stream = try #require(demuxer.stream(at: audioIndex))
        let decoder = AudioDecoder()
        try decoder.open(stream: stream)
        defer { decoder.close() }

        var packets: [PacketRingBuffer.Packet] = []
        while let pkt = try demuxer.readPacket() {
            if pkt.pointee.stream_index == audioIndex, let data = pkt.pointee.data {
                packets.append(PacketRingBuffer.Packet(
                    pts: Double(packets.count) * 1024.0 / 48_000.0, isKeyframe: true, isVideo: false,
                    bytes: Data(bytes: data, count: Int(pkt.pointee.size))))
            }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        try #require(packets.count >= 40)

        let output = AudioOutput()
        let tapped = Counter()
        func feed(_ packet: PacketRingBuffer.Packet, epoch: UInt64) -> Bool {
            SoftwarePlaybackHost.feedRingPacket(
                packet,
                videoDecoder: SoftwareVideoDecoder(),
                audioDecoder: decoder,
                audioOutput: output,
                videoStreamIndex: 0,
                audioStreamIndex: audioIndex,
                videoTimeBaseSeconds: 1.0 / 90_000.0,
                audioTimeBaseSeconds: 1.0 / 48_000.0,
                audioTapSink: { _ in tapped.increment() },
                audioEpoch: epoch,
                noteDecodeGeneration: {})
        }

        let stale = output.epoch
        output.flush()
        let half = packets.count / 2
        let staleProduced = packets[..<half].map { feed($0, epoch: stale) }
        #expect(!staleProduced.contains(true), "the rewind's flush retired these")
        #expect(tapped.value == 0, "a refused buffer is not mirrored to the tap either")

        let freshProduced = packets[half...].map { feed($0, epoch: output.epoch) }
        #expect(freshProduced.contains(true), "an epoch read after the flush is honoured")
        #expect(tapped.value > 0)
    }
}
