import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// #220 (rrgomes): `SoftwareVideoDecoder.decode` returned on any negative `avcodec_send_packet`
/// result without draining the receive loop. `AVERROR(EAGAIN)` is not an error there: it means
/// the packet was NOT consumed because the decoder's output queue is full and has to be read
/// first, which is legal at any time under frame threading. Returning both dropped the packet
/// and left the queue full, so every subsequent send hit the same wall and video wedged
/// permanently until a seek flushed the decoder, while audio kept playing.
///
/// The wedge state itself is only reachable through decoder-internal threading, so it is the
/// disposition rule that is pinned here, plus a real decode over a fixture proving the split
/// into send + `drainDecodedFrames` sustains one output frame per input packet once warm.
struct Issue220SoftwareDecoderDrainTests {

    // MARK: - Send disposition

    @Test("a taken packet needs no retry")
    func acceptedPacket() {
        #expect(SoftwareVideoDecoder.disposition(forSendResult: 0) == .accepted)
    }

    /// The defect in one line: EAGAIN used to be handled as `ret < 0`, i.e. as a dropped packet.
    @Test("EAGAIN drains and retries rather than dropping the packet")
    func eagainRetries() {
        #expect(SoftwareVideoDecoder.disposition(forSendResult: FFmpegErr.eagain) == .drainAndRetry)
    }

    @Test("a real decode error drops the packet")
    func hardErrorDrops() {
        #expect(SoftwareVideoDecoder.disposition(forSendResult: FFmpegErr.invalidData) == .dropped)
        #expect(SoftwareVideoDecoder.disposition(forSendResult: FFmpegErr.einval) == .dropped)
        #expect(SoftwareVideoDecoder.disposition(forSendResult: FFmpegErr.eof) == .dropped)
    }

    // MARK: - Real decode

    /// Regression guard for the send/drain split: IDR+P packets, no B-frames. Frame threading
    /// delays output by the thread pipeline depth, which scales with the host processor count.
    /// Warm that pipeline before measuring another full pass, without flushing the decoder.
    @Test("a warmed progressive decoder keeps producing one frame per packet (#220)")
    func decodesFixtureFrames() throws {
        let data = try #require(Data(base64Encoded: Self.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }

        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let counter = FrameCounter()
        let decoder = SoftwareVideoDecoder()
        try decoder.open(stream: stream) { _, _, _ in counter.increment() }
        defer { decoder.close() }

        let packetsPerPass = 40
        let warmupPasses = (ProcessInfo.processInfo.activeProcessorCount + packetsPerPass - 1)
            / packetsPerPass
        let passDuration = av_rescale_q(4, AVRational(num: 1, den: 1), stream.pointee.time_base)
        for pass in 0...warmupPasses {
            if pass > 0 { try #require(demuxer.seek(to: 0)) }
            let framesBeforePass = counter.value
            var packets = 0
            while let pkt = try demuxer.readPacket() {
                var ownedPacket: UnsafeMutablePointer<AVPacket>? = pkt
                defer { trackedPacketFree(&ownedPacket) }
                if pkt.pointee.stream_index == videoIndex {
                    packets += 1
                    // Each pass begins at an IDR. Keep its timestamps continuous across replays
                    // while leaving the decoder's in-flight frames intact.
                    pkt.pointee.pts += Int64(pass) * passDuration
                    pkt.pointee.dts += Int64(pass) * passDuration
                    decoder.decode(packet: pkt)
                }
            }
            try #require(packets == packetsPerPass)
            if pass == warmupPasses {
                #expect(counter.value - framesBeforePass == packetsPerPass,
                        "a warmed decoder must keep up with every new packet")
            }
        }
    }

    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// 128x96 h264, 4 s at 10 fps, `-bf 0 -tune zerolatency -x264-params keyint=10`. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=red:s=128x96:r=10:d=4" -c:v libx264 -preset ultrafast \
    ///     -tune zerolatency -bf 0 -pix_fmt yuv420p -x264-params keyint=10 -movflags +faststart swdec.mp4
    ///   base64 -i swdec.mp4
    private static let fixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAPPbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAD6AAAQAA
        AQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAgAAAvl0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAA
        AAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAIAAAABgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAA+gAAAAAAABAAAAAAJx
        bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAoABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRl
        b0hhbmRsZXIAAAACHG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAA
        AQAAAdxzdGJsAAAAuHN0c2QAAAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAIAAYABIAAAASAAAAAAA
        AAABFUxhdmM2Mi4yOC4xMDEgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAK/+EAF2dCwAraCDbARAAAAwAEAAAD
        AFI8SJqAAQAEaM4PyAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAAliAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAoAAAE
        AAAAACBzdHNzAAAAAAAAAAQAAAABAAAACwAAABUAAAAfAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAoAAAAAQAAALRzdHN6AAAA
        AAAAAAAAAAAoAAACkgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAD0AAAAKAAAACgAAAAoAAAAKAAAA
        CgAAAAoAAAAKAAAACgAAAAoAAAA9AAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAAPQAAAAoAAAAKAAAA
        CgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAABRzdGNvAAAAAAAAAAEAAAP/AAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRs
        cgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDEA
        AAAIZnJlZQAABLltZGF0AAACUgYF//9O3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0g
        SC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gy
        NjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9
        MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4
        eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBs
        b29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlf
        Y29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0xMCBrZXlpbnRfbWluPTEg
        c2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBx
        cG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAADhliIQ6EYoAAhjxwABA9jgACHlJycnJycnJ11111111
        111111111111111111111111111111114AAAAAZBmiA+gYwAAAAGQZpAPoGMAAAABkGaYBCgYwAAAAZBmoAQoGMAAAAGQZqg
        EKBjAAAABkGawBCgYwAAAAZBmuAQoGMAAAAGQZsAEKBjAAAABkGbIBCgYwAAADlliIIBGhGKAAKSMcAARwY4AAq5ScnJycnJ
        yddddddddddddddddddddddddddddddddddddddddeAAAAAGQZogPoGMAAAABkGaQD6BjAAAAAZBmmAQoGMAAAAGQZqAEKBj
        AAAABkGaoBCgYwAAAAZBmsAQoGMAAAAGQZrgEKBjAAAABkGbABCgYwAAAAZBmyAQoGMAAAA5ZYiEBKhGKAAKi8cAAR9Y4AAs
        IScnJycnJyddddddddddddddddddddddddddddddddddddddddeAAAAABkGaID6BjAAAAAZBmkA+gYwAAAAGQZpgEKBjAAAA
        BkGagBCgYwAAAAZBmqAQoGMAAAAGQZrAEKBjAAAABkGa4BCgYwAAAAZBmwAQoGMAAAAGQZsgEKBjAAAAOWWIggEqEYoAAqLx
        wABH1jgACwhJycnJycnJ11111111111111111111111111111111111111114AAAAAZBmiA+gYwAAAAGQZpAPoGMAAAABkGa
        YBCgYwAAAAZBmoAQoGMAAAAGQZqgEKBjAAAABkGawBCgYwAAAAZBmuAQoGMAAAAGQZsAEKBjAAAABkGbIBCgYw==
        """
}
