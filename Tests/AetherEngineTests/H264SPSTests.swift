import XCTest
@testable import AetherEngine

final class H264SPSTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Real Pluto ad creative SPS (NAL incl 0x67 header), high profile.
    func testAdSPSIs1280x720() {
        let sps = hex("6764001facd9405005bb016a02040280000003008000001e078c18cb")
        let dim = H264SPS.dimensions(fromNAL: sps)
        XCTAssertEqual(dim?.width, 1280)
        XCTAssertEqual(dim?.height, 720)
    }

    // Real Pluto program (content) SPS, high profile, cropped to 684.
    func testContentSPSIs1216x684() {
        let sps = hex("6764001facd9404c057fbc05a828282a000003000200000300781e30632c")
        let dim = H264SPS.dimensions(fromNAL: sps)
        XCTAssertEqual(dim?.width, 1216)
        XCTAssertEqual(dim?.height, 684)
    }

    func testRejectsNonSPS() {
        XCTAssertNil(H264SPS.dimensions(fromNAL: hex("68efbcb0"))) // PPS
        XCTAssertNil(H264SPS.dimensions(fromNAL: []))
        XCTAssertNil(H264SPS.dimensions(fromNAL: hex("67")))       // header only
    }

    // #133: a real 720p SPS + PPS + IDR-slice access unit (Annex-B, 4-byte start codes).
    private let sc: [UInt8] = [0, 0, 0, 1]
    private var sps720: [UInt8] { hex("6764001facd9405005bb016a02040280000003008000001e078c18cb") }
    private var pps: [UInt8] { hex("68efbcb0") }

    private func annexB(_ nals: [[UInt8]]) -> [UInt8] {
        nals.reduce(into: [UInt8]()) { $0 += sc + $1 }
    }

    private func withBuf<R>(_ bytes: [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        bytes.withUnsafeBufferPointer { body($0) }
    }

    // #133 / AE#627: a mid-stream join opens on an entry point: an IDR (NAL type 5), or an intra
    // picture behind a recovery point SEI with recovery_frame_cnt 0. A bare non-IDR slice is neither.
    private var iSlice: [UInt8] { [0x41, 0x88, 0x84, 0x00] }          // non-IDR, first_mb 0, slice_type 7 (I)
    private var pSlice: [UInt8] { [0x41, 0x9a, 0x00, 0x00] }          // non-IDR, first_mb 0, slice_type 5 (P)
    private var recoveryNow: [UInt8] { [0x06, 0x06, 0x01, 0xc4, 0x80] }  // recovery point, cnt 0 (x264's bytes)
    private var recoveryLater: [UInt8] { [0x06, 0x06, 0x01, 0x71, 0x80] } // recovery point, cnt 2 (gradual refresh)

    func testIDRIsAnEntry() {
        let au = annexB([sps720, pps, [0x65, 0x88, 0x84, 0x00]])
        XCTAssertTrue(withBuf(au) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
    }

    func testBareNonIDRSliceIsNotAnEntry() {
        XCTAssertFalse(withBuf(annexB([sps720, pps, pSlice])) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
        XCTAssertFalse(withBuf(annexB([sps720, pps, iSlice])) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
    }

    func testBareParameterSetsAreNotAnEntry() {
        XCTAssertFalse(withBuf(annexB([sps720, pps])) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
        XCTAssertFalse(withBuf(annexB([sps720, pps, recoveryNow])) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
    }

    func testEntryHandlesThreeByteStartCodes() {
        let sc3: [UInt8] = [0, 0, 1]
        var au: [UInt8] = sc3
        au += sps720
        au += sc3
        au += pps
        au += sc3
        au += [0x65, 0x88]
        XCTAssertTrue(withBuf(au) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
    }

    // AE#627: the reporter's feed never sends an IDR. Its entry points are AUD, SPS, PPS, SEI
    // [recovery point cnt 0, pic_timing], then an I-picture.
    func testImmediateIntraRecoveryPointIsAnEntry() {
        let aud: [UInt8] = [0x09, 0xf0]
        let au = annexB([aud, sps720, pps, recoveryNow, iSlice])
        XCTAssertTrue(withBuf(au) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
    }

    func testRecoveryPointBehindAnotherSEIMessageIsFound() {
        let sei: [UInt8] = [0x06, 0x05, 0x02, 0xaa, 0xbb, 0x06, 0x01, 0xc4, 0x80]
        XCTAssertTrue(withBuf(annexB([sps720, pps, sei, iSlice])) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
    }

    func testGradualRefreshRecoveryPointIsNotAnEntry() {
        XCTAssertFalse(withBuf(annexB([sps720, pps, recoveryLater, iSlice])) {
            H264SPS.isRandomAccessEntry(fromAnnexB: $0)
        })
    }

    func testRecoveryPointOnAPictureWithAPSliceIsNotAnEntry() {
        XCTAssertFalse(withBuf(annexB([sps720, pps, recoveryNow, pSlice])) { H264SPS.isRandomAccessEntry(fromAnnexB: $0) })
        XCTAssertFalse(withBuf(annexB([sps720, pps, recoveryNow, iSlice, pSlice])) {
            H264SPS.isRandomAccessEntry(fromAnnexB: $0)
        })
    }

    func testRecoveryFrameCountParsesTheMessage() {
        XCTAssertEqual(H264SPS.recoveryFrameCount(seiRBSP: [0x06, 0x01, 0xc4, 0x80]), 0)
        XCTAssertEqual(H264SPS.recoveryFrameCount(seiRBSP: [0x06, 0x01, 0x71, 0x80]), 2)
        XCTAssertNil(H264SPS.recoveryFrameCount(seiRBSP: [0x05, 0x02, 0xaa, 0xbb, 0x80]))
        XCTAssertNil(H264SPS.recoveryFrameCount(seiRBSP: [0x06, 0x09, 0xc4]))  // size past the end
    }

    func testExtractSPSandPPSStillSucceedsOnRecoveryPointAU() {
        let au = annexB([sps720, pps, recoveryNow, iSlice])
        let got = withBuf(au) { H264SPS.extractSPSandPPS(fromAnnexB: $0) }
        XCTAssertNotNil(got)
        XCTAssertEqual(H264SPS.dimensions(fromNAL: got!.sps)?.width, 1280)
    }

    // MARK: - #150 frame_mbs_only_flag fallback

    // Main profile 4.0, 1920x1080, frame_mbs_only=0, mb_adaptive=0 (PAFF) - the reporter's channel shape.
    private var spsInterlaced1080i: [UInt8] { hex("674d4028eca03c0223ed") }

    func testInterlacedSPSParsesDimensionsAndFrameMbsOnlyFalse() {
        let dim = H264SPS.dimensions(fromNAL: spsInterlaced1080i)
        XCTAssertEqual(dim?.width, 1920)
        XCTAssertEqual(dim?.height, 1080)
        XCTAssertEqual(H264SPS.frameMbsOnly(fromNAL: spsInterlaced1080i), false)
    }

    func testProgressiveSPSFrameMbsOnlyTrue() {
        XCTAssertEqual(H264SPS.frameMbsOnly(fromNAL: sps720), true)
    }

    func testFrameMbsOnlyRejectsNonSPS() {
        XCTAssertNil(H264SPS.frameMbsOnly(fromNAL: hex("68efbcb0"))) // PPS
        XCTAssertNil(H264SPS.frameMbsOnly(fromNAL: []))
    }

    func testSPSNALFromAnnexBExtradata() {
        let extradata = annexB([spsInterlaced1080i, pps])
        let sps = H264SPS.spsNAL(fromExtradata: extradata)
        XCTAssertEqual(sps, spsInterlaced1080i)
    }

    func testSPSNALFromAvcCExtradata() {
        var avcc: [UInt8] = [0x01, 0x4d, 0x40, 0x28, 0xff, 0xe1]
        avcc += [UInt8(spsInterlaced1080i.count >> 8), UInt8(spsInterlaced1080i.count & 0xff)]
        avcc += spsInterlaced1080i
        avcc += [0x01, UInt8(pps.count >> 8), UInt8(pps.count & 0xff)]
        avcc += pps
        let sps = H264SPS.spsNAL(fromExtradata: avcc)
        XCTAssertEqual(sps, spsInterlaced1080i)
    }

    func testSPSNALRejectsGarbageOrEmpty() {
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: []))
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: [0xde, 0xad, 0xbe, 0xef]))
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: [0x01, 0x4d])) // truncated avcC header
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: annexB([pps]))) // params without SPS
    }
}
