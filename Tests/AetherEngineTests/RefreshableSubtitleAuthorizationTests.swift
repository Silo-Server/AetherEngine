#if os(macOS)
import Foundation
import Testing
@testable import AetherEngine

@Suite("Refreshable subtitle and resource authorization")
struct RefreshableSubtitleAuthorizationTests {
    @Test("Registered ASS reselect, secondary and native stores resolve rotated credentials")
    @MainActor func registeredTrackSurvivesRotation() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let state = SubtitleAuthorizationState()
        let provider = HTTPRequestAuthorization { url, rejected in await state.resolve(url, rejected: rejected) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        let track = ExternalSubtitleTrack(url: origin.url("/subtitle.ass"), name: "Registered ASS",
            httpHeaders: ["Authorization": "Bearer old", "X-Static-Secret": "unused"],
            httpRequestAuthorization: provider, sourceStreamIndex: 0, nativeTimelineOffsetSeconds: 1)
        let info = engine.addExternalSubtitleTrack(track)
        let store = NativeSubtitleCueStore()
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: nil, externalID: info.id, language: "en")]
        engine.testHookInstallNativeStores([store])
        engine.selectSubtitleTrack(index: info.id)
        await engine.sidecarTask?.value
        #expect(engine.subtitleCues.first?.text?.contains("Hello") == true)
        await state.setToken("fresh")
        try origin.setExpectedToken("fresh")
        engine.clearSubtitle()
        engine.selectSubtitleTrack(index: info.id)
        await engine.sidecarTask?.value
        #expect(engine.subtitleCues.first?.text?.contains("Hello") == true)
        #expect(engine.sidecarASSHeader?.contains("[V4+ Styles]") == true)
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.externalSubtitleRegistry[info.id] == track)
        #expect(engine.subtitleTracks.map(\.id) == [info.id])
        #expect(engine.nativeSubtitleTrackTable.first?.externalID == info.id)
        #expect(engine.nativeStore(atOrdinal: 0) === store)
        let carried = engine.captureSubtitleSessionCarryover()
        #expect(carried.externalTracks.first?.id == info.id)
        #expect(carried.externalTracks.first?.track.httpRequestAuthorization === provider)
        #expect(carried.externalTracks.first?.track.sourceStreamIndex == 0)
        #expect(carried.externalTracks.first?.track.nativeTimelineOffsetSeconds == 1)
        engine.selectSecondarySubtitleTrack(index: info.id)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySubtitleCues.first?.text == "Hello")
        let jobs = AetherEngine.externalSubtitleFillJobs(table: engine.nativeSubtitleTrackTable,
            registry: engine.externalSubtitleRegistry, stores: [store], defaultHeaders: [:])
        await AetherEngine.runExternalSubtitleFill(job: try #require(jobs.first))
        #expect(store.isFinished)
        #expect(store.snapshotCues().first?.startTime == 2)
        #expect(store.allCues().first?.start == 1)
        let remote = RemoteHLSSubtitleProvider(tracks: [.init(externalID: info.id, source: track)],
            masterBody: "", programDuration: 10, defaultHeaders: [:], vttFillWaitSeconds: 0)
        remote.startFill()
        await remote.awaitFill()
        if case .ready(let vtt) = remote.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0) {
            #expect(vtt.contains("Hello"))
            #expect(vtt.contains("00:00:01.000"))
        } else { Issue.record("Authorized remote native rendition was not filled") }
        #expect(origin.requests.allSatisfy { $0["x-static-secret"] == nil })
    }

    @Test("A raw bounded resource retries a changed bearer and retains exact bytes")
    func boundedResource() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        try origin.setExpectedToken("fresh")
        let state = SubtitleAuthorizationState()
        let provider = HTTPRequestAuthorization { url, rejected in await state.resolve(url, rejected: rejected) }
        let bytes = try await provider.data(from: origin.url("/raw.m3u8"), maximumBytes: 1024)
        #expect(String(decoding: bytes, as: UTF8.self) == "#EXTM3U\nsegment.ts\n")
        #expect(origin.requests.map { $0["authorization"] } == ["Bearer old", "Bearer fresh"])
    }
    @Test("Raw sidecar relay streams unknown-length bytes before the origin finishes")
    func unknownLengthStreaming() async throws {
        let origin = try #require(TricklingOrigin(slices: 2, pauseSeconds: 20, declaresLength: false))
        defer { origin.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { _, _ in [:] }, rawResources: true)
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { relay.stop(); server.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/sidecar.m3u8")!
        let entry = try #require(server.relayURL(for: url))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: entry)
        request.timeoutInterval = 2
        let start = Date()
        let (bytes, response) = try await session.bytes(for: request)
        var iterator = bytes.makeAsyncIterator()
        #expect(try await iterator.next() == 0x47)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(response.expectedContentLength == -1)
    }

    @Test("Encoded sidecar response lengths describe the delivered decoded bytes")
    func compressedSidecar() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer old"] }
        let url = origin.url("/compressed.ass")
        let result = try await SubtitleDecoder.decodeFile(url: url, httpRequestAuthorization: provider)
        #expect(result.cues.first?.text == "Hello")
        // Compare the complete decompressed bytes across the real loopback socket, so a cue
        // that happened to fit before a mistaken Content-Length cannot hide truncation.
        let expected = try await provider.data(from: url, maximumBytes: 4096)
        let relay = HLSOriginRelay(authorization: provider, rawResources: true)
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { relay.stop(); server.stop() }
        let entry = try #require(server.relayURL(for: url))
        let (actual, _) = try await URLSession.shared.data(from: entry)
        #expect(actual == expected)
        #expect(String(decoding: actual, as: UTF8.self).hasSuffix("Hello\n"))
    }

    @Test("Rejected speculative suffix ranges preserve authorized sidecar decoding")
    func suffixRangeFallback() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer old"] }
        let result = try await SubtitleDecoder.decodeFile(url: origin.url("/no-suffix.ass"),
            httpRequestAuthorization: provider)
        #expect(result.cues.first?.text == "Hello")
        #expect(origin.requests.contains { $0["range"]?.hasPrefix("bytes=-") == true })
        #expect(origin.requests.contains { $0["range"]?.hasPrefix("bytes=0-") == true })
    }

    @Test("Terminal sidecar refusal does not wait for a stalled error body", arguments: ["/slow403", "/slow401"])
    func terminalRefusal(path: String) async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let state = SubtitleAuthorizationState()
        let provider = HTTPRequestAuthorization { url, rejected in await state.resolve(url, rejected: rejected) }
        let url = origin.url(path)
        let start = Date()
        let decode = Task { try await SubtitleDecoder.decodeFile(url: url, httpRequestAuthorization: provider) }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); decode.cancel() }
        defer { watchdog.cancel() }
        await #expect(throws: (any Error).self) { _ = try await decode.value }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(origin.requests.count >= (path == "/slow401" ? 2 : 1))
        #expect(await state.challenges >= (path == "/slow401" ? 1 : 0))
    }

    @Test("Raw sidecar framing completes and preserves bytes", arguments: [false, true])
    func rawBodyCompletes(declaresLength: Bool) async throws {
        let origin = try #require(TricklingOrigin(slices: 2, pauseSeconds: 0, declaresLength: declaresLength))
        defer { origin.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { _, _ in [:] }, rawResources: true)
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { relay.stop(); server.stop() }
        let entry = try #require(server.relayURL(for: URL(string: "http://127.0.0.1:\(origin.port)/opaque.m3u8")!))
        let (body, _) = try await URLSession.shared.data(from: entry)
        #expect(body.count == TricklingOrigin.totalBytes(slices: 2))
        #expect(body.allSatisfy { $0 == 0x47 })
    }

    @Test("Later authorization refusal cannot publish a partial subtitle as complete")
    func lateAuthorizationRefusal() async throws {
        try await MultiSubtitleContainerFixture.withFixture { fixture in
            let origin = try SubtitleAuthorizationOrigin()
            defer { origin.stop() }
            var data = try Data(contentsOf: fixture)
            let segment = try #require(data.range(of: Data([0x18, 0x53, 0x80, 0x67])))
            data.replaceSubrange(segment.upperBound..<(segment.upperBound + 8),
                                 with: [0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
            // A large trailing EBML Void forces another read after the fixture's subtitle packets.
            data.append(contentsOf: [0xec, 0x30, 0x00, 0x00])
            data.append(Data(repeating: 0, count: 1024 * 1024))
            try data.write(to: origin.directory.appendingPathComponent("container.mkv"))
            let scope = SubtitleAuthorizationRevocation()
            let provider = HTTPRequestAuthorization { _, _ in try await scope.resolve() }
            let url = origin.url("/revoked.mkv")
            let start = Date()
            let decode = Task { try await SubtitleDecoder.decodeFile(url: url, httpRequestAuthorization: provider) }
            let watchdog = Task { try await Task.sleep(for: .seconds(8)); decode.cancel() }
            defer { watchdog.cancel() }
            do {
                let result = try await decode.value
                Issue.record("Published \(result.cues.count) cues after scope revocation")
            } catch { }
            #expect(Date().timeIntervalSince(start) < 5, "Authorization refusal must abort AVIO without a reconnect loop")
            #expect(await scope.calls > 1)
            #expect(origin.requests.allSatisfy { $0["authorization"] == "Bearer old" })
        }
    }

    @Test("Resource cap rejects both declared and chunked oversized bodies", arguments: ["/large", "/chunked"])
    func resourceLimit(path: String) async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer old"] }
        await #expect(throws: (any Error).self) {
            _ = try await provider.data(from: origin.url(path), maximumBytes: 32)
        }
        #expect(origin.requests.count == 1)
    }

    @Test("The resource limit admits exactly the cap")
    func exactResourceLimit() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer old"] }
        #expect(try await provider.data(from: origin.url("/large"), maximumBytes: 65536).count == 65536)
    }

    @Test("Invalid resource schemes never invoke the provider")
    func resourceScheme() async {
        let provider = HTTPRequestAuthorization { _, _ in
            Issue.record("Non-HTTP URL reached authorization")
            return [:]
        }
        await #expect(throws: (any Error).self) {
            _ = try await provider.data(from: URL(fileURLWithPath: "/missing/font.zip"), maximumBytes: 1024)
        }
    }

    @Test("Resource and decoder redirects cannot escape the credential scope", arguments: [false, true])
    func refusedRedirect(decoding: Bool) async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { url, _ in
            guard url.host == "127.0.0.1" else { throw URLError(.userAuthenticationRequired) }
            return ["Authorization": "Bearer old"]
        }
        await #expect(throws: (any Error).self) {
            if decoding {
                _ = try await SubtitleDecoder.decodeFile(url: origin.url("/foreign"),
                    httpRequestAuthorization: provider)
            } else { _ = try await provider.data(from: origin.url("/foreign"), maximumBytes: 1024) }
        }
        #expect(!origin.requests.isEmpty)
        #expect(origin.requests.allSatisfy { $0["path"] == "/foreign" })
    }

    @Test("Scope refusal happens before sending any request", arguments: [false, true])
    func refusedScope(decoding: Bool) async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { _, _ in throw URLError(.userAuthenticationRequired) }
        await #expect(throws: (any Error).self) {
            if decoding {
                _ = try await SubtitleDecoder.decodeFile(url: origin.url("/subtitle.ass"),
                    httpHeaders: ["Authorization": "Bearer old"], httpRequestAuthorization: provider)
            } else { _ = try await provider.data(from: origin.url("/large"), maximumBytes: 1024) }
        }
        #expect(origin.requests.isEmpty)
    }

    @Test("Unchanged bearer does not retry a resource 401")
    func unchangedBearer() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        try origin.setExpectedToken("fresh")
        let provider = HTTPRequestAuthorization { _, rejected in
            ["Authorization": "Bearer old", "X-Other": rejected == nil ? "first" : "changed"]
        }
        await #expect(throws: (any Error).self) {
            _ = try await provider.data(from: origin.url("/large"), maximumBytes: 1024)
        }
        #expect(origin.requests.count == 1)
    }

    @Test("A second rejected bearer ends the resource request")
    func secondRejection() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        try origin.setExpectedToken("unavailable")
        let state = SubtitleAuthorizationState()
        let provider = HTTPRequestAuthorization { url, rejected in await state.resolve(url, rejected: rejected) }
        await #expect(throws: (any Error).self) {
            _ = try await provider.data(from: origin.url("/large"), maximumBytes: 1024)
        }
        #expect(origin.requests.map { $0["authorization"] } == ["Bearer old", "Bearer fresh"])
        #expect(await state.challenges == 1)
    }

    @Test("Decoder probes and range reads can refresh a rejected bearer")
    func decoderRefresh() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        try origin.setExpectedToken("fresh")
        let state = SubtitleAuthorizationState()
        let provider = HTTPRequestAuthorization { url, rejected in await state.resolve(url, rejected: rejected) }
        let result = try await SubtitleDecoder.decodeFile(url: origin.url("/subtitle.ass"),
            httpRequestAuthorization: provider)
        #expect(result.cues.first?.text == "Hello")
        // AVIO may probe and start its range read concurrently, so both can reach the
        // server before either refreshes. Each rejected upstream request gets one retry.
        let challenges = await state.challenges
        let rejected = origin.requests.filter { $0["authorization"] == "Bearer old" }
        #expect(challenges >= 1)
        #expect(challenges == rejected.count)
        #expect(origin.requests.last?["authorization"] == "Bearer fresh")
        #expect(origin.requests.contains { $0["range"] != nil })
    }

    @Test("Cancellation wakes an uncooperative authorizer and discards its late answer", arguments: [false, true])
    func cancelAuthorizer(decoding: Bool) async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let gate = SubtitleAuthorizationGate()
        let provider = HTTPRequestAuthorization { _, _ in await gate.wait() }
        let url = origin.url(decoding ? "/subtitle.ass" : "/large")
        let task = Task {
            if decoding {
                _ = try await SubtitleDecoder.decodeFile(url: url,
                    httpRequestAuthorization: provider)
            } else { _ = try await provider.data(from: url, maximumBytes: 1024) }
        }
        for _ in 0..<400 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        let start = Date()
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 2)
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(origin.requests.isEmpty)
    }

    @Test("Cancellation stops a resource whose response has not arrived")
    func cancelTransfer() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer old"] }
        let url = origin.url("/slow")
        let task = Task { try await provider.data(from: url, maximumBytes: 1024) }
        for _ in 0..<400 where origin.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(origin.requests.count == 1)
        let start = Date()
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("A whole-transfer deadline stops a trickling resource")
    func transferDeadline() async throws {
        let origin = try SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let provider = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer old"] }
        // A short injected deadline exercises the same transport path as the public API;
        // DocumentedConstantsTests pins that API's production budget.
        let relay = HLSOriginRelay(authorization: provider, resourceTimeout: 10,
                                   deadline: Date().addingTimeInterval(0.15))
        defer { relay.stop() }
        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await relay.fetchData(origin.url("/trickle"), maximumBytes: 1024)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("Native fill grouping keeps distinct provider identities separate")
    func groupingIdentity() throws {
        let url = URL(string: "https://example.test/subtitles.mkv")!
        let first = HTTPRequestAuthorization { _, _ in [:] }
        let second = HTTPRequestAuthorization { _, _ in [:] }
        let tracks = [first, first, second].enumerated().map { index, provider in
            ExternalSubtitleTrack(url: url, httpRequestAuthorization: provider, sourceStreamIndex: Int32(index))
        }
        let table = tracks.indices.map {
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000 + $0, language: nil)
        }
        let stores = tracks.map { _ in NativeSubtitleCueStore() }
        let registry = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { (100_000 + $0.offset, $0.element) })
        let jobs = AetherEngine.externalSubtitleFillJobs(table: table, registry: registry, stores: stores, defaultHeaders: [:])
        let remote = RemoteHLSSubtitleProvider.fillJobs(tracks: tracks.enumerated().map {
            .init(externalID: 100_000 + $0.offset, source: $0.element)
        }, stores: stores, defaultHeaders: [:])
        for grouped in [jobs, remote] {
            #expect(grouped.count == 2)
            #expect(grouped.first?.targets.map(\.streamIndex) == [0, 1])
            #expect(grouped.last?.targets.map(\.streamIndex) == [2])
            #expect(grouped.first?.httpRequestAuthorization === first)
            #expect(grouped.last?.httpRequestAuthorization === second)
        }
        #expect(ExternalSubtitleTrack(url: url).httpRequestAuthorization == nil)
        #expect(ExternalSubtitleTrack(url: url, httpRequestAuthorization: first)
                != ExternalSubtitleTrack(url: url, httpRequestAuthorization: second))
    }

    @Test("Authorized multistream fill and individual fallback preserve requested indexes")
    func multiStreamFill() async throws {
        try await MultiSubtitleContainerFixture.withFixture { fixture in
            let origin = try SubtitleAuthorizationOrigin()
            defer { origin.stop() }
            try FileManager.default.copyItem(at: fixture, to: origin.directory.appendingPathComponent("container.mkv"))
            let provider = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer old"] }
            let english = NativeSubtitleCueStore()
            let spanish = NativeSubtitleCueStore()
            let invalid = NativeSubtitleCueStore()
            let job = AetherEngine.ExternalSubtitleFillJob(url: origin.url("/container.mkv"), headers: [:],
                httpRequestAuthorization: provider,
                targets: [.init(streamIndex: MultiSubtitleContainerFixture.englishStreamIndex, store: english),
                          .init(streamIndex: MultiSubtitleContainerFixture.spanishStreamIndex, store: spanish)])
            await AetherEngine.runExternalSubtitleFill(job: job)
            #expect(english.snapshotCues().compactMap(\.text) == MultiSubtitleContainerFixture.englishLines)
            #expect(spanish.snapshotCues().compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
            let fallback = AetherEngine.ExternalSubtitleFillJob(url: job.url, headers: [:],
                httpRequestAuthorization: provider,
                targets: [.init(streamIndex: 99, store: invalid),
                          .init(streamIndex: MultiSubtitleContainerFixture.spanishStreamIndex, store: NativeSubtitleCueStore())])
            await AetherEngine.runExternalSubtitleFill(job: fallback)
            #expect(!invalid.isFinished)
            #expect(fallback.targets.last?.store.snapshotCues().compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
            #expect(origin.requests.allSatisfy { $0["authorization"] == "Bearer old" })
        }
    }

}

