import Testing
import Foundation
import AVFoundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// The spatial bridge turns TrueHD Atmos into APAC for the fMP4 muxer. What it must get right
/// beyond the audio itself is time: its packets land in segments by PTS, so the first packet after
/// a load or a seek has to sit where the source says, however much the decoder skipped to find a
/// major sync, and nothing after it may drift. Packets are stamped the way AVFoundation reads APAC,
/// with the encoder's 2048 frames of priming counted in, so the first packet takes the anchor and
/// the first content frame plays there. These drive the bridge with a synthetic decoder that
/// behaves like the real one on exactly those points.
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

    /// Stand-in decoder with something to find: one pushed byte is one 40-frame access unit,
    /// contiguous from the first push, and the left bed channel carries a 3 ms 1 kHz burst
    /// starting at input frame `clickFrame`.
    final class ClickDecoder: ObjectAudioDecoding {
        let clickFrame: Int64
        private var inputFrames: Int64 = 0
        private var blocks: [(offset: Int64, frames: Int)] = []
        private var stateSent = false
        private let plane = UnsafeMutablePointer<Float>.allocate(capacity: 1 << 16)

        init(clickFrame: Int64) { self.clickFrame = clickFrame }
        deinit { plane.deallocate() }

        func push(_ bytes: UnsafeRawBufferPointer) throws {
            blocks.append((inputFrames, bytes.count * 40))
            inputFrames += Int64(bytes.count * 40)
        }

        func nextBlock() throws -> ObjectAudioDecodedBlock? {
            guard !blocks.isEmpty else { return nil }
            let b = blocks.removeFirst()
            for i in 0..<b.frames {
                let d = b.offset + Int64(i) - clickFrame
                plane[i] = (0..<144).contains(d) ? 0.8 * sinf(2 * .pi * 1000 * Float(d) / 48_000) : 0
            }
            defer { stateSent = true }
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000, frameCount: b.frames, inputFrameOffset: b.offset,
                configurationGeneration: 0, roles: [.bed(.left)], planes: [UnsafePointer(plane)],
                updates: stateSent ? [] : [.init(frameOffset: 0, rampFrames: 0, states: [.init()])])
        }

        func reset() { inputFrames = 0; blocks = []; stateSent = false }
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
        // 1000 ms = 48000 frames, plus five skipped 40-frame access units. The first packet is the
        // encoder's priming, which AVFoundation presents before its timestamp, so the first content
        // frame plays on the anchor.
        #expect(packets.first?.pts == Int64(48_200))
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.pts - $0.pts == 1024 })
        #expect(packets.allSatisfy { $0.key && $0.size > 0 })
        // 96000 frames in, 200 of them skipped, after two packets of priming; the flush pads the
        // last partial packet.
        #expect(packets.count == 2 + Int((Double(96_000 - 200) / 1024).rounded(.up)))
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
        // 100 packets x 960 frames in, the dropped 480 included as silence: the tail, presented
        // 2048 frames before its timestamp, reaches the end.
        let end = packets.last!.pts + 1024 - 2048
        #expect(end >= 96_000 && end < 96_000 + 1024)
    }

    /// Mux `count` 20 ms source packets from `startMs` through the bridge, next to the probe video
    /// movenc needs, and cut one segment. Returns the init segment, the segment file and the
    /// session directory it sits in (the caller removes it).
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func muxWithProbeVideo(
        _ bridge: SpatialAudioBridge, startMs: Int64, count: Int
    ) throws -> (initBytes: Data, segment: URL, sessionDir: URL)? {
        let videoDemuxer = Demuxer()
        defer { videoDemuxer.close() }
        try videoDemuxer.open(
            reader: DataIOReader(data: Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                            options: .ignoreUnknownCharacters)!),
            formatHint: "mp4")
        let vStream = try #require(videoDemuxer.stream(at: videoDemuxer.videoStreamIndex))
        let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

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
        for i in 0..<count {
            let pkt = av_packet_alloc()!
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            payload.withUnsafeMutableBytes { raw in
                _ = av_new_packet(pkt, 24)
                pkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 24)
            }
            pkt.pointee.pts = startMs + Int64(i) * 20
            for fp in try bridge.feed(packet: pkt) + (i == count - 1 ? bridge.flush() : []) {
                var p: UnsafeMutablePointer<AVPacket>? = fp
                defer { trackedPacketFree(&p) }
                fp.pointee.stream_index = muxer.audioOutputStreamIndex
                av_packet_rescale_ts(fp, bridge.encoderTimeBase, muxer.muxerAudioTimeBase)
                #expect(muxer.writePacket(fp).rc >= 0)
            }
        }
        guard case .completed(let segment, _) = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("the stand-in needs no parsed packet, so the cut completes")
            return nil
        }
        return (try #require(initBytes), segment, sessionDir)
    }

    @Test("movenc muxes the stand-in and the init segment carries the real apac entry")
    func muxedInitCarriesAPAC() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SyntheticDecoder(skipAfterReset: 0))
        defer { bridge.close() }
        guard let muxed = try muxWithProbeVideo(bridge, startMs: 0, count: 50) else { return }
        let sessionDir = muxed.sessionDir
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        let bytes = muxed.initBytes
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

    /// The end-to-end form of the timestamp contract: a click at a known source position is
    /// rendered, encoded, muxed and decoded back by AVFoundation, which presents APAC the way
    /// AVPlayer does, and has to come out where the source put it. With the encoder's priming
    /// packets dropped it came out 2048 frames (42.7 ms) early, and so did every session's audio.
    @Test("a click decodes back at its source position through AVFoundation")
    func clickDecodesOnItsSourcePosition() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // The source starts at 0 and the click is 12000 frames in, so it belongs at 0.25 s.
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: ClickDecoder(clickFrame: 12_000))
        defer { bridge.close() }
        guard let muxed = try muxWithProbeVideo(bridge, startMs: 0, count: 30) else { return }
        let sessionDir = muxed.sessionDir
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        let file = sessionDir.appendingPathComponent("joined.mp4")
        try (muxed.initBytes + Data(contentsOf: muxed.segment)).write(to: file)

        let asset = AVURLAsset(url: file)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var onset: Double?
        while onset == nil, let buffer = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = Int(asbd.mChannelsPerFrame)
            let frames = CMSampleBufferGetNumSamples(buffer)
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            var block: CMBlockBuffer?
            var list = AudioBufferList()
            _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
            guard let samples = list.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if let i = (0..<frames).first(where: { abs(samples[$0 * channels]) > 0.2 }) {
                onset = start + Double(i) / 48_000
            }
        }
        let heard = try #require(onset, "the click reaches the left channel")
        #expect(abs(heard - 0.25) < 0.001, "the click decodes at \(heard) s, not at its source position 0.25 s")
    }
}
