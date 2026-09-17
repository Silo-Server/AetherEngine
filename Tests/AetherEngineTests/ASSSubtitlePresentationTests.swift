import CoreGraphics
import Foundation
import XCTest
@testable import AetherEngine

final class ASSSubtitlePresentationTests: XCTestCase {
    private let playRes = CGSize(width: 640, height: 480)

    private func cue(_ text: String, id: Int = 10) -> SubtitleCue {
        SubtitleCue(id: id, startTime: 1, endTime: 3, body: .text(text))
    }

    func testSoftwarePiPNormalizationMatchesTheOrdinaryASSDecoder() async throws {
        let url = try MultiASSPlayResFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        for index in [MultiASSPlayResFixture.englishStreamIndex, MultiASSPlayResFixture.spanishStreamIndex] {
            let raw = try await SubtitleDecoder.decodeFile(url: url, preserveASSMarkup: true, sourceStreamIndex: index)
            let ordinary = try await SubtitleDecoder.decodeFile(url: url, sourceStreamIndex: index)
            let header = try XCTUnwrap(raw.assHeader)
            let resolution = try XCTUnwrap(SubtitleRectText.playRes(fromASSHeader: header))
            let normalized = SubtitleRectText.normalizedASSCues(raw.cues, playRes: resolution, isExternal: true)
            XCTAssertEqual(normalized.count, ordinary.cues.count)
            for (actual, expected) in zip(normalized, ordinary.cues) {
                XCTAssertEqual(actual.text, expected.text)
                XCTAssertEqual(actual.placement, expected.placement)
                XCTAssertEqual(actual.startTime, expected.startTime)
                XCTAssertEqual(actual.endTime, expected.endTime)
            }
            XCTAssertTrue(raw.cues[0].text?.contains("\\pos(320,240)") == true,
                          "Normalizing PiP must leave the primary raw cue intact")
        }
    }

    func testNormalizationRetainsRunsPlacementAndMultiRectBodyOrder() throws {
        let raw = cue([
            #"0,0,Default,,0,0,0,,{\an8\pos(320,240)}plain\Nsecond"#,
            #"1,0,Default,,0,0,0,,{\c&H0000FF&\i1\fnArial\fs32}styled"#,
            #"2,0,Default,,0,0,0,,last"#,
        ].joined(separator: "\n"))
        let embedded = SubtitleRectText.normalizedASSCues([raw], playRes: playRes, isExternal: false)
        let external = SubtitleRectText.normalizedASSCues([raw], playRes: playRes, isExternal: true)
        XCTAssertEqual(embedded.map(\.text), ["styled", "plain\nsecond\nlast"])
        XCTAssertEqual(external.map(\.text), ["plain\nsecond\nlast", "styled"])
        guard case .richText(let runs) = embedded[0].body else {
            return XCTFail("PiP should retain the ordinary decoder's resolved runs")
        }
        XCTAssertEqual(runs.first?.color, SubtitleColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(runs.first?.isItalic, true)
        XCTAssertEqual(runs.first?.fontName, "Arial")
        XCTAssertEqual(runs.first?.fontSize, 32)
        for value in embedded + external {
            XCTAssertEqual(value.placement?.alignment, 8)
            XCTAssertEqual(value.placement?.position, CGPoint(x: 0.5, y: 0.5))
            XCTAssertEqual(value.id, raw.id)
            XCTAssertEqual(value.startTime, raw.startTime)
            XCTAssertEqual(value.endTime, raw.endTime)
        }
    }

    @MainActor
    func testOnlyRawPrimaryASSIsNormalizedForSoftwarePiP() throws {
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        engine.subtitleTracks = [TrackInfo(id: 2, name: "ASS", codec: "ass", language: "en", isDefault: false,
                                          assHeader: "[Script Info]\nPlayResX: 640\nPlayResY: 480")]
        engine.activeSubtitleTrackIndex = 2
        let primary = cue(#"0,0,Default,,0,0,0,,{\pos(320,240)}primary"#)
        // An ordinary text line that resembles an event must not be parsed.
        let companion = cue("0,1,2,3,4,5,6,7,companion", id: 11)
        XCTAssertEqual(engine.softwarePiPSubtitleCues(primary: [primary], secondary: [companion])[0].text, primary.text)
        engine.pictureInPictureActive = true
        let normalized = engine.softwarePiPSubtitleCues(primary: [primary], secondary: [companion])
        XCTAssertEqual(normalized.map(\.text), ["primary", companion.text])
        XCTAssertEqual(normalized[0].placement?.position, CGPoint(x: 0.5, y: 0.5))
        engine.subtitleTracks = [TrackInfo(id: 2, name: "SRT", codec: "subrip", language: "en", isDefault: false)]
        XCTAssertEqual(engine.softwarePiPSubtitleCues(primary: [companion], secondary: [])[0].text, companion.text)
    }

    @MainActor
    func testPrimaryAndSecondaryASSUseDifferentDecoderModes() async throws {
        let url = try MultiASSPlayResFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        var options = LoadOptions(matchContentEnabled: false, preserveASSMarkup: true)
        options.autoplay = false
        try await engine.load(url: url, options: options)
        let track = Int(MultiASSPlayResFixture.englishStreamIndex)
        engine.selectSubtitleTrack(index: track)
        engine.selectSecondarySubtitleTrack(index: track)
        for _ in 0..<100 {
            if !engine.subtitleCues.isEmpty, !engine.secondarySubtitleCues.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let primary = try XCTUnwrap(engine.subtitleCues.first)
        let secondary = try XCTUnwrap(engine.secondarySubtitleCues.first)
        XCTAssertTrue(primary.text?.contains("\\pos(320,240)") == true)
        XCTAssertEqual(secondary.text, MultiASSPlayResFixture.englishLines[0])
        XCTAssertEqual(secondary.placement?.position, MultiASSPlayResFixture.englishPosition)
    }
}