actor SubtitleAuthorizationRevocation {
    var calls = 0
    func resolve() throws -> [String: String] {
        calls += 1
        guard calls == 1 else { throw URLError(.userAuthenticationRequired) }
        return ["Authorization": "Bearer old"]
    }
}

actor SubtitleAuthorizationGate {
    var entered = false
    private var continuations: [CheckedContinuation<[String: String], Never>] = []
    private var released = false
    func wait() async -> [String: String] {
        entered = true
        if released { return ["Authorization": "Bearer old"] }
        return await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        continuations.forEach { $0.resume(returning: ["Authorization": "Bearer old"]) }
        continuations.removeAll()
    }
}

actor SubtitleAuthorizationState {
    var token = "old"
    var challenges = 0
    func setToken(_ value: String) { token = value }
    func resolve(_ url: URL, rejected: [String: String]?) -> [String: String] {
        if rejected != nil { challenges += 1; token = "fresh" }
        return ["Authorization": "Bearer \(token)"]
    }
}

final class SubtitleAuthorizationOrigin {
    let port: UInt16
    let directory: URL
    private let process: Process
    init() throws {
        let launched = try #require(PythonOrigin.launch(prefix: "aether-subtitle-auth", script: Self.script))
        port = launched.port
        process = launched.process
        directory = launched.workDir
        try setExpectedToken("old")
    }
    func setExpectedToken(_ value: String) throws {
        try value.write(to: directory.appendingPathComponent("token"), atomically: true, encoding: .utf8)
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    var requests: [[String: String]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONDecoder().decode([String: String].self, from: Data($0.utf8))
        }
    }
    func stop() { process.terminate(); try? FileManager.default.removeItem(at: directory) }
    private static let script = #"""
    import http.server, json, time, gzip
    ASS = b"[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 480\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,Hello\n"
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *args): pass
        def do_GET(self):
            headers = {k.lower():v for k,v in self.headers.items()}
            headers["path"] = self.path
            with open("requests.jsonl", "a") as f: f.write(json.dumps(headers)+"\n")
            if self.path in ["/slow403", "/slow401"]:
                self.send_response(403 if self.path == "/slow403" else 401)
                self.send_header("Content-Length", "65536")
                self.send_header("Content-Type", "application/octet-stream")
                self.end_headers()
                # CFNetwork may await initial bytes before delivering response metadata.
                self.wfile.write(b"!" * 1024)
                self.wfile.flush()
                time.sleep(30)
                return
            expected = open("token").read()
            status, body, extra = 200, ASS, {}
            if headers.get("authorization") != "Bearer " + expected:
                status, body = 401, b"rejected"
            elif self.path == "/foreign":
                status, body = 302, b""
                extra["Location"] = "http://localhost:%s/subtitle.ass" % self.server.server_address[1]
            elif self.path == "/compressed.ass":
                body = gzip.compress(ASS)
                extra["Content-Encoding"] = "gzip"
                extra["Content-Type"] = "application/octet-stream"
            elif self.path == "/raw.m3u8":
                body = b"#EXTM3U\nsegment.ts\n"
                extra["Content-Type"] = "application/vnd.apple.mpegurl"
            elif self.path in ["/container.mkv", "/revoked.mkv"]: body = open("container.mkv", "rb").read()
            elif self.path == "/trickle":
                self.send_response(200)
                self.send_header("Content-Length", "100")
                self.end_headers()
                for i in range(100):
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    time.sleep(.1)
                return
            elif self.path == "/large": body = b"x" * 65536
            elif self.path == "/chunked":
                self.send_response(200)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for i in range(64): self.wfile.write(b"400\r\n" + b"x"*1024 + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
                return
            elif self.path == "/slow": time.sleep(30)
            if status == 200 and "range" in headers and self.path != "/compressed.ass":
                selected = headers["range"].split("=",1)[1].split("-",1)
                if not selected[0] and self.path == "/no-suffix.ass":
                    extra["Content-Range"] = "bytes */%s" % len(body)
                    status, body = 416, b""
                else:
                    start = int(selected[0]) if selected[0] else max(0, len(body) - int(selected[1]))
                    end = min(int(selected[1]) if selected[0] and selected[1] else len(body)-1, len(body)-1)
                    if self.path == "/revoked.mkv": end = min(end, start + 65535)
                    extra["Content-Range"] = "bytes %s-%s/%s" % (start, end, len(body))
                    status, body = 206, body[start:end+1]
                    if self.path == "/no-suffix.ass": time.sleep(.05)
            self.send_response(status)
            for k,v in extra.items(): self.send_header(k,v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print("READY", server.server_address[1], flush=True)
    server.serve_forever()
    """#
}
#endif
