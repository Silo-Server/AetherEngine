import Foundation
import Testing
import CoreMedia
import AudioToolbox
@testable import AetherEngine

/// The `nativeRemoteHLS` bypass runs no libav probe, so a stats panel had nothing but the host's own
/// metadata of the ORIGINAL file to show: a capped 1280x720 H.264 transcode read "3840x2160, Main 10".
/// AVPlayer's parsed item tracks already carry the delivered stream, so these pin the mapping from its
/// format descriptions onto the fields the probe path publishes, in the probe path's vocabulary.
@Suite("RemoteHLSStreamDescription")
struct RemoteHLSStreamDescriptionTests {

    // MARK: - Fixtures

    private static let avc1: FourCharCode = 0x61766331
    private static let hvc1: FourCharCode = 0x68766331

    /// avcC with no SPS/PPS: version, profile_idc, constraint flags, level, lengthSizeMinusOne, 0 SPS, 0 PPS.
    private static func avcC(profileIDC: UInt8, compatibility: UInt8 = 0, highExtension: (chroma: UInt8, lumaDepth: UInt8)? = nil) -> Data {
        var bytes: [UInt8] = [1, profileIDC, compatibility, 31, 0xFF, 0xE0, 0x00]
        if let ext = highExtension {
            bytes += [0xFC | ext.chroma, 0xF8 | (ext.lumaDepth - 8), 0xF8 | (ext.lumaDepth - 8), 0x00]
        }
        return Data(bytes)
    }

