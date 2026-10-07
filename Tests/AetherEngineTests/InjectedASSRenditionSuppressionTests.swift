// `PythonOrigin` needs `Process`, which exists only on macOS.
#if os(macOS)

import Testing
import Foundation
import AVFoundation
@testable import AetherEngine

/// AE#616 measures the bypass clock off the injected rendition AVPlayer presents, and only while one
/// is selected. A styled ASS track the host draws itself used to deselect its plain rendition, which
/// left `sourceTime` on item time for exactly the host that draws from it. The rendition now stays
/// selected behind a suppressing legible output. These run against a real `AVPlayerItem`, because
/// whether AVPlayer draws a rendition is decided by the item's outputs and media selection, not by
/// anything the engine records about them.
@Suite("Overlay-drawn injected ASS keeps its rendition selected (AE#616)", .timeLimit(.minutes(2)))
@MainActor
struct InjectedASSRenditionSuppressionTests {

    private static let script = #"""
    import http.server, time
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *args): pass
        def do_GET(self):
            if self.path == "/slow.ass":
                time.sleep(2)
                body = open("sub.ass", "rb").read()
                self.send_response(200)
                self.send_header("Content-Type", "text/x-ssa")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/master.m3u8":
                body = b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nmedia.m3u8\n"
            elif self.path == "/media.m3u8":
                body = b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n"
            else:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print("READY %d" % server.server_address[1], flush=True)
    server.serve_forever()
    """#

    private static let assScript = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 180
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,24,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\b1}Styled caption
    """

    private static func suppressed(_ item: AVPlayerItem) -> Bool {
        item.outputs.contains { ($0 as? AVPlayerItemLegibleOutput)?.suppressesPlayerRendering == true }
    }

    /// The served master names each injected rendition plainly, so its display name is that NAME.
    private static func selectedName(_ item: AVPlayerItem, in group: AVMediaSelectionGroup) -> String? {
        item.currentMediaSelection.selectedMediaOption(in: group)?.displayName
    }

    @Test("The overlay hides the selected rendition, a native surface shows it, and Off deselects it")
    func overlayASSKeepsTheRenditionSelectedButHidden() async throws {
        let origin = try #require(await PythonOrigin.launch(prefix: "aether-ass-suppress", script: Self.script))
        defer { origin.stop() }
        let ass = FileManager.default.temporaryDirectory
            .appendingPathComponent("suppressed-\(UUID().uuidString).ass")
        try Self.assScript.write(to: ass, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ass) }

        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        let master = try #require(URL(string: "http://127.0.0.1:\(origin.port)/master.m3u8"))
        _ = try await engine.load(url: master, options: LoadOptions(
            nativeRemoteHLS: true, preserveASSMarkup: true,
            externalSubtitles: [ExternalSubtitleTrack(url: ass, name: "Styled ASS")], autoplay: false))

        let id = AetherEngine.externalSubtitleTrackIDBase
        let name = try #require(engine.injectedSubtitleRenditionNames[id])
        let item = try #require(engine.currentAVPlayer?.currentItem)
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))

        engine.selectSubtitleTrack(index: id)
        try await waitFor { Self.selectedName(item, in: group) == name && Self.suppressed(item) }
        // The host's overlay gets the raw events whatever AVPlayer is doing with the rendition.
        try await waitFor { !engine.subtitleCues.isEmpty }
        guard case .text(let raw) = try #require(engine.subtitleCues.first).body else {
            Issue.record("Expected raw ASS events for the host's styled renderer")
            return
        }
        #expect(raw.contains("{\\b1}Styled caption"))

        engine.setNativeSubtitleRendering(true)
        try await waitFor { !Self.suppressed(item) }
        #expect(Self.selectedName(item, in: group) == name)

        engine.setNativeSubtitleRendering(false)
        try await waitFor { Self.selectedName(item, in: group) == name && Self.suppressed(item) }

        // Off takes the rendition down at once and leaves the output: nothing selected draws
        // nothing, and the next styled pick must not uncover a line while it resolves.
        engine.clearSubtitle()
        #expect(Self.selectedName(item, in: group) == nil)
        #expect(Self.suppressed(item))

        engine.selectSubtitleTrack(index: id)
        try await waitFor { Self.selectedName(item, in: group) == name }
        #expect(Self.suppressed(item))
    }

    /// AVPlayer fetches and buffers a selected rendition, and the whole-program .vtt is served only
    /// once extraction finishes. A hidden rendition selected before that holds playback up for a
    /// subtitle nobody sees, and one still selected when the host turns subtitles off and plays is
    /// fetched on into playback. Seen as a stalled start in Silo's authorization playback tests.
    @Test("The hidden rendition waits for its extraction, and Off takes it down at once")
    func hiddenRenditionWaitsForExtraction() async throws {
        let origin = try #require(await PythonOrigin.launch(
            prefix: "aether-ass-slow", script: Self.script, files: ["sub.ass": Self.assScript]))
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop(finalTeardown: true) }
        let master = try #require(URL(string: "http://127.0.0.1:\(origin.port)/master.m3u8"))
        let sidecar = try #require(URL(string: "http://127.0.0.1:\(origin.port)/slow.ass"))
        _ = try await engine.load(url: master, options: LoadOptions(
            nativeRemoteHLS: true, preserveASSMarkup: true,
            externalSubtitles: [ExternalSubtitleTrack(url: sidecar, name: "Styled ASS")], autoplay: false))
        let id = AetherEngine.externalSubtitleTrackIDBase
        let name = try #require(engine.injectedSubtitleRenditionNames[id])
        let item = try #require(engine.currentAVPlayer?.currentItem)
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
        let provider = try #require(engine.remoteHLSSubtitleProxy?.provider)

        engine.selectSubtitleTrack(index: id)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!provider.isFillFinished, "the origin holds the sidecar for two seconds")
        #expect(Self.selectedName(item, in: group) == nil)

        try await waitFor { provider.isFillFinished }
        try await waitFor { Self.selectedName(item, in: group) == name && Self.suppressed(item) }

        engine.clearSubtitle()
        #expect(Self.selectedName(item, in: group) == nil)
    }
}

#endif
