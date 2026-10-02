// Real HTTPS-to-HTTP redirects through `HLSOriginRelay`, with synthetic credentials only. The TLS
// leg needs the self-signed loopback certificate accepted, which is a write to the process-global
// trust evaluator, so the suite nests under `LiveTrustEvaluatorTests`. `Process` is macOS-only.
#if os(macOS)

    import Foundation
    import Testing

    @testable import AetherEngine

    extension LiveTrustEvaluatorTests {
        /// PR #2 review: once a request chain has reached HTTPS, no credential header may cross a
        /// later cleartext hop, whether the static headers or the provider supplied it.
        @Suite("Redirect authorization scope across an HTTPS-to-HTTP downgrade")
        struct RedirectAuthorizationScopeTests {

            private static let bearer = "Bearer synthetic-test-only"

            @Test("A provider's credentials are dropped from the HTTP hop; other headers still go")
            func providerCredentialsDroppedOnDowngrade() async throws {
                try await Self.withDowngradeOrigin { origin in
                    let asked = AskedURLs()
                    let provider = HTTPRequestAuthorization { url, _ in
                        asked.append(url)
                        return ["Authorization": Self.bearer, "X-Test-Client": "aether"]
                    }
                    let body = try await provider.data(from: origin.url, maximumBytes: 1024)
                    #expect(String(decoding: body, as: UTF8.self) == "redirect-body")
                    #expect(asked.schemes == ["https", "http"])
                    let requests = try origin.requests()
                    #expect(requests.map(\.scheme) == ["https", "http"])
                    #expect(requests.map(\.authorization) == [Self.bearer, nil])
                    #expect(requests.map(\.client) == ["aether", "aether"])
                }
            }

            @Test("A provider that throws for the HTTP destination stops the chain before it is sent")
            func providerRefusalStopsDowngradedRequest() async throws {
                try await Self.withDowngradeOrigin { origin in
                    let asked = AskedURLs()
                    let provider = HTTPRequestAuthorization { url, _ in
                        asked.append(url)
                        guard url.scheme == "https" else { throw URLError(.userAuthenticationRequired) }
                        return ["Authorization": Self.bearer]
                    }
                    await #expect(throws: URLError(.badServerResponse)) {
                        _ = try await provider.data(from: origin.url, maximumBytes: 1024)
                    }
                    // The provider was asked about the HTTP destination, so the HTTP server seeing
                    // nothing is its refusal and not an earlier failure.
                    #expect(asked.schemes == ["https", "http"])
                    let requests = try origin.requests()
                    #expect(requests.map(\.scheme) == ["https"])
                    #expect(requests.map(\.authorization) == [Self.bearer])
                }
            }

            @Test("Static credentials are stripped from the HTTP redirect request")
            func staticCredentialsStrippedOnDowngrade() async throws {
                try await Self.withDowngradeOrigin { origin in
                    let relay = HLSOriginRelay()
                    defer { relay.stop() }
                    let (body, finalURL) = try await relay.fetchPlaylist(
                        origin.url, headers: ["Authorization": Self.bearer])
                    #expect(body == "redirect-body")
                    #expect(finalURL.scheme == "http")
                    let requests = try origin.requests()
                    #expect(requests.map(\.scheme) == ["https", "http"])
                    #expect(requests.map(\.authorization) == [Self.bearer, nil])
                }
            }

            @Test("A provider can explicitly allow an anonymous HTTP redirect destination")
            func providerAllowsAnonymousDowngradedDestination() async throws {
                try await Self.withDowngradeOrigin { origin in
                    let provider = HTTPRequestAuthorization { url, _ in
                        url.scheme == "https" ? ["Authorization": Self.bearer] : [:]
                    }
                    let body = try await provider.data(from: origin.url, maximumBytes: 1024)
                    #expect(String(decoding: body, as: UTF8.self) == "redirect-body")
                    let requests = try origin.requests()
                    #expect(requests.map(\.scheme) == ["https", "http"])
                    #expect(requests.map(\.authorization) == [Self.bearer, nil],
                            "the redirect must use the new provider result, not replay the old bearer")
                }
            }

            @Test("An HTTP origin the host chose still receives the provider's credentials")
            func providerCredentialsReachAConfiguredHTTPOrigin() async throws {
                try await Self.withDowngradeOrigin { origin in
                    let provider = HTTPRequestAuthorization { _, _ in ["Authorization": Self.bearer] }
                    let body = try await provider.data(from: origin.plainURL, maximumBytes: 1024)
                    #expect(String(decoding: body, as: UTF8.self) == "redirect-body")
                    let requests = try origin.requests()
                    #expect(requests.map(\.scheme) == ["http"])
                    #expect(requests.map(\.authorization) == [Self.bearer])
                }
            }

            private static func withDowngradeOrigin(
                _ body: (TLSDowngradeOrigin) async throws -> Void
            ) async throws {
                let origin = try await TLSDowngradeOrigin()
                defer { origin.stop() }
                try await LiveTrustEvaluatorTests.withEvaluator({ $0.host == "127.0.0.1" }) {
                    try await body(origin)
                }
            }

            /// The resolver is `@Sendable` and runs off the test's task.
            private final class AskedURLs: @unchecked Sendable {
                private let lock = NSLock()
                private var urls: [URL] = []

                func append(_ url: URL) { lock.withLock { urls.append(url) } }
                var schemes: [String?] { lock.withLock { urls.map(\.scheme) } }
            }
        }
    }

    /// Paired loopback origins record headers before responding, so awaiting the transfer also
    /// makes the request log observable without a sleep. No traffic leaves this machine.
    private final class TLSDowngradeOrigin {
        struct Request: Decodable {
            let scheme: String
            let authorization: String?
            let client: String?
        }

        /// The HTTPS origin, which redirects to `plainURL`.
        let url: URL
        /// The HTTP origin, which answers with the body.
        let plainURL: URL
        private let launched: PythonOrigin.Launched

        /// Every request either origin received, in order. Empty when none arrived.
        func requests() throws -> [Request] {
            let log = launched.workDir.appendingPathComponent("requests.jsonl")
            guard FileManager.default.fileExists(atPath: log.path) else { return [] }
            return try String(decoding: Data(contentsOf: log), as: UTF8.self).split(separator: "\n").map {
                try JSONDecoder().decode(Request.self, from: Data($0.utf8))
            }
        }

        init() async throws {
            launched = try #require(await PythonOrigin.launch(
                prefix: "aether-tls-downgrade", script: Self.serverPy,
                files: ["cert.pem": SelfSignedTLSOrigin.certPEM,
                        "key.pem": SelfSignedTLSOrigin.keyPEM]))
            let plainPort = try String(
                contentsOf: launched.workDir.appendingPathComponent("plain.port"), encoding: .utf8)
            url = try #require(URL(string: "https://127.0.0.1:\(launched.port)/start"))
            plainURL = try #require(URL(string: "http://127.0.0.1:\(plainPort)/end"))
        }

        func stop() { launched.stop() }

        private static let serverPy = """
            import http.server, json, ssl, threading

            lock = threading.Lock()

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"
                def log_message(self, *args): pass
                def do_GET(self):
                    secure = isinstance(self.connection, ssl.SSLSocket)
                    with lock:
                        with open("requests.jsonl", "a") as f:
                            f.write(json.dumps({"scheme": "https" if secure else "http",
                                                "authorization": self.headers.get("Authorization"),
                                                "client": self.headers.get("X-Test-Client")}) + "\\n")
                    if secure:
                        self.send_response(302)
                        self.send_header("Location", f"http://127.0.0.1:{plain.server_address[1]}/end")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                    else:
                        body = b"redirect-body"
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)

            plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=plain.serve_forever, daemon=True).start()
            with open("plain.port", "w") as f:
                f.write(str(plain.server_address[1]))
            secure = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain("cert.pem", "key.pem")
            secure.socket = context.wrap_socket(secure.socket, server_side=True)
            print("READY", secure.server_address[1], flush=True)
            secure.serve_forever()
            """
    }

#endif