    /// hvcC header (23 bytes) with no parameter-set arrays.
    private static func hvcC(profileIDC: UInt8, chroma: UInt8 = 1, lumaDepth: UInt8 = 8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 23)
        bytes[0] = 1
        bytes[1] = profileIDC & 0x1F
        bytes[12] = 150
        bytes[16] = 0xFC | chroma
        bytes[17] = 0xF8 | (lumaDepth - 8)
        bytes[18] = 0xF8 | (lumaDepth - 8)
        return Data(bytes)
    }

    private static func videoDescription(
        subType: FourCharCode, width: Int32, height: Int32,
        extensions: [CFString: Any]
    ) throws -> CMFormatDescription {
        var desc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: subType, width: width, height: height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &desc)
        try #require(status == noErr)
        return try #require(desc)
    }

    private static func audioDescription(formatID: AudioFormatID, sampleRate: Double, channels: UInt32,
                                         bitsPerChannel: UInt32 = 0, cookie: Data? = nil) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1536, mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel, mReserved: 0)
        var desc: CMFormatDescription?
        let status: OSStatus
        if let cookie {
            status = cookie.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                    magicCookieSize: cookie.count, magicCookie: raw.baseAddress, extensions: nil,
                    formatDescriptionOut: &desc)
            }
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        }
        try #require(status == noErr)
        return try #require(desc)
    }

    /// dec3 payload for one independent substream without dependents, JOC flag as given.
    private static func dec3(joc: Bool) -> Data {
        // data_rate(13)=640 num_ind_sub(3)=0 | fscod bsid reserved asvc bsmod acmod lfeon reserved
        // num_dep_sub(4)=0 reserved(1) | reserved(7) flag_ec3_extension_type_a(1) | complexity_index(8)
        Data([0x50, 0x00, 0x20, 0x0F, 0x00, joc ? 0x01 : 0x00, joc ? 16 : 0])
    }

    // MARK: - Delivered video

    @Test("the device case: a 720p H.264 High transcode reads as what was delivered")
    func deliveredH264Transcode() throws {
        let desc = try Self.videoDescription(
            subType: Self.avc1, width: 1280, height: 720,
            extensions: [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
                kCMFormatDescriptionExtension_FullRangeVideo: false,
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": Self.avcC(profileIDC: 100)],
            ])
        let video = try #require(RemoteHLSStreamDescription.video(from: desc))
        #expect(video.width == 1280)
        #expect(video.height == 720)
        #expect(video.codecName == "h264")
        #expect(video.format == VideoStreamFormat(
            pixelFormat: "yuv420p", bitDepth: 8, colorPrimaries: "bt709", transfer: "bt709",
            matrix: "bt709", range: "tv", profile: "High"))
    }

    @Test("HEVC Main 10 PQ reads its profile, depth and BT.2020 description from hvcC and the extensions")
    func hevcMain10PQ() throws {
        let desc = try Self.videoDescription(
            subType: Self.hvc1, width: 3840, height: 2160,
            extensions: [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["hvcC": Self.hvcC(profileIDC: 2, lumaDepth: 10)],
            ])
        let video = try #require(RemoteHLSStreamDescription.video(from: desc))
        #expect(video.codecName == "hevc")
        #expect(video.format.pixelFormat == "yuv420p10le")
        #expect(video.format.bitDepth == 10)
        #expect(video.format.profile == "Main 10")
        #expect(video.format.colorPrimaries == "bt2020")
        #expect(video.format.transfer == "smpte2084")
        #expect(video.format.matrix == "bt2020nc")
        #expect(video.format.range == nil)
    }

    /// Same rule as AE#658 on the probe path: an untagged stream is not reported as BT.709.
    @Test("an untagged stream keeps its gaps")
    func untaggedStaysNil() throws {
        let desc = try Self.videoDescription(subType: Self.avc1, width: 640, height: 360, extensions: [:])
        let video = try #require(RemoteHLSStreamDescription.video(from: desc))
        #expect(video.format.colorPrimaries == nil)
        #expect(video.format.transfer == nil)
        #expect(video.format.matrix == nil)
        #expect(video.format.range == nil)
        #expect(video.format.profile == nil)
        #expect(video.format.pixelFormat == nil)
        #expect(video.format.bitDepth == nil)
    }

    @Test("CoreMedia colour names map onto libav's")
    func colourNames() {
        #expect(RemoteHLSStreamDescription.primariesName(kCMFormatDescriptionColorPrimaries_P3_D65 as String) == "smpte432")
        #expect(RemoteHLSStreamDescription.primariesName(kCMFormatDescriptionColorPrimaries_DCI_P3 as String) == "smpte431")
        #expect(RemoteHLSStreamDescription.primariesName(kCMFormatDescriptionColorPrimaries_EBU_3213 as String) == "bt470bg")
        #expect(RemoteHLSStreamDescription.primariesName(kCMFormatDescriptionColorPrimaries_SMPTE_C as String) == "smpte170m")
        #expect(RemoteHLSStreamDescription.transferName(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) == "arib-std-b67")
        #expect(RemoteHLSStreamDescription.transferName(kCMFormatDescriptionTransferFunction_ITU_R_2020 as String) == "bt2020-10")
        #expect(RemoteHLSStreamDescription.transferName(kCMFormatDescriptionTransferFunction_Linear as String) == "linear")
        #expect(RemoteHLSStreamDescription.transferName(kCMFormatDescriptionTransferFunction_sRGB as String) == "iec61966-2-1")
        #expect(RemoteHLSStreamDescription.matrixName(kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String) == "smpte170m")
        #expect(RemoteHLSStreamDescription.matrixName(kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as String) == "smpte240m")
        // A name CoreMedia adds later passes through rather than vanishing.
        #expect(RemoteHLSStreamDescription.primariesName("Future_Primaries") == "Future_Primaries")
    }

    @Test("constraint flags in avcC reach the profile name")
    func constrainedBaseline() {
        let config = RemoteHLSStreamDescription.avcConfiguration(Self.avcC(profileIDC: 66, compatibility: 0x40))
        #expect(config?.profileName == "Constrained Baseline")
        let high10 = RemoteHLSStreamDescription.avcConfiguration(
            Self.avcC(profileIDC: 110, highExtension: (chroma: 1, lumaDepth: 10)))
        #expect(high10?.profileName == "High 10")
        #expect(high10?.pixelFormat == "yuv420p10le")
        #expect(high10?.bitDepth == 10)
    }

    @Test("a truncated configuration record yields nothing rather than a guess")
    func truncatedRecords() {
        #expect(RemoteHLSStreamDescription.avcConfiguration(Data([1, 100])) == nil)
        #expect(RemoteHLSStreamDescription.hevcConfiguration(Data([1, 2, 0, 0])) == nil)
    }

    @Test("an audio description is not a video one")
    func audioIsNotVideo() throws {
        let desc = try Self.audioDescription(formatID: kAudioFormatEnhancedAC3, sampleRate: 48_000, channels: 6)
        #expect(RemoteHLSStreamDescription.video(from: desc) == nil)
    }

    // MARK: - Audio tracks

    @Test("the device case: E-AC-3 5.1 at 48 kHz becomes an eac3 TrackInfo")
    func eac3Track() throws {
        let desc = try Self.audioDescription(formatID: kAudioFormatEnhancedAC3, sampleRate: 48_000, channels: 6)
        let reading = try #require(RemoteHLSStreamDescription.audioReading(from: desc, isEnabled: true, language: "eng"))
        let (tracks, active) = RemoteHLSStreamDescription.audioTracks([reading])
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.id == RemoteHLSStreamDescription.audioTrackIDBase)
        #expect(active == track.id)
        #expect(track.codec == "eac3")
        #expect(track.channels == 6)
        #expect(track.sampleRate == 48_000)
        #expect(track.bitsPerSample == 0)
        #expect(track.language == "eng")
        #expect(track.name == "ENG (eac3)")
        #expect(track.isAtmos == false)
        #expect(track.isDefault)
    }

    @Test("a dec3 cookie announcing JOC marks the track Atmos, as a box or as its payload")
    func eac3JOC() throws {
        let payload = Self.dec3(joc: true)
        var box = Data([0, 0, 0, UInt8(8 + payload.count)])
        box.append(contentsOf: Array("dec3".utf8))
        box.append(payload)
        for cookie in [payload, box] {
            let desc = try Self.audioDescription(
                formatID: kAudioFormatEnhancedAC3, sampleRate: 48_000, channels: 6, cookie: cookie)
            let reading = try #require(RemoteHLSStreamDescription.audioReading(from: desc, isEnabled: true, language: nil))
            let track = try #require(RemoteHLSStreamDescription.audioTracks([reading]).tracks.first)
            #expect(track.isAtmos)
            #expect(track.profile == "Dolby Digital Plus + Dolby Atmos")
        }
        #expect(RemoteHLSStreamDescription.eac3CarriesJOC(dec3: Self.dec3(joc: false)) == false)
        #expect(RemoteHLSStreamDescription.eac3CarriesJOC(dec3: Data([0x50])) == false)
    }

    @Test("audio format IDs map onto libavcodec names, AAC with its profile")
    func audioCodecNames() {
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatMPEG4AAC).name == "aac")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatMPEG4AAC).profile == "LC")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatMPEG4AAC_HE).profile == "HE-AAC")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatMPEG4AAC_HE_V2).profile == "HE-AACv2")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatAC3).name == "ac3")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatEnhancedAC3).name == "eac3")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatMPEGLayer3).name == "mp3")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatFLAC).name == "flac")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatOpus).name == "opus")
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: kAudioFormatAppleLossless).name == "alac")
        // An unmapped format still names itself, like the video side.
        #expect(RemoteHLSStreamDescription.audioCodec(formatID: 0x7A7A7A7A).name == "zzzz")
    }

    @Test("ids are synthetic and ordinal, the enabled track is the active one, und is no language")
    func multipleTracks() throws {
        let a = try Self.audioDescription(formatID: kAudioFormatMPEG4AAC, sampleRate: 44_100, channels: 2)
        let b = try Self.audioDescription(formatID: kAudioFormatAC3, sampleRate: 48_000, channels: 6)
        let readings = [
            try #require(RemoteHLSStreamDescription.audioReading(from: a, isEnabled: false, language: "und")),
            try #require(RemoteHLSStreamDescription.audioReading(from: b, isEnabled: true, language: "deu")),
        ]
        let (tracks, active) = RemoteHLSStreamDescription.audioTracks(readings)
        #expect(tracks.map(\.id) == [RemoteHLSStreamDescription.audioTrackIDBase, RemoteHLSStreamDescription.audioTrackIDBase + 1])
        #expect(active == RemoteHLSStreamDescription.audioTrackIDBase + 1)
        #expect(tracks[0].language == nil)
        #expect(tracks[0].name == "Track 1 (aac)")
        #expect(tracks[0].isDefault == false)
        #expect(tracks[1].name == "DEU (ac3)")
    }

    @Test("no enabled track means no active index")
    func nothingEnabled() throws {
        let a = try Self.audioDescription(formatID: kAudioFormatMPEG4AAC, sampleRate: 48_000, channels: 2)
        let reading = try #require(RemoteHLSStreamDescription.audioReading(from: a, isEnabled: false, language: nil))
        #expect(RemoteHLSStreamDescription.audioTracks([reading]).activeID == nil)
        #expect(RemoteHLSStreamDescription.audioTracks([]).tracks.isEmpty)
    }

    @Test("a video description is not an audio one")
    func videoIsNotAudio() throws {
        let desc = try Self.videoDescription(subType: Self.avc1, width: 16, height: 16, extensions: [:])
        #expect(RemoteHLSStreamDescription.audioReading(from: desc, isEnabled: true, language: nil) == nil)
    }
}
