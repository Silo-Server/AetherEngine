import Foundation
import CoreVideo
import CoreMedia
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit DEC-107: `SoftwareVideoDecoder` hard-wired its output to 8-bit or 10-bit VIDEO range from the
/// container declaration. `color_range` was never read, so a full-range AV1 / VP9 / HEVC picture was
/// labelled video range and shown crushed, and `bits_per_raw_sample` is 0 for libdav1d and the AV1 / VP9
/// parsers, so a 10-bit SDR stream was dithered down to 8 bit. The pool format now follows the frame.
@Suite("Software decoder output format follows the frame (DEC-107)")
struct SoftwareDecoderOutputFormatTests {

    // MARK: - The decision

    @Test("full range is carried as a label on 8-bit and on 10-bit output")
    func fullRangeIsALabel() {
        let eight = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P.rawValue, colorRange: AVCOL_RANGE_JPEG, streamIs10Bit: false)
        #expect(eight == .init(tenBit: false, fullRange: true))
        #expect(eight.pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        let ten = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P10LE.rawValue, colorRange: AVCOL_RANGE_JPEG, streamIs10Bit: false)
        #expect(ten == .init(tenBit: true, fullRange: true))
        #expect(ten.pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    }

    @Test("limited and unspecified range stay video range")
    func limitedStaysVideoRange() {
        for range in [AVCOL_RANGE_MPEG, AVCOL_RANGE_UNSPECIFIED] {
            let format = SoftwareVideoDecoder.outputFormat(
                pixelFormat: AV_PIX_FMT_YUV420P.rawValue, colorRange: range, streamIs10Bit: false)
            #expect(format == .init(tenBit: false, fullRange: false))
            #expect(format.pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    @Test("a 10-bit frame is 10-bit output even when the stream declared no depth")
    func frameDepthWidensTheDeclaration() {
        let format = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P10LE.rawValue, colorRange: AVCOL_RANGE_MPEG, streamIs10Bit: false)
        #expect(format == .init(tenBit: true, fullRange: false))
        #expect(format.swscaleFormat == AV_PIX_FMT_P010LE)
    }

    @Test("the stream's own 10-bit verdict is never narrowed by an 8-bit frame")
    func declarationIsNeverNarrowed() {
        let format = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P.rawValue, colorRange: AVCOL_RANGE_MPEG, streamIs10Bit: true)
        #expect(format.tenBit)
    }

