import Foundation
import AetherLibavcodec
import AetherLibavutil

/// TrueHD Atmos in, APAC out: decodes the object presentation, renders its beds and objects into a
/// `SpatialSpeakerLayout` bed and encodes that as Apple Positional Audio, which tvOS delivers to an
/// Atmos receiver as Dolby MAT with the heights intact.
///
/// The FLAC bridge keeps TrueHD lossless but can only carry the 7.1 presentation, so every height
/// and every object position is gone before the audio leaves the engine. This bridge trades the
/// lossless bed for the Atmos mix: APAC is lossy, at a few Mbit/s, several times the rate streaming
/// services deliver Atmos at.
///
/// libavformat can neither encode nor mux APAC, so the muxer is handed an ALAC stand-in stream
/// (`encoderCodecpar`) whose sample entry the init segment rewrite replaces with the real one
/// (`soundSampleEntryOverride`). Packets pass through movenc untouched.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class SpatialAudioBridge: AudioTranscodingBridge, @unchecked Sendable {

    static let sampleRate = ObjectAudioRendering.sampleRate

    /// Default encode rate per bed channel. 3.84 Mbit/s for 7.1.4, 5.12 for 9.1.6.
    static let bitRatePerChannel = 320_000

    enum BridgeError: Error, CustomStringConvertible {
        case codecparAllocFailed
        case unsupportedSampleRate(Int)

        var description: String {
            switch self {
            case .codecparAllocFailed: return "SpatialAudioBridge: avcodec_parameters_alloc failed"
            case .unsupportedSampleRate(let r): return "SpatialAudioBridge: object audio at \(r) Hz (48 kHz only)"
            }
        }
    }

    let layout: SpatialSpeakerLayout
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?
    let encoderTimeBase = AVRational(num: 1, den: Int32(SpatialAudioBridge.sampleRate))
    let soundSampleEntryOverride: Data?
    /// HLS `CODECS` value for the track.
    let hlsCodecs: String

    private let srcTimeBase: AVRational
    private let decoder: ObjectAudioDecoding
    private let encoder: APACEncoder
    private var renderer: ObjectAudioRenderer?
    private var rendererGeneration = -1

    /// Rendered bed awaiting the encoder. TrueHD decodes one 40-frame access unit per block, 1200
    /// a second; feeding the converter that often costs more in call overhead than the encode, so
    /// blocks are rendered straight into this buffer and it is encoded `encodeChunkFrames` at a time.
    private var outputPlanes: [UnsafeMutablePointer<Float>] = []
    private var outputCapacity = 0
    private var pendingFrames = 0
    private static let encodeChunkFrames = 2048

    /// Timeline, in 48 kHz frames on the output time base.
    /// `originFrame`: the source PTS of the first packet pushed since the last reset.
    /// `encoderStartFrame`: where the first frame handed to the encoder since the reset sits.
    /// `encoderFramesIn`: frames handed to the encoder since the reset; `packetsOut`: packets it
    /// has returned. Packet k covers frames [k·1024 − leadingFrames, +1024) of encoder input.
    private var originFrame: Int64?
    private var encoderStartFrame: Int64?
    private var encoderFramesIn: Int64 = 0
    private var packetsOut: Int64 = 0
    private var nextExpectedInputOffset: Int64?
    private var drainedAtEOF = false

    private let opLock = NSLock()
    private var stats = AudioBridge.FeedStats()
    private(set) var outputBytesLifetime: Int64 = 0

    private static let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1

    init(
        srcTimeBase: AVRational,
        layout: SpatialSpeakerLayout,
        decoder: ObjectAudioDecoding,
        bitRate: Int? = nil
    ) throws {
        self.srcTimeBase = srcTimeBase
        self.layout = layout
        self.decoder = decoder
        let rate = bitRate ?? layout.channelCount * Self.bitRatePerChannel
        encoder = try APACEncoder(layout: layout, sampleRate: Double(Self.sampleRate), bitRate: rate)
        soundSampleEntryOverride = APACSampleEntry.sampleEntry(
            magicCookie: encoder.magicCookie, sampleRate: Self.sampleRate)
        hlsCodecs = APACSampleEntry.codecsString(channelCount: layout.channelCount)
        guard let cp = Self.makeStandInCodecpar() else { throw BridgeError.codecparAllocFailed }
        encoderCodecpar = cp
        EngineLog.emit(
            "[SpatialAudioBridge] init: layout=\(layout.rawValue) bitRate=\(rate / 1000) kbps "
            + "codecs=\(hlsCodecs) priming=\(encoder.leadingFrames) frames",
            category: .session
        )
    }

    deinit { cleanup() }

    /// ALAC, 2 channels, 48 kHz, 1024-frame packets: a stream movenc writes from parameters alone and
    /// never inspects the packets of. Its sample entry is replaced wholesale, so only the timing
    /// fields matter to anything downstream.
    private static func makeStandInCodecpar() -> UnsafeMutablePointer<AVCodecParameters>? {
        guard let cp = avcodec_parameters_alloc() else { return nil }
        cp.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        cp.pointee.codec_id = AV_CODEC_ID_ALAC
        cp.pointee.sample_rate = Int32(sampleRate)
        cp.pointee.frame_size = Int32(APACEncoder.framesPerPacket)
        cp.pointee.bits_per_raw_sample = 16
        cp.pointee.bits_per_coded_sample = 16
        av_channel_layout_default(&cp.pointee.ch_layout, 2)
        // A well-formed 36-byte ALAC `alac` atom (ALACSpecificConfig), so movenc writes a sane box.
        var cookie: [UInt8] = [0, 0, 0, 36] + Array("alac".utf8) + [0, 0, 0, 0]
        cookie += [0, 0, 4, 0]                  // frameLength 1024
        cookie += [0, 16, 40, 10, 14, 2]        // compatibleVersion, bitDepth, pb, mb, kb, numChannels
        cookie += [0, 255]                      // maxRun
        cookie += [0, 0, 0, 0, 0, 0, 0, 0]      // maxFrameBytes, avgBitRate
        cookie += [0, 0, 0xBB, 0x80]            // sampleRate 48000
        if let extradata = av_mallocz(cookie.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?
            .assumingMemoryBound(to: UInt8.self) {
            extradata.update(from: cookie, count: cookie.count)
            cp.pointee.extradata = extradata
            cp.pointee.extradata_size = Int32(cookie.count)
        }
        return cp
    }

    // MARK: - AudioTranscodingBridge

    var feedStats: AudioBridge.FeedStats { stats }
    var fifoSampleCount: Int { 0 }
    var liveBytes: AudioBridge.LiveBytes {
        AudioBridge.LiveBytes(fifoSamples: 0, fifoBytes: 0, swrDelaySamples: 0, swrDelayBytes: 0)
    }

    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        stats.packetsFed += 1
        stats.packetsFedSinceLastEnqueue += 1

        if originFrame == nil, packet.pointee.pts != Self.avNoPTS {
            originFrame = av_rescale_q(packet.pointee.pts, srcTimeBase, encoderTimeBase)
        }
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        do {
            try decoder.push(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
        } catch {
            stats.packetsRejected += 1
            return []
        }

        var results: [UnsafeMutablePointer<AVPacket>] = []
        do {
            while let block = try decoder.nextBlock() {
                stats.framesDecoded += 1
                try renderAndEncode(block, into: &results)
            }
        } catch {
            stats.decodeErrors += 1
            for p in results { var pp: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&pp) }
            throw error
        }
        return results
    }

    func flush() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard !drainedAtEOF else { return [] }
        drainedAtEOF = true
        var results: [UnsafeMutablePointer<AVPacket>] = []
        try? encodePending(into: &results)
        if let packets = try? encoder.flush() { emit(packets, into: &results) }
        if !results.isEmpty {
            EngineLog.emit("[SpatialAudioBridge] EOF flush emitted \(results.count) tail packet(s)", category: .session)
        }
        return results
    }

    func startSegment() {
        opLock.lock()
        defer { opLock.unlock() }
        decoder.reset()
        renderer?.reset()
        encoder.reset()
        pendingFrames = 0
        originFrame = nil
        encoderStartFrame = nil
        encoderFramesIn = 0
        packetsOut = 0
        nextExpectedInputOffset = nil
        drainedAtEOF = false
    }

    func noteTimelineJump(deltaSeconds: Double) {
        opLock.lock()
        defer { opLock.unlock() }
        guard deltaSeconds > 0, let start = encoderStartFrame else { return }
        encoderStartFrame = start + Int64((deltaSeconds * Double(Self.sampleRate)).rounded())
    }

    func close() {
        opLock.lock()
        defer { opLock.unlock() }
        cleanup()
    }

    private func cleanup() {
        if encoderCodecpar != nil { avcodec_parameters_free(&encoderCodecpar) }
        outputPlanes.forEach { $0.deallocate() }
        outputPlanes = []
        outputCapacity = 0
    }

    // MARK: - Pipeline

    private func renderAndEncode(_ block: ObjectAudioDecodedBlock, into results: inout [UnsafeMutablePointer<AVPacket>]) throws {
        guard block.sampleRate == Self.sampleRate else { throw BridgeError.unsupportedSampleRate(block.sampleRate) }
        guard block.frameCount > 0 else { return }

        if renderer == nil || block.configurationGeneration != rendererGeneration {
            if renderer != nil {
                EngineLog.emit(
                    "[SpatialAudioBridge] object configuration changed (\(block.roles.count) elements), renderer rebuilt",
                    category: .session
                )
            }
            renderer = ObjectAudioRenderer(layout: layout, roles: block.roles)
            rendererGeneration = block.configurationGeneration
        } else if block.isDiscontinuity {
            renderer?.markDiscontinuity()
        }
        // Anchor the encoder on the first block after a reset, and keep the encoder's input
        // contiguous with the source afterwards: a gap the decoder skipped (corrupt access units) is
        // filled with silence so everything after it stays on its timestamp.
        if encoderStartFrame == nil {
            encoderStartFrame = (originFrame ?? 0) + block.inputFrameOffset
        } else if let expected = nextExpectedInputOffset, block.inputFrameOffset > expected {
            let gap = Int(min(block.inputFrameOffset - expected, Int64(Self.sampleRate * 5)))
            try encodeSilence(frames: gap, into: &results)
        }
        nextExpectedInputOffset = block.inputFrameOffset + Int64(block.frameCount)

        ensureOutputCapacity(pendingFrames + block.frameCount)
        renderer!.render(
            inputs: block.planes, frameCount: block.frameCount, updates: block.updates,
            outputs: outputPlanes.map { $0 + pendingFrames })
        pendingFrames += block.frameCount
        stats.samplesEnqueued += Int64(block.frameCount)
        stats.packetsFedSinceLastEnqueue = 0
        if pendingFrames >= Self.encodeChunkFrames { try encodePending(into: &results) }
    }

    private func encodeSilence(frames: Int, into results: inout [UnsafeMutablePointer<AVPacket>]) throws {
        guard frames > 0 else { return }
        ensureOutputCapacity(pendingFrames + frames)
        for plane in outputPlanes { (plane + pendingFrames).update(repeating: 0, count: frames) }
        pendingFrames += frames
        if pendingFrames >= Self.encodeChunkFrames { try encodePending(into: &results) }
    }

    private func encodePending(into results: inout [UnsafeMutablePointer<AVPacket>]) throws {
        guard pendingFrames > 0 else { return }
        let frames = pendingFrames
        pendingFrames = 0
        let packets: [APACEncoder.Packet]
        do {
            packets = try encoder.encode(planes: outputPlanes.map { UnsafePointer($0) }, frameCount: frames)
        } catch {
            // Packet timestamps count packets since the encoder started, so a failed call that
            // swallowed packets would leave every later one stamped early. Start the encoder over
            // past this chunk instead: the chunk becomes a gap and everything after it keeps its
            // source position.
            if let start = encoderStartFrame {
                encoderStartFrame = start + encoderFramesIn + Int64(frames)
            }
            encoder.reset()
            encoderFramesIn = 0
            packetsOut = 0
            stats.encodeErrors += 1
            throw error
        }
        encoderFramesIn += Int64(frames)
        emit(packets, into: &results)
    }

    /// Stamp encoder packets onto the output timeline and wrap them for the muxer. The encoder's
    /// priming packets precede the first input frame; they carry no content and would sit before
    /// the anchor (below zero at the head of the file), so they are dropped. Every APAC packet the
    /// encoder produces is independently decodable, so the first kept packet decodes on its own.
    private func emit(_ packets: [APACEncoder.Packet], into results: inout [UnsafeMutablePointer<AVPacket>]) {
        let frames = Int64(APACEncoder.framesPerPacket)
        let leading = Int64(encoder.leadingFrames)
        for packet in packets {
            let k = packetsOut
            packetsOut += 1
            let contentStart = k * frames - leading
            guard contentStart + frames > 0, let start = encoderStartFrame else { continue }
            guard let avpkt = trackedPacketAlloc() else { continue }
            guard av_new_packet(avpkt, Int32(packet.data.count)) >= 0 else {
                var p: UnsafeMutablePointer<AVPacket>? = avpkt
                trackedPacketFree(&p)
                continue
            }
            packet.data.withUnsafeBytes { raw in
                avpkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: packet.data.count)
            }
            let pts = start + max(contentStart, 0)
            avpkt.pointee.pts = pts
            avpkt.pointee.dts = pts
            avpkt.pointee.duration = frames
            if packet.isSync { avpkt.pointee.flags |= AV_PKT_FLAG_KEY }
            outputBytesLifetime += Int64(packet.data.count)
            stats.packetsEmitted += 1
            results.append(avpkt)
        }
    }

    /// Grow the planes to hold `frames`, keeping the `pendingFrames` already rendered into them.
    private func ensureOutputCapacity(_ frames: Int) {
        guard frames > outputCapacity || outputPlanes.count != layout.channelCount else { return }
        let capacity = max(frames, Self.encodeChunkFrames * 4)
        let grown = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        if outputPlanes.count == grown.count {
            for c in grown.indices { grown[c].update(from: outputPlanes[c], count: pendingFrames) }
        }
        outputPlanes.forEach { $0.deallocate() }
        outputPlanes = grown
        outputCapacity = capacity
    }
}
