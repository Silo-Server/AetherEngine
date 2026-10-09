import Testing
import Foundation
@testable import AetherEngine

/// #316: the loopback origin that carries host-declared sidecars as legible renditions in front of a
/// remote HLS master. These drive the real server over a real socket, because the contract that matters
/// is what AVPlayer would actually fetch: a verbatim master, a whole-program WebVTT playlist, and
/// nothing else. A media request reaching this server at all would mean the rewrite moved the media.
@Suite("Remote-HLS subtitle proxy origin (#316)")
struct RemoteHLSSubtitleProxyTests {

    private static let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="subs"
    https://jf.test/videos/42/main.m3u8
    """

    private static func track(_ id: Int, url: URL, headers: [String: String]? = nil,
                              streamIndex: Int32? = nil) -> RemoteHLSSubtitleProvider.Track {
        RemoteHLSSubtitleProvider.Track(
            externalID: id,
            source: ExternalSubtitleTrack(url: url, name: "English", language: "en",
                                          httpHeaders: headers, sourceStreamIndex: streamIndex))
    }

    /// Async on purpose: the callback form parked a cooperative thread on a semaphore for the whole
    /// round trip, and every one of these tests runs inside a several-hundred-test parallel run. A
    /// transport error is thrown rather than folded into status 0, so a failure names itself instead
    /// of arriving as "expected 200, got 0".
    private static func get(_ path: String, port: UInt16) async throws -> (status: Int, body: String) {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Fill jobs

    @Test("Sidecars sharing a container are decoded in one pass")
    func fillJobsGroupByContainer() {
        let container = URL(string: "https://origin.test/movie.mkv")!
        let tracks = [Self.track(100_000, url: container, streamIndex: 2),
                      Self.track(100_001, url: container, streamIndex: 3)]
        let stores = tracks.map { _ in NativeSubtitleCueStore() }

        let jobs = RemoteHLSSubtitleProvider.fillJobs(tracks: tracks, stores: stores,
                                                      defaultHeaders: [:])
        #expect(jobs.count == 1)
        #expect(jobs[0].targets.map(\.streamIndex) == [2, 3])
    }

    @Test("Differing auth means differing requests, so it splits the jobs")
    func fillJobsSplitOnHeaders() {
        let container = URL(string: "https://origin.test/movie.mkv")!
        let tracks = [Self.track(100_000, url: container, headers: ["X-Token": "a"]),
                      Self.track(100_001, url: container, headers: ["X-Token": "b"])]
        let stores = tracks.map { _ in NativeSubtitleCueStore() }
        #expect(RemoteHLSSubtitleProvider.fillJobs(tracks: tracks, stores: stores,
                                                   defaultHeaders: [:]).count == 2)
    }

    @Test("A track without its own headers inherits the load's")
    func fillJobsInheritDefaultHeaders() {
        let tracks = [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)]
        let stores = tracks.map { _ in NativeSubtitleCueStore() }
        let jobs = RemoteHLSSubtitleProvider.fillJobs(tracks: tracks, stores: stores,
                                                      defaultHeaders: ["Authorization": "Bearer x"])
        #expect(jobs.first?.headers == ["Authorization": "Bearer x"])
    }

    // MARK: - Served endpoints

    @Test("The rewritten master is served verbatim, not rebuilt from provider metadata")
    func masterIsServedVerbatim() async throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1200, defaultHeaders: [:])
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (status, body) = try await Self.get("/\(server.pathToken)/master.m3u8", port: server.port)
        #expect(status == 200)
        #expect(body == Self.master)
    }

    @Test("AVPlayer is pointed at the master even though the provider has no master codecs")
    func playlistURLPrefersTheStaticMaster() throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1200, defaultHeaders: [:])
        #expect(provider.masterCodecs == nil)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        #expect(server.playlistURL?.lastPathComponent == "master.m3u8")
    }

    @Test("The rendition playlist is a finished whole-program VOD playlist")
    func subtitlePlaylistIsWholeProgram() async throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1234.5, defaultHeaders: [:])
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (status, body) = try await Self.get("/\(server.pathToken)/subs_0.m3u8", port: server.port)
        #expect(status == 200)
        #expect(body.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(body.contains("#EXT-X-TARGETDURATION:1235"))
        #expect(body.contains("#EXTINF:1234.500"))
        #expect(body.contains("subs_0_0.vtt"))
        #expect(body.contains("#EXT-X-ENDLIST"))
    }

    @Test("The proxy origin serves no media: a segment request is a 404, not a redirect to the origin")
    func mediaIsNotServed() async throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1200, defaultHeaders: [:])
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        #expect(try await Self.get("/\(server.pathToken)/seg0.mp4", port: server.port).status == 404)
        #expect(try await Self.get("/\(server.pathToken)/init.mp4", port: server.port).status == 404)
    }

    @Test("A decoded sidecar is served as whole-program WebVTT", .timeLimit(.minutes(2)))
    func sidecarBecomesWebVTT() async throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Erste Zeile

        2
        00:00:04,500 --> 00:00:06,000
        Zweite Zeile

        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae316-\(UUID().uuidString).srt")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: file)],
            masterBody: Self.master, programDuration: 60, defaultHeaders: [:],
            vttFillWaitSeconds: 10)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop(); provider.cancelFill() }
        // Await the fill instead of letting the handler's budget race it. The decode is a detached
        // Task, so on a saturated cooperative pool (a parallel test run on a 3-core CI box, 2026-08-08)
        // it gets no thread for tens of seconds, the budget expires, and the request comes back empty.
        provider.startFill()
        await provider.awaitFill()

        let (status, body) = try await Self.get("/\(server.pathToken)/subs_0_0.vtt", port: server.port)
        #expect(status == 200)
        #expect(body.hasPrefix("WEBVTT"))
        #expect(body.contains("Erste Zeile"))
        #expect(body.contains("Zweite Zeile"))
        // Cue times are used verbatim: no loopback producer means no playlist shift.
        #expect(body.contains("00:00:01.000 --> 00:00:03.000"))
    }

    @Test("An unfinished rendition retries and a completed sidecar uses its declared movie offset")
    func unfinishedRenditionRetriesThenUsesOriginalMovieOffset() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-offset-\(UUID().uuidString).srt")
        try "1\n00:10:01,000 --> 00:10:03,000\nAfter reanchor\n\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let track = RemoteHLSSubtitleProvider.Track(externalID: 100_000,
            source: ExternalSubtitleTrack(url: file, nativeTimelineOffsetSeconds: 600))
        let provider = RemoteHLSSubtitleProvider(tracks: [track], masterBody: Self.master,
            programDuration: 60, defaultHeaders: [:], vttFillWaitSeconds: 0)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop(); provider.cancelFill() }
        let path = "/\(server.pathToken)/subs_0_0.vtt"
        let pending = try await Self.get(path, port: server.port)
        #expect(pending.status == 503)
        #expect(!pending.body.contains("WEBVTT"))
        provider.startFill()
        await provider.awaitFill()
        let ready = try await Self.get(path, port: server.port)
        #expect(ready.status == 200)
        #expect(ready.body.contains("00:00:01.000 --> 00:00:03.000"))
        #expect(ready.body.contains("After reanchor"))
    }

    // MARK: - Timestamp anchor

    /// One TS packet opening a PES on PID 0x100 whose header carries only a PTS.
    private static func pesPacket(pts90k: Int64, streamID: UInt8 = 0xE0) -> [UInt8] {
        var packet: [UInt8] = [0x47, 0x41, 0x00, 0x10, 0x00, 0x00, 0x01, streamID, 0x00, 0x00, 0x80, 0x80, 0x05]
        packet += [UInt8(0x21 | ((pts90k >> 29) & 0x0E)),
                   UInt8((pts90k >> 22) & 0xFF),
                   UInt8(((pts90k >> 14) & 0xFE) | 1),
                   UInt8((pts90k >> 7) & 0xFF),
                   UInt8(((pts90k << 1) & 0xFE) | 1)]
        return packet + [UInt8](repeating: 0xFF, count: 188 - packet.count)
    }

    /// A PAT ahead of the PES, as a muxer writes it: a section the probe has to step over.
    private static func tsSegment(videoPTS90k: Int64) -> Data {
        let pat: [UInt8] = [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
                            0x00, 0x01, 0xF0, 0x00]
        return Data(pat + [UInt8](repeating: 0xFF, count: 188 - pat.count)
                    + pesPacket(pts90k: videoPTS90k - 9000, streamID: 0xC0)
                    + pesPacket(pts90k: videoPTS90k))
    }

    #if os(macOS)
    /// A finished origin on disk: a master, a variant of five 6 s segments, and only the segment files
    /// passed in, so a probe that reads any other segment fails. The sidecar has a cue at 20 s. The
    /// playlists are served over HTTP by `servedVTT`, because the bounded playlist fetch only accepts an
    /// HTTP answer.
    private static func diskOrigin(segments: [Int: Data]) throws -> (dir: URL, master: URL, srt: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ae-anchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("v"), withIntermediateDirectories: true)
        try "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nv/media.m3u8\n"
            .write(to: dir.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        var media = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<5 { media += "#EXTINF:6.000000,\nseg\(index).ts\n" }
        media += "#EXT-X-ENDLIST\n"
        try media.write(to: dir.appendingPathComponent("v/media.m3u8"), atomically: true, encoding: .utf8)
        for (index, data) in segments { try data.write(to: dir.appendingPathComponent("v/seg\(index).ts")) }
        let srt = dir.appendingPathComponent("en.srt")
        try "1\n00:00:20,000 --> 00:00:22,000\nAnchored line\n\n".write(to: srt, atomically: true, encoding: .utf8)
        return (dir, dir.appendingPathComponent("master.m3u8"), srt)
    }

    /// Prepares the proxy over a disk origin opened at 13 s (segment 2, which starts at 12 s), waits for
    /// the decode and the probe, and returns the served rendition.
    private static func servedVTT(segments: [Int: Data]) async throws -> String {
        let origin = try diskOrigin(segments: segments)
        defer { try? FileManager.default.removeItem(at: origin.dir) }
        let script = """
        import http.server

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=r"\(origin.dir.path)", **kwargs)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        print("READY", server.server_address[1], flush=True)
        server.serve_forever()
        """
        let launched = try #require(await PythonOrigin.launch(prefix: "aether-anchor-origin", script: script))
        defer { launched.stop() }
        let master = try #require(URL(string: "http://127.0.0.1:\(launched.port)/master.m3u8"))
        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: master, tracks: [Self.track(100_000, url: origin.srt)], httpHeaders: [:],
            needsRelay: false, startPosition: 13))
        defer { prepared.tearDown() }
        let provider = try #require(prepared.provider)
        await provider.awaitFill()
        await provider.awaitTimestampAnchor()
        let (status, body) = try await Self.get("/\(prepared.server.pathToken)/subs_0_0.vtt",
                                                port: prepared.server.port)
        #expect(status == 200)
        #expect(body.contains("Anchored line"))
        // Cue times stay in source time; only the header moves them.
        #expect(body.contains("00:00:20.000 --> 00:00:22.000"))
        return body
    }

    @Test("An origin whose media runs 10 s ahead of its playlist anchors the rendition there",
          .timeLimit(.minutes(2)))
    func renditionAnchorsToOriginTimestamps() async throws {
        // ffmpeg's MPEG-TS muxer with -copyts -max_delay 5000000: source time + 10 s.
        let body = try await Self.servedVTT(segments: [2: Self.tsSegment(videoPTS90k: (12 + 10) * 90_000)])
        #expect(body.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n"))
    }

    @Test("An origin whose media sits on its playlist timeline keeps the plain body", .timeLimit(.minutes(2)))
    func zeroOffsetKeepsPlainBody() async throws {
        let body = try await Self.servedVTT(segments: [2: Self.tsSegment(videoPTS90k: 12 * 90_000)])
        #expect(body.hasPrefix("WEBVTT\n\n"))
        #expect(!body.contains("X-TIMESTAMP-MAP"))
    }

    @Test("A probe that cannot read the segment keeps the plain body", .timeLimit(.minutes(2)))
    func probeFailureKeepsPlainBody() async throws {
        // Only segment 0 exists: the probe asks for the segment the load opens on, and that one fails.
        let body = try await Self.servedVTT(segments: [0: Self.tsSegment(videoPTS90k: 10 * 90_000)])
        #expect(body.hasPrefix("WEBVTT\n\n"))
        #expect(!body.contains("X-TIMESTAMP-MAP"))
    }

    /// A Jellyfin-style origin restarts its transcode at the keyframe before the requested slot
    /// (`-noaccurate_seek -copyts`): the segment at 12 s starts at media 10.5 s, and media time stays
    /// source time. The probe reads -1.5 s, but that is the keyframe gap, not an offset of the media
    /// timestamps. The rendition must keep cue time on media time, so the line lands on its frame and
    /// AE#616 measures the 1.5 s by which AVPlayer's item time leads the picture.
    @Test("A keyframe-restart origin keeps the plain body and leaves the lead to AE#616", .timeLimit(.minutes(2)))
    func keyframeRestartLeavesLeadToCueClock() async throws {
        let slot = 12.0
        let keyframe = 10.5
        let body = try await Self.servedVTT(segments: [2: Self.tsSegment(videoPTS90k: Int64(keyframe * 90_000))])
        #expect(body.hasPrefix("WEBVTT\n\n"))
        #expect(!body.contains("X-TIMESTAMP-MAP"))

        // AVPlayer places the first loaded segment at its slot, so item time = media time + lead, and it
        // shows a cue at media time cue + (MPEGTS - LOCAL) of the served map.
        let lead = slot - keyframe
        let cue = (start: 20.0, text: "Anchored line")
        let shownAtItem = cue.start + Self.cueToMediaShift(body) + lead
        var clock = RemoteHLSCueClock()
        clock.setCues([cue])
        let landing = clock.observe(strings: [], itemTime: slot)
        #expect(landing == nil) // the landing delivery teaches nothing
        let measured = clock.observe(strings: [cue.text], itemTime: shownAtItem)
        let offset = try #require(measured)
        // The line shows on its own frame: the frame on screen at item t is source time t - lead.
        #expect(abs((shownAtItem - lead) - cue.start) < 0.001)
        // AE#616 measures that lead, so sourceTime (item less the offset) is the presented frame's.
        #expect(abs(offset - lead) < 0.001)
    }

    /// Seconds a served rendition's `X-TIMESTAMP-MAP` adds to cue time to reach media time; 0 without one.
    private static func cueToMediaShift(_ body: String) -> Double {
        guard let line = body.split(separator: "\n").first(where: { $0.hasPrefix("X-TIMESTAMP-MAP=") }),
              let mpegts = line.firstRange(of: "MPEGTS:"), let local = line.firstRange(of: "LOCAL:") else { return 0 }
        let ticks = Double(line[mpegts.upperBound...].prefix(while: \.isNumber)) ?? 0
        let parts = line[local.upperBound...].split(separator: ":").compactMap { Double($0) }
        let localSeconds = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : 0
        return ticks / 90_000 - localSeconds
    }
    #endif

    @Test("The probe reads the segment the load opens on, with EXT-X-DEFINE variables substituted")
    func probeTargetsTheStartSegment() throws {
        let body = """
        #EXTM3U
        #EXT-X-VERSION:8
        #EXT-X-DEFINE:NAME="q",VALUE="token=abc"
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4?{$q}"
        #EXTINF:6.0,
        seg_00000.m4s?{$q}
        #EXTINF:6.0,
        seg_00001.m4s?{$q}
        #EXTINF:6.0,
        seg_00002.m4s?{$q}
        #EXT-X-ENDLIST
        """
        let url = try #require(URL(string: "https://origin.test/hls/main.m3u8"))
        guard case .media(let media) = try HLSPlaylistParser.parse(body) else {
            Issue.record("not a media playlist")
            return
        }
        let resumed = RemoteHLSTimestampAnchor.target(mediaPlaylistBody: body, media: media, at: url,
                                                      startPosition: 7.5)
        #expect(resumed?.segmentURL.absoluteString == "https://origin.test/hls/seg_00001.m4s?token=abc")
        #expect(resumed?.initURL?.absoluteString == "https://origin.test/hls/init.mp4?token=abc")
        #expect(resumed?.segmentStart == 6)
        let fromStart = RemoteHLSTimestampAnchor.target(mediaPlaylistBody: body, media: media, at: url,
                                                        startPosition: nil)
        #expect(fromStart?.segmentURL.lastPathComponent == "seg_00000.m4s")
        #expect(fromStart?.segmentStart == 0)
    }

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
            + Array(type.utf8) + payload
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func trak(id: UInt32, timescale: UInt32, handler: String) -> [UInt8] {
        let tkhd = box("tkhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(id) + [UInt8](repeating: 0, count: 68))
        let mdhd = box("mdhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(timescale) + be32(0) + [0, 0, 0, 0])
        let hdlr = box("hdlr", [0, 0, 0, 0] + be32(0) + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))
        return box("trak", tkhd + box("mdia", mdhd + hdlr))
    }

    private static func traf(id: UInt32, decodeTime: UInt64) -> [UInt8] {
        let tfdt = box("tfdt", [1, 0, 0, 0] + be32(UInt32(decodeTime >> 32)) + be32(UInt32(decodeTime & 0xFFFF_FFFF)))
        return box("traf", box("tfhd", [0, 0, 0, 0] + be32(id)) + tfdt)
    }

    @Test("fMP4 anchors on the video track's tfdt over its own timescale")
    func fragmentAnchorUsesVideoTrack() {
        let initSegment = Data(Self.box("ftyp", Array("iso6".utf8) + Self.be32(0))
            + Self.box("moov", Self.trak(id: 2, timescale: 48_000, handler: "soun")
                  + Self.trak(id: 1, timescale: 12_800, handler: "vide")))
        let fragment = Data(Self.box("styp", Array("msdh".utf8) + Self.be32(0))
            + Self.box("moof", Self.box("mfhd", [0, 0, 0, 0] + Self.be32(3))
                  + Self.traf(id: 2, decodeTime: 0) + Self.traf(id: 1, decodeTime: 22 * 12_800))
            + [0x00, 0x10, 0x00, 0x00] + Array("mdat".utf8)) // truncated mdat, as a ranged read leaves it
        let anchor = RemoteHLSTimestampAnchor.anchorSeconds(segmentHead: fragment, initSegment: initSegment,
                                                            segmentStart: 12)
        #expect(anchor == 10)
    }

    #if os(macOS)
    /// An fMP4 probe makes two sequential reads. The budget covers both: a URL session's timeouts are per
    /// task, so a segment that arrives late followed by an init segment that never does used to take the
    /// segment's wait plus a whole budget, past the provider's `.vtt` wait.
    @Test("The probe budget bounds both fMP4 reads together", .timeLimit(.minutes(1)))
    func probeBudgetCoversBothReads() async throws {
        let budget: TimeInterval = 4
        let segmentDelay = 2.5
        let script = """
        import http.server, time

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                with open("requests.log", "a") as log:
                    log.write(self.path + "\\n")
                if self.path.startswith("/init.mp4"):
                    time.sleep(60)
                    return
                time.sleep(\(segmentDelay))
                body = b"\\x00\\x00\\x00\\x10stypmsdh\\x00\\x00\\x00\\x00"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        print("READY", server.server_address[1], flush=True)
        server.serve_forever()
        """
        let launched = try #require(await PythonOrigin.launch(prefix: "aether-anchor-stall", script: script))
        defer { launched.stop() }
        let base = "http://127.0.0.1:\(launched.port)"
        let target = RemoteHLSTimestampAnchor.Target(
            segmentURL: try #require(URL(string: "\(base)/seg_00000.m4s")),
            initURL: try #require(URL(string: "\(base)/init.mp4")), segmentStart: 0)

        let started = Date()
        let anchor = await RemoteHLSTimestampAnchor.probe(target,
                                                          credentials: CredentialScope(headers: [:], anchors: []),
                                                          authorization: nil, budget: budget)
        let elapsed = Date().timeIntervalSince(started)

        #expect(anchor == nil)
        // Per-task timeouts would end this at segmentDelay + budget (6.5 s).
        #expect(elapsed < budget + 1.5, "probe took \(elapsed) s against a \(budget) s budget")
        let log = try String(contentsOf: launched.workDir.appendingPathComponent("requests.log"), encoding: .utf8)
        #expect(log.split(separator: "\n") == ["/seg_00000.m4s", "/init.mp4"])
    }
    #endif

    @Test("A negative anchor moves to the cue side instead of wrapping the 33-bit timestamp")
    func negativeAnchorUsesLocalTime() {
        #expect(WebVTTBuilder.timestampMap(anchorSeconds: 10) == "X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000")
        #expect(WebVTTBuilder.timestampMap(anchorSeconds: -2.5) == "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:02.500")
    }

    /// An extended-size box whose 64-bit size is `Int.max`, after a complete box, used to trap on
    /// `offset + size` while walking an origin's init segment or fragment.
    @Test("An extended box size past the data ends the box walk instead of trapping")
    func oversizedExtendedBoxEndsTheWalk() {
        let oversized: [UInt8] = Self.be32(1) + Array("moov".utf8)
            + Self.be32(UInt32(UInt64(Int.max) >> 32)) + Self.be32(UInt32(UInt64(Int.max) & 0xFFFF_FFFF))
        let ftyp = Self.box("ftyp", Array("iso6".utf8) + Self.be32(0))
        let initSegment = Data(ftyp + Self.box("moov", Self.trak(id: 1, timescale: 12_800, handler: "vide")))
        let fragment = Data(Self.box("moof", Self.box("mfhd", [0, 0, 0, 0] + Self.be32(3))
            + Self.traf(id: 1, decodeTime: 22 * 12_800)))
        #expect(RemoteHLSTimestampAnchor.anchorSeconds(segmentHead: fragment, initSegment: Data(ftyp + oversized),
                                                       segmentStart: 0) == nil)
        #expect(RemoteHLSTimestampAnchor.anchorSeconds(segmentHead: Data(ftyp + oversized), initSegment: initSegment,
                                                       segmentStart: 0) == nil)
        #expect(RemoteHLSTimestampAnchor.anchorSeconds(segmentHead: fragment, initSegment: initSegment,
                                                       segmentStart: 12) == 10)
    }

    /// A version-1 `tfdt` of `UInt64.max` over a timescale of 1 is a finite anchor too large for `Int64`
    /// ticks; it used to trap building the rendition's header.
    @Test("An origin anchor too large for Int64 ticks wraps to 33 bits, and a non-finite one is dropped")
    func hugeAnchorWrapsWithoutTrapping() {
        let initSegment = Data(Self.box("moov", Self.trak(id: 1, timescale: 1, handler: "vide")))
        let fragment = Data(Self.box("moof", Self.traf(id: 1, decodeTime: .max)))
        let anchor = RemoteHLSTimestampAnchor.anchorSeconds(segmentHead: fragment, initSegment: initSegment,
                                                            segmentStart: 0)
        #expect(anchor == Double(UInt64.max))
        #expect(WebVTTBuilder.timestampMap(anchorSeconds: Double(UInt64.max))
            == "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000") // 2^64 * 90000 is a multiple of 2^33
        #expect(WebVTTBuilder.timestampMap(anchorSeconds: 1e15) // 9e19 ticks mod 2^33
            == "X-TIMESTAMP-MAP=MPEGTS:3643277312,LOCAL:00:00:00.000")
        for value in [Double.infinity, -.infinity, .nan] {
            #expect(WebVTTBuilder.timestampMap(anchorSeconds: value) == "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000")
        }
        #expect(RemoteHLSTimestampAnchor.anchorSeconds(segmentHead: fragment, initSegment: initSegment,
                                                       segmentStart: .nan) == nil)
    }

    // MARK: - Rendition metadata

    @Test("Renditions are numbered in subs_{ordinal} order and carry the host's own labels")
    func renditionsMirrorTheDeclaration() {
        let tracks = [
            RemoteHLSSubtitleProvider.Track(
                externalID: 100_000,
                source: ExternalSubtitleTrack(url: URL(string: "https://o/en.srt")!,
                                              name: "English", language: "en")),
            RemoteHLSSubtitleProvider.Track(
                externalID: 100_001,
                source: ExternalSubtitleTrack(url: URL(string: "https://o/de.srt")!,
                                              name: "Deutsch SDH", language: "de",
                                              isHearingImpaired: true))
        ]
        let renditions = RemoteHLSSubtitleProvider.renditions(for: tracks)
        #expect(renditions.map(\.ordinal) == [0, 1])
        #expect(renditions.map(\.name) == ["English", "Deutsch SDH"])
        #expect(renditions.map(\.isSDH) == [false, true])
    }

    @Test("A bitmap sidecar is not rendition material")
    func bitmapSidecarIsExcluded() {
        let pgs = ExternalSubtitleTrack(url: URL(string: "https://o/en.sup")!)
        let srt = ExternalSubtitleTrack(url: URL(string: "https://o/en.srt")!)
        let hinted = ExternalSubtitleTrack(url: URL(string: "https://o/stream?id=3")!, formatHint: "ass")
        #expect(!pgs.isTextFormat)
        #expect(srt.isTextFormat)
        #expect(hinted.isTextFormat)
    }

    // MARK: - Dedupe against the surfaced legible group

    @MainActor
    @Test("An injected rendition is not published a second time under a legible id")
    func injectedRenditionsAreNotDoubleListed() {
        let declared = [ExternalSubtitleTrack(url: URL(string: "https://o/en.srt")!, name: "English",
                                              language: "en")
            .makeTrackInfo(id: AetherEngine.externalSubtitleTrackIDBase, fallbackNumber: 1)]
        let legible = [
            RemoteHLSMediaSelection.LegibleOption(displayName: "Français", extendedLanguageTag: "fr",
                                                  isDefault: false, isForced: false, isSDH: false),
            RemoteHLSMediaSelection.LegibleOption(displayName: "English", extendedLanguageTag: "en",
                                                  isDefault: false, isForced: false, isSDH: false)
        ]

        let merged = RemoteHLSMediaSelection.mergedSubtitleTracks(
            existing: declared, legible: legible, injectedNames: ["English"])

        #expect(merged.map(\.name) == ["English", "Français"])
        // The surviving rendition keeps its index in the FULL group, which is what selection indexes back.
        #expect(merged.map(\.id) == [AetherEngine.externalSubtitleTrackIDBase,
                                     RemoteHLSMediaSelection.subtitleTrackIDBase + 0])
    }

    /// Measured against Apple's own CMAF master: `displayName` is a LOCALIZED language name, not the
    /// rendition's NAME (an injected `NAME="DE"` reads back as "German", the origin's "简体中文" as
    /// "Chinese"). Keying the dedupe on the display name therefore matched nothing and the sidecar was
    /// published twice, once as its external track and once as a legible one.
    @MainActor
    @Test("Dedupe keys on the playlist NAME, not on AVFoundation's localized display name")
    func dedupeSurvivesTheLocalizedDisplayName() {
        let localized = RemoteHLSMediaSelection.LegibleOption(
            displayName: "German", extendedLanguageTag: "de",
            isDefault: false, isForced: false, isSDH: false, playlistName: "DE")

        let merged = RemoteHLSMediaSelection.mergedSubtitleTracks(
            existing: [], legible: [localized], injectedNames: ["DE"])

        #expect(merged.isEmpty)
    }

    // MARK: - NAT-1: a hostile EXTINF never reaches Int(Double)

    private static func seg(_ duration: Double) -> HLSMediaSegment {
        HLSMediaSegment(uri: "s.ts", duration: duration, discontinuityBefore: false)
    }

    @Test("An infinite, negative or absurd EXTINF is refused before it becomes a program duration")
    func rejectsHostileSegmentDurations() {
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(.infinity)])
        }
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(.nan)])
        }
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(-1)])
        }
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            // Finite, but a sum this large is still out of range (audit NAT-1's "finite but huge" case).
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(5e18), Self.seg(5e18)])
        }
    }

    @Test("An ordinary EXTINF sum is unaffected")
    func sumsOrdinaryDurations() throws {
        let total = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(5), Self.seg(6.5)])
        #expect(total == 11.5)
    }

    @Test("A non-finite or absurd program duration is clamped before it reaches the provider's segment")
    func providerClampsAHostileProgramDuration() {
        let providerInf = RemoteHLSSubtitleProvider(
            tracks: [], masterBody: Self.master, programDuration: .infinity, defaultHeaders: [:])
        #expect(providerInf.segmentDuration(at: 0).isFinite)

        let providerHuge = RemoteHLSSubtitleProvider(
            tracks: [], masterBody: Self.master, programDuration: 5e18, defaultHeaders: [:])
        #expect(providerHuge.segmentDuration(at: 0) <= RemoteHLSSubtitleProxy.maxProgramDurationSeconds)

        let providerNaN = RemoteHLSSubtitleProvider(
            tracks: [], masterBody: Self.master, programDuration: .nan, defaultHeaders: [:])
        #expect(providerNaN.segmentDuration(at: 0) == 1)
    }

    @Test("Without an m3u8/NAME the display name is still the key")
    func injectionKeyFallsBackToDisplayName() {
        let bare = RemoteHLSMediaSelection.LegibleOption(
            displayName: "German", extendedLanguageTag: "de",
            isDefault: false, isForced: false, isSDH: false)
        #expect(RemoteHLSMediaSelection.injectionKey(bare) == "German")
    }
}
