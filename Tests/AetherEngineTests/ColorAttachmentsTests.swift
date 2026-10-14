import CoreVideo
import Testing
import AetherLibavutil
@testable import AetherEngine

struct ColorAttachmentsTests {

    private func described(
        _ primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED,
        _ transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
        _ matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED
    ) -> ColorDescription {
        ColorDescription(primaries: primaries, transfer: transfer, matrix: matrix, range: AVCOL_RANGE_MPEG)
    }

    @Test("AE#654: an untagged stream is presented as BT.709 in all three, whatever its size")
    func untaggedIsBT709() {
        let tags = ColorAttachments.presented(.unspecified)
        #expect(tags == ColorAttachments.Tags(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
    }

    @Test("AE#654: a lone BT.601 matrix gets SMPTE-C primaries, as VideoToolbox fills it")
    func bt601MatrixImpliesSMPTEC() {
        let tags = ColorAttachments.presented(described(AVCOL_PRI_UNSPECIFIED, AVCOL_TRC_UNSPECIFIED, AVCOL_SPC_SMPTE170M))
        #expect(tags.primaries == kCVImageBufferColorPrimaries_SMPTE_C)
        #expect(tags.transfer == kCVImageBufferTransferFunction_ITU_R_709_2)
        #expect(tags.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
    }

    @Test("AE#654: SD primaries without a matrix get the BT.601 matrix, not BT.709")
    func sdPrimariesImplyBT601Matrix() {
        #expect(ColorAttachments.presented(described(AVCOL_PRI_BT470BG)).matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        #expect(ColorAttachments.presented(described(AVCOL_PRI_SMPTE170M)).matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        #expect(ColorAttachments.presented(described(AVCOL_PRI_BT2020)).matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020)
    }

    @Test("AE#654: a tagged SD stream keeps its tags; before, none of them had a CoreVideo mapping")
    func taggedSDIsNotGuessed() {
        let pal = ColorAttachments.presented(described(AVCOL_PRI_BT470BG, AVCOL_TRC_SMPTE170M, AVCOL_SPC_BT470BG))
        #expect(pal.primaries == kCVImageBufferColorPrimaries_EBU_3213)
        #expect(pal.transfer == kCVImageBufferTransferFunction_ITU_R_709_2)
        #expect(pal.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
    }

    @Test("AE#654: a declared HDR description passes through untouched")
    func hdrUntouched() {
        let tags = ColorAttachments.presented(described(AVCOL_PRI_BT2020, AVCOL_TRC_SMPTE2084, AVCOL_SPC_BT2020_NCL))
        #expect(tags == ColorAttachments.Tags(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020))
    }

    @Test("A still's colour space is the one CoreVideo manages the displayed buffer in")
    func stillColorSpaceFollowsPlayback() throws {
        let untagged = try #require(ColorAttachments.colorSpace(for: ColorAttachments.presented(.unspecified)))
        #expect(untagged.name as String? == "kCGColorSpaceCoreMedia709")
        let sd = ColorAttachments.presented(described(AVCOL_PRI_SMPTE170M, AVCOL_TRC_SMPTE170M, AVCOL_SPC_SMPTE170M))
        let sdSpace = try #require(ColorAttachments.colorSpace(for: sd))
        #expect(sdSpace != untagged)
        let sdr2020 = ColorAttachments.presented(described(AVCOL_PRI_BT2020, AVCOL_TRC_BT2020_10, AVCOL_SPC_BT2020_NCL))
        #expect(ColorAttachments.colorSpace(for: sdr2020) != nil)
    }
}
