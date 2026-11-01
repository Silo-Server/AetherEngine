import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

/// AetherEngine#88: load-declared external tracks join the native rendition table (externalID set,
/// sourceStreamIndex nil) and the PiP ordinal mapping resolves them. A finished store (whole-file
/// decode at load) backfills the overlay instantly on select instead of re-downloading, and a
/// selection made while that decode runs waits for it (silo-apple#600).
@MainActor
struct ExternalNativeSubtitleTests {

    @Test("PiP ordinal maps embedded actives via sourceStreamIndex")
    func ordinalEmbedded() {
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 2, language: "en"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 4, language: "de"),
        ]
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 4, in: table) == 1)
    }

    @Test("PiP ordinal maps external actives via externalID")
    func ordinalExternal() {
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 2, language: "en"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000, language: "de"),
        ]
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 100_000, in: table) == 1)
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 100_001, in: table) == nil)
    }

    @Test("finished external store backfills the overlay instantly on select")
    func instantBackfill() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, language: "de"))
        let store = NativeSubtitleCueStore()
        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        store.markFinished()
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: nil, externalID: info.id, language: "de")
        ]
        engine.testHookInstallNativeStores([store])
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.subtitleCues.count == 1)
        #expect(!engine.isLoadingSubtitles)
        #expect(engine.activeSubtitleTrackIndex == info.id)
    }

    @Test("an unfinished or cut-short store does not short-circuit; the sidecar decode runs",
          arguments: [false, true])
    func unfinishedStoreDecodes(cutShort: Bool) throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, language: "de"))
        let store = NativeSubtitleCueStore()
        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        if cutShort { store.markFinished(endedEarly: true) }
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: nil, externalID: info.id, language: "de")
        ]
        engine.testHookInstallNativeStores([store])
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.isLoadingSubtitles)
    }

    @Test("styled-ASS preference skips the plain-text store backfill")
    func assSkipsBackfill() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.ass")!, language: "de"))
        let store = NativeSubtitleCueStore()
        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        store.markFinished()
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: nil, externalID: info.id, language: "de")
        ]
        engine.testHookInstallNativeStores([store])
        engine.selectSubtitleTrack(index: info.id)
        // Falls through to the sidecar decode (async, fake URL): loading spinner on, no store cues.
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.isLoadingSubtitles)
    }

    // MARK: - One fetch per selection (silo-apple#600)

    /// A load-declared track whose store fill is reading its sidecar right now.
    private func trackWithRunningFill(_ engine: AetherEngine, url: String,
                                      preserveASSMarkup: Bool = false) -> (TrackInfo, NativeSubtitleCueStore) {
        if preserveASSMarkup { engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true)) }
        let info = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: URL(string: url)!, language: "de"))
        let store = NativeSubtitleCueStore()
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: nil, externalID: info.id, language: "de")]
        engine.testHookInstallNativeStores([store])
        engine.runningExternalStoreFillIDs = [info.id]
        return (info, store)
    }

    private func finishFill(_ engine: AetherEngine, id: Int, complete: Bool,
                            styled: SidecarDecodeResult? = nil, generation: UInt64? = nil) {
        engine.externalStoreFillFinished(.init(externalID: id, complete: complete, styled: styled),
                                         generation: generation ?? engine.externalStoreFillGeneration)
    }

    @Test("a selection while its store fill runs waits for that fill instead of fetching again")
    func selectionWaitsForRunningFill() throws {
        let engine = try AetherEngine()
        let (info, store) = trackWithRunningFill(engine, url: "https://s/x.vtt")
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.sidecarTask == nil, "a decode of its own fetches the sidecar a second time")
        #expect(engine.isLoadingSubtitles)
        #expect(engine.activeSubtitleTrackIndex == info.id)

        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        store.markFinished()
        finishFill(engine, id: info.id, complete: true)
        #expect(engine.sidecarTask == nil)
        #expect(engine.subtitleCues.compactMap(\.text) == ["hi"])
        #expect(!engine.isLoadingSubtitles)
    }

    @Test("a complete fill of a track with no cues backfills it empty instead of fetching it again")
    func completeEmptyFillBackfills() throws {
        let engine = try AetherEngine()
        let (info, store) = trackWithRunningFill(engine, url: "https://s/x.vtt")
        engine.selectSubtitleTrack(index: info.id)
        store.markFinished()
        finishFill(engine, id: info.id, complete: true)
        #expect(engine.sidecarTask == nil)
        #expect(engine.subtitleCues.isEmpty)
        #expect(!engine.isLoadingSubtitles)
    }

    @Test("a bitmap sidecar declared at load decodes on its own instead of waiting on the fill")
    func bitmapSidecarDoesNotWaitForFill() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.sup")!, language: "de", formatHint: "sup"))
        let store = NativeSubtitleCueStore()
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: nil, externalID: info.id, language: "de")]
        engine.testHookInstallNativeStores([store])
        engine.runningExternalStoreFillIDs = [info.id]
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.sidecarTask != nil, "the fill keeps no image cues, so it cannot serve this track")
    }

    @Test("a text stream of a subtitle container or an extensionless sidecar still waits for its fill",
          arguments: [("https://s/multi.mkv", Int32(3)), ("https://s/subtitles/7", nil)] as [(String, Int32?)])
    func unknownFormatSharesFill(url: String, streamIndex: Int32?) throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: url)!, language: "de", sourceStreamIndex: streamIndex))
        let store = NativeSubtitleCueStore()
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: nil, externalID: info.id, language: "de")]
        engine.testHookInstallNativeStores([store])
        engine.runningExternalStoreFillIDs = [info.id]
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.sidecarTask == nil, "a decode of its own fetches the file a second time")
        #expect(engine.isLoadingSubtitles)
    }

    @Test("a fill holds the whole track only when it read all of a text track")
    func fillHoldsWholeTrackOnlyForCompleteText() {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = SubtitleCue(id: 0, startTime: 1, endTime: 2,
                                body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)))
        let text = SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))
        #expect(AetherEngine.fillHoldsWholeTrack(.init(cues: [text], assHeader: nil), endedEarly: false))
        #expect(AetherEngine.fillHoldsWholeTrack(.init(cues: [], assHeader: nil), endedEarly: false))
        #expect(!AetherEngine.fillHoldsWholeTrack(.init(cues: [text], assHeader: nil), endedEarly: true))
        #expect(!AetherEngine.fillHoldsWholeTrack(.init(cues: [image], assHeader: nil), endedEarly: false))
    }

    @Test("a fill that fails or ends early hands the waiting selection to its own decode",
          arguments: [false, true])
    func shortFillDecodes(endedEarly: Bool) throws {
        let engine = try AetherEngine()
        let (info, store) = trackWithRunningFill(engine, url: "https://s/x.vtt")
        engine.selectSubtitleTrack(index: info.id)
        if endedEarly {
            store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
            store.markFinished(endedEarly: true)
        }
        finishFill(engine, id: info.id, complete: false)
        #expect(engine.sidecarTask != nil)
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.isLoadingSubtitles)
    }

    @Test("a styled ASS track backfills from the fill's raw-markup decode, then and on reselect")
    func styledTrackBackfillsFromFill() throws {
        let engine = try AetherEngine()
        let (info, store) = trackWithRunningFill(engine, url: "https://s/x.ass", preserveASSMarkup: true)
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.sidecarTask == nil)
        #expect(engine.isLoadingSubtitles)

        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        store.markFinished()
        let raw = SubtitleCue(id: 0, startTime: 1, endTime: 2, body: .text("0,0,Default,,0,0,0,,{\\i1}hi"))
        finishFill(engine, id: info.id, complete: true,
                   styled: SidecarDecodeResult(cues: [raw], assHeader: "[Script Info]"))
        #expect(engine.sidecarTask == nil)
        #expect(engine.subtitleCues.map(\.text) == [raw.text])
        #expect(engine.sidecarASSHeader == "[Script Info]")
        #expect(!engine.isLoadingSubtitles)

        engine.clearSubtitle()
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.sidecarTask == nil)
        #expect(engine.subtitleCues.map(\.text) == [raw.text])
    }

    @Test("a selection that moved on before the fill landed is left alone")
    func movedOnSelectionIsLeftAlone() throws {
        let engine = try AetherEngine()
        let (info, _) = trackWithRunningFill(engine, url: "https://s/x.vtt")
        engine.selectSubtitleTrack(index: info.id)
        engine.clearSubtitle()
        finishFill(engine, id: info.id, complete: false)
        #expect(engine.sidecarTask == nil)
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(!engine.isLoadingSubtitles)
    }

    @Test("a superseded fill run's completion does not end the wait")
    func staleFillRunIsIgnored() throws {
        let engine = try AetherEngine()
        let (info, _) = trackWithRunningFill(engine, url: "https://s/x.vtt")
        engine.selectSubtitleTrack(index: info.id)
        finishFill(engine, id: info.id, complete: false, generation: engine.externalStoreFillGeneration &- 1)
        #expect(engine.runningExternalStoreFillIDs.contains(info.id))
        #expect(engine.sidecarTask == nil)
        #expect(engine.isLoadingSubtitles)
    }

    @Test("a track still queued behind another track's fill decodes on its own, as before")
    func queuedTrackDecodes() throws {
        let engine = try AetherEngine()
        let (info, _) = trackWithRunningFill(engine, url: "https://s/x.vtt")
        engine.runningExternalStoreFillIDs = [info.id + 1]
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.sidecarTask != nil)
    }

    @Test("a plain track whose store is gone decodes rather than waiting on a fill it cannot use")
    func plainTrackWithoutStoreDecodes() throws {
        let engine = try AetherEngine()
        let (info, _) = trackWithRunningFill(engine, url: "https://s/x.vtt")
        engine.testHookInstallNativeStores([])
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.sidecarTask != nil)
    }

    private actor OutcomeLog {
        var outcomes: [AetherEngine.ExternalSubtitleFillOutcome] = []
        func add(_ outcome: AetherEngine.ExternalSubtitleFillOutcome) { outcomes.append(outcome) }
    }

    @Test("one fill pass gives the store plain text and reports a styled ASS track's raw events")
    func fillReportsStyledDecode() async throws {
        let dir = FileManager.default.temporaryDirectory
        let ass = dir.appendingPathComponent("silo-600-\(UUID().uuidString).ass")
        let srt = dir.appendingPathComponent("silo-600-\(UUID().uuidString).srt")
        try Self.assFile.write(to: ass, atomically: true, encoding: .utf8)
        try "1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i>\n".write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ass); try? FileManager.default.removeItem(at: srt) }

        let log = OutcomeLog()
        let assStore = NativeSubtitleCueStore(), srtStore = NativeSubtitleCueStore()
        for (url, store, id) in [(ass, assStore, 100_000), (srt, srtStore, 100_001)] {
            await AetherEngine.runExternalSubtitleFill(job: .init(
                url: url, headers: [:], targets: [.init(streamIndex: nil, store: store, externalID: id)],
                preserveASSMarkup: true)) { await log.add($0) }
        }

        let outcomes = await log.outcomes
        #expect(outcomes.map(\.externalID) == [100_000, 100_001])
        #expect(outcomes.map(\.complete) == [true, true])
        // The store holds the same plain-text reading a fill without markup wrote.
        #expect(assStore.snapshotCues().compactMap(\.text) == ["Hello world"])
        #expect(assStore.isFinished)
        let styled = try #require(outcomes[0].styled)
        #expect(styled.assHeader?.contains("[V4+ Styles]") == true)
        #expect(styled.cues.first?.text?.contains("{\\i1}Hello{\\i0} world") == true)
        // SubRip keeps no markup, so the store's cues are the overlay's and nothing extra is kept.
        #expect(outcomes[1].styled == nil)
        #expect(srtStore.snapshotCues().compactMap(\.text) == ["Hello"])
    }

    private static let assFile = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}Hello{\\i0} world
    """
}
