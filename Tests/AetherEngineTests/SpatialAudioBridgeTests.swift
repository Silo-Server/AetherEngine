import Testing
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// The spatial bridge turns TrueHD Atmos into APAC for the fMP4 muxer. What it must get right
/// beyond the audio itself is time: its packets land in segments by PTS, so the first packet after
/// a load or a seek has to sit where the source says, however much the decoder skipped to find a
/// major sync, and nothing after it may drift. These drive the bridge with a synthetic decoder
/// that behaves like the real one on exactly those points.
@Suite("TrueHD Atmos spatial bridge")
struct SpatialAudioBridgeTests {

    /// Stand-in object decoder: one pushed byte is one 40-frame access unit (TrueHD's 1/1200 s),
    /// the first `skipAfterReset` access units after a reset are discarded as a real decoder does
    /// while it looks for a major sync, and `dropAt` discards a run mid-stream like a corrupt span.
    final class SyntheticDecoder: ObjectAudioDecoding {
        let framesPerAU = 40
        var skipAfterReset: Int
        var dropAt: (push: Int, count: Int)?
        private var pushes = 0
        private var skipped = 0
        private var inputFrames: Int64 = 0
        private var blocks: [(offset: Int64, frames: Int)] = []
        private let planes: [UnsafeMutablePointer<Float>] = (0..<3).map { _ in .allocate(capacity: 1 << 16) }
        private var t = 0

        init(skipAfterReset: Int, dropAt: (push: Int, count: Int)? = nil) {
            self.skipAfterReset = skipAfterReset
            self.dropAt = dropAt
        }
        deinit { planes.forEach { $0.deallocate() } }

        func push(_ bytes: UnsafeRawBufferPointer) throws {
            pushes += 1
            var start: Int64?
            var frames = 0
            var toDrop = (dropAt?.push == pushes) ? dropAt!.count : 0
            for _ in 0..<bytes.count {
                defer { inputFrames += Int64(framesPerAU) }
                if skipped < skipAfterReset { skipped += 1; continue }
                if toDrop > 0 {
                    toDrop -= 1
                    if frames > 0 { blocks.append((start!, frames)); start = nil; frames = 0 }
                    continue
                }
                if start == nil { start = inputFrames }
                frames += framesPerAU
            }
            if let start, frames > 0 { blocks.append((start, frames)) }
        }

        func nextBlock() throws -> ObjectAudioDecodedBlock? {
            guard !blocks.isEmpty else { return nil }
            let b = blocks.removeFirst()
            for i in 0..<b.frames {
                let v = 0.1 * sinf(Float(t + i) * 0.05)
                planes[0][i] = v; planes[1][i] = v * 0.5; planes[2][i] = v
            }
            t += b.frames
            let x = Float(t % 48_000) / 48_000
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000, frameCount: b.frames, inputFrameOffset: b.offset,
                configurationGeneration: 0, roles: [.bed(.left), .lfe, .object],
                planes: planes.map { UnsafePointer($0) },
                updates: [.init(frameOffset: 0, rampFrames: b.frames,
                                states: [.init(), .init(), .init(position: SIMD3(x, 0.5, 1))])])
        }

