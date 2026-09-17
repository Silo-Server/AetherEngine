import Testing
import Foundation
import AVFoundation
@testable import AetherEngine

/// #316: `LoadOptions.externalSubtitles` used to be dropped on the nativeRemoteHLS bypass. The branch
/// returns from `load()` well before the probe path's registration step, so a host that declared
/// sidecars at load time got an empty `subtitleTracks` back, with no error and no log line. The only
/// remaining route was `addExternalSubtitleTrack`, which is overlay-only by contract.
@Suite("nativeRemoteHLS bypass keeps declared external subtitles (#316)")
@MainActor
struct Issue316BypassExternalSubtitleTests {

    private static func sidecar(_ name: String, _ lang: String) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(string: "https://origin.test/\(lang).srt")!,
                              name: name, language: lang)
    }

    /// Dead-end URL: the bypass wires its host synchronously and never awaits readiness, so the
    /// registration is observable without a reachable origin (same trick as the #120 attach tests).
    private static let deadEndURL = URL(string: "http://127.0.0.1:9/vod.m3u8")!

    @Test("A load-time declaration is registered on the bypass")
    func bypassRegistersDeclaredTracks() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(
            url: Self.deadEndURL,
            options: LoadOptions(nativeRemoteHLS: true,
                                 externalSubtitles: [Self.sidecar("English", "en"),
                                                     Self.sidecar("Deutsch", "de")]))

        #expect(engine.subtitleTracks.map(\.name) == ["English", "Deutsch"])
        #expect(engine.subtitleTracks.allSatisfy { $0.isExternal })
        #expect(engine.externalSubtitleRegistry.count == 2)
        #expect(engine.subtitleTracks.map(\.id)
                == [AetherEngine.externalSubtitleTrackIDBase,
                    AetherEngine.externalSubtitleTrackIDBase + 1])
    }

    @Test("An empty declaration leaves the bypass exactly as it was")
    func bypassWithoutDeclarationStaysEmpty() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(url: Self.deadEndURL, options: LoadOptions(nativeRemoteHLS: true))
        #expect(engine.subtitleTracks.isEmpty)
        #expect(engine.externalSubtitleRegistry.isEmpty)
    }

    /// The AE#154 discovery assigned the legible list wholesale, so a bypass source carrying its own
    /// renditions delisted the host's sidecars again a beat after they were registered.
    @Test("Surfacing the legible group keeps the external tracks and appends the renditions")
    func legibleSurfacingMergesInsteadOfReplacing() {
        let declared = [
            Self.sidecar("English", "en").makeTrackInfo(id: AetherEngine.externalSubtitleTrackIDBase,
                                                        fallbackNumber: 1)
        ]
        let legible = [
            RemoteHLSMediaSelection.LegibleOption(displayName: "Français", extendedLanguageTag: "fr",
                                                  isDefault: false, isForced: false, isSDH: false)
        ]

        let merged = RemoteHLSMediaSelection.mergedSubtitleTracks(existing: declared, legible: legible)

        #expect(merged.map(\.name) == ["English", "Français"])
        #expect(merged.map(\.id) == [AetherEngine.externalSubtitleTrackIDBase,
                                     RemoteHLSMediaSelection.subtitleTrackIDBase])
        #expect(merged.map(\.isExternal) == [true, false])
    }

    /// With a proxy standing, the sidecar is AVPlayer's to draw. Starting the overlay decode as well
    /// would render the same cues twice, and only the rendition survives PiP / AirPlay.
    @Test("Selecting a proxied sidecar drives media selection, not the overlay decode")
    func selectingAnInjectedTrackSkipsTheSidecarDecode() async throws {
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        _ = try await engine.load(
            url: Self.deadEndURL,
            options: LoadOptions(nativeRemoteHLS: true, preserveASSMarkup: true,
                                 externalSubtitles: [Self.sidecar("English", "en")]))
        let id = AetherEngine.externalSubtitleTrackIDBase
        engine.injectedSubtitleRenditionNames = [id: "English"]

        engine.selectSubtitleTrack(index: id)

        #expect(engine.activeSubtitleTrackIndex == id)
        #expect(engine.isSubtitleActive)
        #expect(engine.loadedSidecarURL == nil, "the overlay decode must not have started")
        #expect(!engine.isLoadingSubtitles)
    }

    @Test("An unknown track ID does not deselect the current native rendition")
    func unknownTrackLeavesInjectedSelectionUntouched() async throws {
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        _ = try await engine.load(url: Self.deadEndURL, options: LoadOptions(
            nativeRemoteHLS: true, externalSubtitles: [Self.sidecar("English", "en")], autoplay: false))
        let id = AetherEngine.externalSubtitleTrackIDBase
        engine.injectedSubtitleRenditionNames = [id: "English"]
        engine.selectSubtitleTrack(index: id)
        #expect(engine.injectedSubtitleSelectionTask != nil)
        #expect(engine.nativeLegibleDeselectPinTask == nil)

        engine.selectSubtitleTrack(index: 999_999)

        #expect(engine.activeSubtitleTrackIndex == id)
        #expect(engine.isSubtitleActive)
        #expect(engine.injectedSubtitleSelectionTask != nil)
        #expect(engine.nativeLegibleDeselectPinTask == nil,
                "Rejecting an unknown track must not issue a native deselection")
    }

    @Test("A delayed automatic subtitle lookup cannot overwrite a later host choice", arguments: [true, false])
    func delayedAutoSelectionHonorsHostChoice(turnOff: Bool) async throws {
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        let styled = ExternalSubtitleTrack(url: URL(string: "https://origin.test/styled.ass")!, name: "Styled ASS")
        _ = try await engine.load(url: Self.deadEndURL, options: LoadOptions(
            nativeRemoteHLS: true, preserveASSMarkup: true,
            externalSubtitles: [Self.sidecar("English", "en"), styled], autoplay: false))
        let englishID = AetherEngine.externalSubtitleTrackIDBase
        engine.injectedSubtitleRenditionNames = [englishID: "English", englishID + 1: "Styled ASS"]
        let item = try #require(engine.currentAVPlayer?.currentItem)
        var finishLookup: CheckedContinuation<Void, Never>?
        let pending = Task { @MainActor in
            await withCheckedContinuation { finishLookup = $0 }
            engine.adoptRemoteHLSSubtitleSelection(name: "Styled ASS", ordinal: 1, from: item)
        }
        for _ in 0..<100 where finishLookup == nil { await Task.yield() }
        let completion = try #require(finishLookup)
        if turnOff { engine.clearSubtitle() }
        else { engine.selectSubtitleTrack(index: englishID) }
        completion.resume()
        await pending.value

        #expect(engine.activeSubtitleTrackIndex == (turnOff ? nil : englishID))
        #expect(engine.isSubtitleActive == !turnOff)
        #expect(engine.loadedSidecarURL == nil,
                "Stale discovery must not start the raw ASS decoder after the host's choice")
        #expect(!engine.isLoadingSubtitles)
    }

    @Test("Preserved injected ASS keeps raw overlay data through native rendering changes")
    func styledInjectedASSUsesOverlayAndRetainsNativeRequest() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("injected-\(UUID().uuidString).ass")
        let script = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 320
        PlayResY: 180
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,24,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,{\\b1}Styled caption
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        _ = try await engine.load(url: Self.deadEndURL, options: LoadOptions(
            nativeRemoteHLS: true, preserveASSMarkup: true,
            externalSubtitles: [ExternalSubtitleTrack(url: url, name: "Styled ASS")], autoplay: false))
        let id = AetherEngine.externalSubtitleTrackIDBase
        engine.injectedSubtitleRenditionNames = [id: "Styled ASS"]
        engine.selectSubtitleTrack(index: id)
        for _ in 0..<100 {
            if !engine.isLoadingSubtitles { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.activeSubtitleTrackIndex == id)
        #expect(engine.loadedSidecarURL == url)
        #expect(engine.sidecarASSHeader?.contains("[V4+ Styles]") == true)
        let cue = try #require(engine.subtitleCues.first)
        guard case .text(let raw) = cue.body else {
            Issue.record("Expected raw ASS events for the host's styled renderer")
            return
        }
        #expect(raw.contains("{\\b1}Styled caption"))
        let header = engine.sidecarASSHeader
        let cues = engine.subtitleCues

        engine.setNativeSubtitleRendering(true)
        #expect(engine.captureSubtitleSessionCarryover().injectedSubtitleRenderingRequested)
        #expect(engine.sidecarASSHeader == header)
        #expect(engine.subtitleCues == cues)
        // Reloads defer media-selection work, but a newer surface request must
        // replace the captured intent before subtitle selection is restored.
        engine.sessionPreservingReloadInFlight = true
        engine.setNativeSubtitleRendering(false)
        #expect(!engine.captureSubtitleSessionCarryover().injectedSubtitleRenderingRequested)
        #expect(engine.pendingNativeRenderingRequest == false)
        engine.sessionPreservingReloadInFlight = false
        engine.restoreSubtitleSelection(from: engine.captureSubtitleSessionCarryover(), resumeAnchor: nil)
        #expect(engine.pendingNativeRenderingRequest == nil)
        #expect(engine.sidecarASSHeader == header)
        #expect(engine.subtitleCues == cues)

        var carryover = engine.captureSubtitleSessionCarryover()
        carryover.injectedSubtitleRenderingRequested = true
        let restored = try AetherEngine()
        defer { restored.stop(finalTeardown: true) }
        restored.applySubtitleSessionCarryoverRegistrations(carryover)
        #expect(restored.injectedSubtitleRenderingRequested)

        engine.clearSubtitle()
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.sidecarASSHeader == nil)
        #expect(engine.injectedSubtitleSelectionTask == nil)
    }

    /// Contrast: without a proxy the same track is the overlay's, exactly as #88 has always had it.
    @Test("Without a proxy the same selection still takes the sidecar path")
    func selectingWithoutProxyUsesTheSidecar() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(
            url: Self.deadEndURL,
            options: LoadOptions(nativeRemoteHLS: true, externalSubtitles: [Self.sidecar("English", "en")]))

        engine.selectSubtitleTrack(index: AetherEngine.externalSubtitleTrackIDBase)

        #expect(engine.loadedSidecarURL?.lastPathComponent == "en.srt")
        #expect(engine.isLoadingSubtitles)
    }

    /// A second surfacing (the readiness retry) must not stack duplicate renditions.
    @Test("Re-surfacing replaces the previous renditions instead of appending to them")
    func resurfacingReplacesRenditions() {
        let legible = [
            RemoteHLSMediaSelection.LegibleOption(displayName: "Français", extendedLanguageTag: "fr",
                                                  isDefault: false, isForced: false, isSDH: false)
        ]
        let first = RemoteHLSMediaSelection.mergedSubtitleTracks(existing: [], legible: legible)
        let second = RemoteHLSMediaSelection.mergedSubtitleTracks(existing: first, legible: legible)
        #expect(second.count == 1)
    }
}
