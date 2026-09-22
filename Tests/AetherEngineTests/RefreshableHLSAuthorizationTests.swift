import Foundation
import Testing
@testable import AetherEngine

#if os(macOS)
@Suite("Refreshable native HLS authorization")
struct RefreshableHLSAuthorizationTests {
    @MainActor
    @Test("Native HLS authorization forces a relay and strips origin headers from the asset")
    func nativeLoadRequiresRelay() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let authorization = HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer fresh"] }
        try await engine.loadRemoteHLS(url: URL(string: "http://127.0.0.1:9/media.m3u8")!,
            options: LoadOptions(httpHeaders: ["Authorization": "Bearer frozen"],
                                 httpRequestAuthorization: authorization, nativeRemoteHLS: true, autoplay: false))
        #expect(engine.remoteHLSSubtitleProxy?.server.relay != nil)
        #expect(engine.nativeHost?.sessionContract.httpHeaders.isEmpty == true)
    }

    @MainActor
    @Test("A required relay failure cannot silently load the original URL")
    func unavailableRequiredRelayFailsLoad() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var failed = false
        do {
            try await engine.loadRemoteHLS(url: URL(fileURLWithPath: "/missing/media.m3u8"),
                options: LoadOptions(httpRequestAuthorization: HTTPRequestAuthorization { _, _ in [:] },
                                     nativeRemoteHLS: true, autoplay: false))
        } catch { failed = true }
        #expect(failed)
        #expect(engine.nativeHost?.avPlayer.currentItem == nil)
    }

    @Test("Subtitle preflight authorizes redirects and variants through the same transport")
    func authorizedSubtitlePreflight() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let track = RemoteHLSSubtitleProvider.Track(externalID: 100_000,
            source: ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing/subtitle.srt"), name: "English"))
        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: origin.url("/master.m3u8"), tracks: [track], httpHeaders: ["X-Static-Secret": "never-forward"],
            needsRelay: true, httpRequestAuthorization: HTTPRequestAuthorization { url, _ in
                ["Authorization": "Bearer \(url.path)"]
            }))
        defer { prepared.tearDown() }
        #expect(prepared.servesSubtitleRenditions)
        #expect(origin.requests.map { $0["authorization"] } == ["Bearer /master.m3u8", "Bearer /redirect", "Bearer /final/media.m3u8"])
        #expect(origin.requests.allSatisfy { $0["x-static-secret"] == nil })
    }

    @Test("Optional subtitle refusal keeps the required authorizing relay")
    func refusedSubtitlePreflightRetainsAuthorization() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let track = RemoteHLSSubtitleProvider.Track(externalID: 100_000,
            source: ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing/subtitle.srt"), name: "English"))
        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: origin.url("/media"), tracks: [track], httpHeaders: [:],
            needsRelay: true, httpRequestAuthorization: HTTPRequestAuthorization { _, _ in
                ["Authorization": "Bearer fresh"]
            }))
        defer { prepared.tearDown() }
        #expect(!prepared.servesSubtitleRenditions)
        let (_, response) = try await URLSession.shared.data(from: prepared.masterURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(origin.requests.count == 2)
        #expect(origin.requests.allSatisfy { $0["authorization"] == "Bearer fresh" })
    }

    @MainActor
    @Test("Stopping a native load cancels pending subtitle authorization")
    func stoppingPreflight() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let gate = AuthorizationGate()
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.externalSubtitleRegistry[100_000] = ExternalSubtitleTrack(
            url: URL(fileURLWithPath: "/missing/subtitle.srt"), name: "English")
        let load = Task {
            try await engine.loadRemoteHLS(url: origin.url("/master.m3u8"),
                options: LoadOptions(httpRequestAuthorization: HTTPRequestAuthorization { _, _ in await gate.wait() },
                                     nativeRemoteHLS: true, autoplay: false))
        }
        for _ in 0..<200 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        let start = Date()
        engine.stop()
        var canceled = false
        do { try await load.value } catch is CancellationError { canceled = true }
        #expect(canceled)
        #expect(Date().timeIntervalSince(start) < 1)
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(origin.requests.isEmpty)
    }

    @Test("Optional subtitle preflight retains its short network budget")
    func subtitlePreflightNetworkBudget() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let track = RemoteHLSSubtitleProvider.Track(externalID: 100_000,
            source: ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing/subtitle.srt"), name: "English"))
        let started = Date()
        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: origin.url("/slow.m3u8"), tracks: [track], httpHeaders: [:],
            needsRelay: true, httpRequestAuthorization: HTTPRequestAuthorization { _, _ in [:] }))
        defer { prepared.tearDown() }
        #expect(!prepared.servesSubtitleRenditions)
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test("Subtitle preflight has one deadline across a delayed redirect chain")
    func subtitlePreflightRedirectBudget() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let track = RemoteHLSSubtitleProvider.Track(externalID: 100_000,
            source: ExternalSubtitleTrack(url: URL(fileURLWithPath: "/missing/subtitle.srt"), name: "English"))
        let started = Date()
        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: origin.url("/chain/0.m3u8"), tracks: [track], httpHeaders: [:],
            needsRelay: true, httpRequestAuthorization: HTTPRequestAuthorization { _, _ in [:] }))
        defer { prepared.tearDown() }
        #expect(!prepared.servesSubtitleRenditions)
        #expect(Date().timeIntervalSince(started) < 6)
        #expect(origin.requests.count <= 5)
    }

    @Test("Provider equality is identity and absent by default")
    func providerIdentity() {
        let first = HTTPRequestAuthorization { _, _ in [:] }
        let second = HTTPRequestAuthorization { _, _ in [:] }
        #expect(first == first)
        #expect(first != second)
        #expect(LoadOptions().httpRequestAuthorization == nil)
        #expect(LoadOptions(httpRequestAuthorization: first) == LoadOptions(httpRequestAuthorization: first))
        #expect(LoadOptions(httpRequestAuthorization: first) != LoadOptions(httpRequestAuthorization: second))
    }

    @Test("A playlist-discovered origin does not inherit credentials")
    func refusedDiscoveredOrigin() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { url, _ in
            guard url.host == "127.0.0.1" else { throw URLError(.userAuthenticationRequired) }
            return ["Authorization": "Bearer private"]
        })
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        relay.admit(origin.url("/media.m3u8"))
        let playlist = relay.rewritePlaylist("#EXTM3U\nhttp://localhost:\(origin.port)/foreign.ts\n",
            relativeTo: origin.url("/media.m3u8"), port: server.port, token: server.pathToken)
        let entry = try #require(URL(string: String(playlist.split(separator: "\n")[1])))
        let (_, response) = try await URLSession.shared.data(from: entry)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(origin.requests.isEmpty)
    }

    @Test("A challenge after a redirect reports the responding URL and its actual headers")
    func redirectedChallenge() async throws {
        let state = AuthorizationState()
        let result = try await exercise("/redirect-protected", state: state)
        #expect(result.status == 200)
        #expect(result.requests.map { $0["path"] } == ["/redirect-protected", "/protected", "/protected"])
        #expect(await state.challengeURLs.map(\.path) == ["/protected"])
        #expect(await state.challenges.first?["Authorization"] == "Bearer old")
    }

    @Test("Authorized segment bytes stream before the origin finishes")
    func authorizedStreaming() async throws {
        let upstream = try #require(await TricklingOrigin(slices: 2, pauseSeconds: 20))
        defer { upstream.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { _, _ in ["Authorization": "Bearer fresh"] })
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let origin = URL(string: "http://127.0.0.1:\(upstream.port)/movie.ts")!
        let entry = try #require(server.relayURL(for: origin))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: entry)
        request.timeoutInterval = 10
        let started = Date()
        let (bytes, response) = try await session.bytes(for: request)
        var iterator = bytes.makeAsyncIterator()
        #expect(try await iterator.next() == 0x47)
        #expect(Date().timeIntervalSince(started) < 8)
        #expect((response as? HTTPURLResponse)?.expectedContentLength == Int64(TricklingOrigin.totalBytes(slices: 2)))
    }

    @Test("Every fetch uses the current complete application headers")
    func credentialsChangeBetweenRequests() async throws {
        let state = AuthorizationState()
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { url, rejected in
            await state.resolve(url, rejected: rejected)
        })
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        relay.admit(origin.url("/media"), httpHeaders: ["X-Static-Secret": "never-forward"])
        let entry = try #require(server.relayURL(for: origin.url("/media")))
        _ = try await URLSession.shared.data(from: entry)
        await state.setToken("fresh")
        _ = try await URLSession.shared.data(from: entry)
        #expect(origin.requests.map { $0["authorization"] } == ["Bearer old", "Bearer fresh"])
        #expect(origin.requests.allSatisfy { $0["x-static-secret"] == nil })
    }

    @Test("A 401 retries once with changed credentials before exposing a response")
    func challengeRefresh() async throws {
        let state = AuthorizationState()
        let result = try await exercise("/protected", state: state)
        #expect(result.status == 200)
        #expect(result.body == "media")
        #expect(result.requests.map { $0["authorization"] } == ["Bearer old", "Bearer fresh"])
        let challenges = await state.challenges
        #expect(challenges.count == 1)
        #expect(challenges.first?["Authorization"] == "Bearer old")
        #expect(challenges.first?["Range"] == "bytes=10-14")
    }

    @Test("An unchanged Authorization does not retry, even if other headers change")
    func unchangedCredential() async throws {
        let state = AuthorizationState(refreshToken: "old")
        let result = try await exercise("/protected", state: state)
        #expect(result.status == 401)
        #expect(result.requests.count == 1)
    }

    @Test("A second 401 passes through without another refresh")
    func secondRejection() async throws {
        let state = AuthorizationState()
        let result = try await exercise("/always401", state: state)
        #expect(result.status == 401)
        #expect(result.requests.count == 2)
        #expect(await state.challenges.count == 1)
    }

    @Test("Authorization cannot replace the transport Range or Host")
    func transportHeaders() async throws {
        let result = try await exercise("/range", state: AuthorizationState())
        #expect(result.status == 206)
        #expect(result.body == "01234")
        #expect(result.contentRange == "bytes 10-14/100")
        #expect(result.requests.first?["range"] == "bytes=10-14")
        #expect(result.requests.first?["host"]?.hasPrefix("127.0.0.1:") == true)
    }

    @Test("A redirect destination must authorize independently and may refuse")
    func refusedRedirect() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { url, _ in
            guard url.host == "127.0.0.1" else { throw URLError(.userAuthenticationRequired) }
            return ["Authorization": "Bearer private"]
        })
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let entry = try #require(server.relayURL(for: origin.url("/foreign")))
        let (_, response) = try await URLSession.shared.data(from: entry)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(origin.requests.count == 1)
    }

    @Test("Static redirects preserve same-origin credentials and strip foreign credentials",
          arguments: ["/redirect", "/foreign"])
    func staticRedirectCredentialScope(path: String) async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let headers = ["Authorization": "Bearer private", "Proxy-Authorization": "private",
                       "Cookie": "private", "x-Emby-Token": "private",
                       "X-Emby-Authorization": "private", "X-MediaBrowser-Token": "private",
                       "User-Agent": "SyntheticPlayer", "X-Transport": "preserved"]
        let relay = HLSOriginRelay()
        relay.admit(origin.url(path), httpHeaders: headers)
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let entry = try #require(server.relayURL(for: origin.url(path)))
        let (_, response) = try await URLSession.shared.data(from: entry)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(origin.requests.count == 2)
        let redirected = try #require(origin.requests.last)
        for (name, value) in headers {
            let preserved = path == "/redirect" || name == "User-Agent" || name == "X-Transport"
            #expect(redirected[name.lowercased()] == (preserved ? value : nil))
        }
    }

    @Test("An authorized redirect uses new headers and the final playlist base")
    func authorizedRedirect() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { url, _ in
            await MainActor.run { ["Authorization": "Bearer \(url.path)"] }
        })
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let entry = try #require(server.relayURL(for: origin.url("/redirect")))
        let (data, _) = try await URLSession.shared.data(from: entry)
        #expect(origin.requests.map { $0["authorization"] } == ["Bearer /redirect", "Bearer /final/media.m3u8"])
        let line = try #require(String(decoding: data, as: UTF8.self).split(separator: "\n").first { !$0.hasPrefix("#") })
        #expect(HLSOriginRelay.originURL(fromQuery: URL(string: String(line))!.query!) == origin.url("/final/segment.ts"))
    }

    @Test("Stopping wakes a pending resolver and prevents its late result from sending")
    func cancellationDuringAuthorization() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let gate = AuthorizationGate()
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { _, _ in await gate.wait() })
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let entry = try #require(server.relayURL(for: origin.url("/media")))
        let fetch = Task { try await URLSession.shared.data(from: entry) }
        for _ in 0..<200 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        let start = Date()
        relay.stop()
        let (_, response) = try await fetch.value
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(Date().timeIntervalSince(start) < 1)
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(origin.requests.isEmpty)
    }

    @Test("An uncooperative resolver cannot outlive its request budget")
    func authorizationTimeout() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let gate = AuthorizationGate()
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { _, _ in await gate.wait() }, authorizationTimeout: 0.1)
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let entry = try #require(server.relayURL(for: origin.url("/media")))
        let start = Date()
        let (_, response) = try await URLSession.shared.data(from: entry)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(Date().timeIntervalSince(start) < 1)
        await gate.release()
        #expect(origin.requests.isEmpty)
    }

    private func exercise(_ path: String, state: AuthorizationState) async throws
        -> (status: Int, body: String, contentRange: String?, requests: [[String: String]]) {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { url, rejected in
            await state.resolve(url, rejected: rejected)
        })
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let entry = try #require(server.relayURL(for: origin.url(path)))
        var request = URLRequest(url: entry)
        request.setValue("bytes=10-14", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self), http.value(forHTTPHeaderField: "Content-Range"), origin.requests)
    }

    @Test("Redirected playlists resolve relative segments against the final URL")
    func redirectedPlaylistBase() async throws {
        let origin = try await AuthorizationOrigin()
        defer { origin.stop() }
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let entry = try #require(server.relayURL(for: origin.url("/redirect")))
        let (data, response) = try await URLSession.shared.data(from: entry)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let text = String(decoding: data, as: UTF8.self)
        let line = try #require(text.split(separator: "\n").first { !$0.hasPrefix("#") })
        let segment = try #require(URL(string: String(line)))
        #expect(HLSOriginRelay.originURL(fromQuery: segment.query ?? "") == origin.url("/final/segment.ts"))
    }
}