        func reset() { skipped = 0; inputFrames = 0; blocks = []; pushes = 0 }
    }

    /// Feed `count` 20 ms packets (24 access units) starting at `startMs` on a 1/1000 time base.
    private func feed(
        _ bridge: some AudioTranscodingBridge, startMs: Int64, count: Int
    ) throws -> [(pts: Int64, key: Bool, size: Int32)] {
        var out: [(Int64, Bool, Int32)] = []
        var payload = [UInt8](repeating: 0, count: 24)
        for i in 0..<count {
            guard let pkt = av_packet_alloc() else { continue }
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            payload.withUnsafeMutableBytes { raw in
                _ = av_new_packet(pkt, 24)
                pkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 24)
            }
            pkt.pointee.pts = startMs + Int64(i) * 20
            pkt.pointee.dts = pkt.pointee.pts
            for fp in try bridge.feed(packet: pkt) {
                out.append((fp.pointee.pts, fp.pointee.flags & AV_PKT_FLAG_KEY != 0, fp.pointee.size))
                var p: UnsafeMutablePointer<AVPacket>? = fp
                trackedPacketFree(&p)
            }
        }
        return out
    }

    @Test("only TrueHD that FFmpeg marks Atmos, at 48 kHz or not yet known, is rendered")
    func eligibility() {
        let on = ObjectAudioRendering.apac(.l714)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 48_000) == .l714)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 0) == .l714)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 0, sampleRate: 48_000) == nil,
                "TrueHD without Atmos keeps its lossless 7.1")
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 96_000) == nil)
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: on, codecID: AV_CODEC_ID_EAC3, profile: 30, sampleRate: 48_000) == nil,
                "E-AC-3 JOC is already Atmos and stream-copies")
        #expect(HLSVideoEngine.spatialRenderingLayout(rendering: .off, codecID: AV_CODEC_ID_TRUEHD, profile: 30, sampleRate: 48_000) == nil)
    }

    @Test("the first packet sits at the source position of the first decodable frame, and steps by 1024")
    func anchorsOnSource() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 5))
        defer { bridge.close() }
        var packets = try feed(bridge, startMs: 1000, count: 100)
        packets += bridge.flush().map { fp in
            defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
            return (fp.pointee.pts, fp.pointee.flags & AV_PKT_FLAG_KEY != 0, fp.pointee.size)
        }
        // 1000 ms = 48000 frames, plus five skipped 40-frame access units.
        #expect(packets.first?.pts == Int64(48_200))
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == 1024 })
        #expect(packets.allSatisfy { $0.key && $0.size > 0 })
        // 96000 frames in, 200 of them skipped; the encoder's priming packets are dropped and the
        // flush pads the last partial packet.
        #expect(packets.count == Int((Double(96_000 - 200) / 1024).rounded(.up)))
        #expect(bridge.feedStats.packetsEmitted == packets.count)
    }

    @Test("a producer restart re-anchors on the new position")
    func restartReanchors() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l916,
            decoder: SyntheticDecoder(skipAfterReset: 3))
        defer { bridge.close() }
        _ = try feed(bridge, startMs: 0, count: 30)
        bridge.startSegment()
        let packets = try feed(bridge, startMs: 5000, count: 30)
        #expect(packets.first?.pts == Int64(240_120))
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == 1024 })
    }

    @Test("a span the decoder drops is filled, so everything after it keeps its timestamp")
    func gapKeepsTimeline() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 0, dropAt: (push: 10, count: 12)))
        defer { bridge.close() }
        var packets = try feed(bridge, startMs: 0, count: 100)
        packets += bridge.flush().map { fp in
            defer { var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p) }
            return (fp.pointee.pts, true, fp.pointee.size)
        }
        #expect(packets.first?.pts == Int64(0))
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == 1024 })
        // 100 packets x 960 frames in, the dropped 480 included as silence: the tail reaches the end.
        let end = packets.last!.pts + 1024
        #expect(end >= 96_000 && end < 96_000 + 1024)
    }

    @Test("movenc muxes the stand-in and the init segment carries the real apac entry")
    func muxedInitCarriesAPAC() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 0))
        defer { bridge.close() }

        let videoDemuxer = Demuxer()
        defer { videoDemuxer.close() }
        try videoDemuxer.open(
            reader: DataIOReader(data: Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                            options: .ignoreUnknownCharacters)!),
            formatHint: "mp4")
        let vStream = try #require(videoDemuxer.stream(at: videoDemuxer.videoStreamIndex))
        let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        var initBytes: Data?
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0, sessionDir: sessionDir,
            video: .init(codecpar: UnsafePointer(vStream.pointee.codecpar), timeBase: vStream.pointee.time_base,
                         codecTagOverride: nil),
            audio: .init(codecpar: UnsafePointer(bridge.encoderCodecpar!), timeBase: bridge.encoderTimeBase,
                         soundSampleEntryOverride: bridge.soundSampleEntryOverride),
            onInitCaptured: { initBytes = $0 })

        while let pkt = try videoDemuxer.readPacket() {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&p) }
            guard pkt.pointee.stream_index == videoDemuxer.videoStreamIndex else { continue }
            pkt.pointee.stream_index = muxer.videoOutputStreamIndex
            av_packet_rescale_ts(pkt, vStream.pointee.time_base, muxer.muxerVideoTimeBase)
            _ = muxer.writePacket(pkt)
        }
        var payload = [UInt8](repeating: 0, count: 24)
        for i in 0..<50 {
            let pkt = av_packet_alloc()!
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            payload.withUnsafeMutableBytes { raw in
                _ = av_new_packet(pkt, 24)
                pkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 24)
            }
            pkt.pointee.pts = Int64(i) * 20
            for fp in try bridge.feed(packet: pkt) + (i == 49 ? bridge.flush() : []) {
                var p: UnsafeMutablePointer<AVPacket>? = fp
                defer { trackedPacketFree(&p) }
                fp.pointee.stream_index = muxer.audioOutputStreamIndex
                av_packet_rescale_ts(fp, bridge.encoderTimeBase, muxer.muxerAudioTimeBase)
                #expect(muxer.writePacket(fp).rc >= 0)
            }
        }
        guard case .completed = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("the stand-in needs no parsed packet, so the cut completes")
            return
        }
        let bytes = try #require(initBytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        #expect(hex.contains("61706163"), "apac sample entry present")
        #expect(hex.contains("64617061"), "dapa configuration present")
        #expect(!hex.contains("616c6163"), "no alac left behind")
        #expect(bytes.range(of: bridge.soundSampleEntryOverride!) != nil)

        if let dump = ProcessInfo.processInfo.environment["AE_SPATIAL_DUMP_DIR"] {
            let dir = URL(fileURLWithPath: dump)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: dir.appendingPathComponent("init.mp4"))
            let seg = try FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)
            for file in seg { try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent)) }
        }
    }
}