    @Test("a yuvj source stays video range, because swscale converts it itself")
    func yuvjIsConvertedBySwscale() {
        let format = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUVJ420P.rawValue, colorRange: AVCOL_RANGE_JPEG, streamIs10Bit: false)
        #expect(format == .init(tenBit: false, fullRange: false))
    }

    // MARK: - Real decodes

    private func firstPixelBuffer(base64: String, formatHint: String?) throws -> CVPixelBuffer {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: formatHint)
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))

        let box = FrameBox()
        let decoder = SoftwareVideoDecoder()
        decoder.decodesSingleThreaded = true
        try decoder.open(stream: stream) { buffer, _, _ in box.keepFirst(buffer) }
        defer { decoder.close() }

        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex { decoder.decode(packet: pkt) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        return try #require(box.first, "the fixture must decode to at least one frame")
    }

    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        func keepFirst(_ candidate: CVPixelBuffer) { lock.withLock { if buffer == nil { buffer = candidate } } }
        var first: CVPixelBuffer? { lock.withLock { buffer } }
    }

    @Test("a full-range VP9 picture reaches the layer as full range, with its white still at 255")
    func fullRangeVP9() throws {
        let buffer = try firstPixelBuffer(base64: Self.vp9FullRangeBase64, formatHint: nil)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        #expect(luma[0] == 255, "no range conversion: the decoder's bytes are copied across and only labelled")
    }

    @Test("a 10-bit SDR AV1 picture stays 10-bit instead of being dithered to 8")
    func tenBitSDRAV1() throws {
        let buffer = try firstPixelBuffer(base64: Self.av1TenBitBase64, formatHint: "mp4")
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    }

    /// 64x64 white, 3 frames, `-color_range pc`. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=white:s=64x64:r=10:d=0.3" -vf "scale=out_range=pc:out_color_matrix=bt709,format=yuv420p" \
    ///     -c:v libvpx-vp9 -color_range pc -b:v 100k -deadline realtime -cpu-used 8 -g 10 vp9fr.webm
    static let vp9FullRangeBase64 = """
        GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAJjEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU
        rmtTrIHYTbuMU6uEElTDZ1OsggEpTbuMU6uEHFO7a1OsggJN7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsirXsYMPQkBNgI1M
        YXZmNjIuMTIuMTAxV0GNTGF2ZjYyLjEyLjEwMUSJiEBywAAAAAAAFlSua8yuAQAAAAAAAEPXgQFzxYjMgzwgXtS2wJyBACK1nIN1
        bmSIgQCGhVZfVlA5g4EBI+ODhAX14QDglLCBQLqBQJqBAlWwiFWxgQFVuYECElTDZ0CAc3OgY8CAZ8iaRaOHRU5DT0RFUkSHjUxh
        dmY2Mi4xMi4xMDFzc9pjwItjxYjMgzwgXtS2wGfIpUWjh0VOQ09ERVJEh5hMYXZjNjIuMjguMTAxIGxpYnZweC12cDlnyKFFo4hE
        VVJBVElPTkSHkzAwOjAwOjAwLjMwMDAwMDAwMAAfQ7Z1QJjngQCj6YEAAICCSYNCUAPwA/YGOCQcGEIAACBAAGxb///ZMyRz+Oqo
        thxUFRuF7BRUkRNywleB6KhH4xFBDtsK7OkcSQT//+C9lZfb5yBGkxAXMq8VCzCvy+wStgESyCieiKCHbYV2dI4kgNw6QKOTgQBk
        AIYAQJKcKElAAANwAABUcKOTgQDIAIYAQJKcLErAAANwAABUcBxTu2uRu4+zgQC3iveBAfGCAa/wgQM=
        """

    /// 64x64 gray, 3 frames, 10-bit 4:2:0, video range, no `bits_per_raw_sample` anywhere. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=0x808080:s=64x64:r=10:d=0.3" -vf format=yuv420p10le -c:v libsvtav1 \
    ///     -preset 12 -g 10 -pix_fmt yuv420p10le av110.mp4
    static let av1TenBitBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21hdjAxaXNvMm1wNDEAAAAIZnJlZQAAAEttZGF0CgoAAAACr/+JXygIMgwQAK8CCCBBAQAAAv4y
        ESgCACSSSRGMAAABAAEAAJwQMhEwAgQJJAAjGAAAAgADAACc6BoBiAAAAyNtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAB
        LAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAACAAACTXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAABLAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAA
        AAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAASwAAAAAAAEAAAAAAcVtZGlh
        AAAAIG1kaGQAAAAAAAAAAAAAAAAAACgAAAAMAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxl
        cgAAAAFwbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABMHN0YmwA
        AACsc3RzZAAAAAAAAAABAAAAnGF2MDEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEXTGF2YzYyLjI4
        LjEwMSBsaWJzdnRhdjEAAAAAAAAAAAAY//8AAAAYYXYxQ4EATAAKCgAAAAKv/4BfCAgAAAAKZmllbAEAAAAAEHBhc3AAAAABAAAA
        AQAAABRidHJ0AAAAAAAABvoAAAb6AAAAGHN0dHMAAAAAAAAAAQAAAAMAAAQAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAcc3RzYwAA
        AAAAAAABAAAAAQAAAAMAAAABAAAAIHN0c3oAAAAAAAAAAAAAAAMAAAAaAAAAJgAAAAMAAAAUc3RjbwAAAAAAAAABAAAAMAAAAGJ1
        ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAA
        AQAAAABMYXZmNjIuMTIuMTAx
        """
}