private actor AuthorizationState {
    var token = "old"
    let refreshToken: String
    var challenges: [[String: String]] = []
    var challengeURLs: [URL] = []
    init(refreshToken: String = "fresh") { self.refreshToken = refreshToken }
    func setToken(_ token: String) { self.token = token }
    func resolve(_ url: URL, rejected: [String: String]?) -> [String: String] {
        if let rejected { challenges.append(rejected); challengeURLs.append(url); token = refreshToken }
        return ["authorization": "Bearer \(token)", "Range": "wrong", "Host": "wrong", "X-Request": UUID().uuidString]
    }
}

private actor AuthorizationGate {
    var entered = false
    var continuation: CheckedContinuation<[String: String], Never>?
    func wait() async -> [String: String] {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: ["Authorization": "Bearer late"]); continuation = nil }
}

private final class AuthorizationOrigin {
    let port: UInt16
    private let process: Process
    private let directory: URL
    init() async throws {
        let launched = try #require(await PythonOrigin.launch(prefix: "aether-auth-origin", script: Self.script))
        port = launched.port
        process = launched.process
        directory = launched.workDir
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    var requests: [[String: String]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode([String: String].self, from: Data(line.utf8))
        }
    }
    func stop() { process.terminate(); try? FileManager.default.removeItem(at: directory) }
    private static let script = #"""
    import http.server, json, time
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *args): pass
        def do_GET(self):
            headers = {k.lower(): v for k,v in self.headers.items()}
            headers["path"] = self.path
            with open("requests.jsonl", "a") as f: f.write(json.dumps(headers) + "\n")
            if self.path == "/slow.m3u8": time.sleep(7)
            if self.path.startswith("/chain/"): time.sleep(1)
            body = b"media"
            status = 200
            extra = {}
            if self.path == "/redirect":
                status = 302
                extra["Location"] = "/final/media.m3u8"
                body = b""
            elif self.path == "/redirect-protected":
                status = 302
                extra["Location"] = "/protected"
                body = b""
            elif self.path == "/foreign":
                status = 302
                extra["Location"] = "http://localhost:%s/final/media.m3u8" % self.server.server_address[1]
                body = b""
            elif self.path.startswith("/chain/") and int(self.path.split("/")[-1].split(".")[0]) < 6:
                hop = int(self.path.split("/")[-1].split(".")[0])
                status = 302
                extra["Location"] = "/chain/%s.m3u8" % (hop + 1)
                body = b""
            elif self.path == "/master.m3u8":
                body = b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n/redirect\n"
                extra["Content-Type"] = "application/vnd.apple.mpegurl"
            elif self.path.endswith(".m3u8"):
                body = b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n"
                extra["Content-Type"] = "application/vnd.apple.mpegurl"
            elif self.path == "/protected" and headers.get("authorization") != "Bearer fresh":
                status, body = 401, b"rejected credentials"
            elif self.path == "/always401":
                status, body = 401, b"still rejected"
            elif self.path == "/range":
                status, body = 206, b"01234"
                extra["Content-Range"] = "bytes 10-14/100"
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
