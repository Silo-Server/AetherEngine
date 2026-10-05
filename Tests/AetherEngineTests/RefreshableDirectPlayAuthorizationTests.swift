// `LoadOptions.httpRequestAuthorization` on direct play. The byte-range reader used to send the
// headers it was opened with for the whole session, so once a host rotated its access token every
// later range was refused and the host had to reload the player at the current position. The reader
// now asks the provider before each request it builds, gives a 401 one retry at the same offset when
// the provider answers with a different credential, and bounds every wait on the provider.
//
// Each test serves a 256 KiB source whose open is bounded to the first 64 KiB, so playback through it
// takes exactly two pump ranges: `bytes=0-65535`, then `bytes=65536-262143`.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Refreshable direct-play authorization", .timeLimit(.minutes(1)))
struct RefreshableDirectPlayAuthorizationTests {
    private static let total = 256 * 1024
    private static let openBytes = 64 * 1024
    private static let secondRange = "bytes=65536-262143"

    @Test("every range request carries the provider's current answer, not the static headers")
    func headersResolvedPerRange() async throws {
        let provider = ProviderLog()
        let server = try Self.origin { _ in true }
        defer { server.stop() }
        let reader = Self.reader(server, headers: ["Authorization": "Bearer static"],
                                 authorization: HTTPRequestAuthorization { _, rejected in
                                     provider.answer(rejected: rejected) { "Bearer \($0)" }
                                 })
        defer { reader.markClosed(); reader.close() }

        let read = try await offThread(reader) {
            try reader.open()
            return Self.read(reader, count: Self.total)
        }

        #expect(read.bytes == Self.total)
        let first = try #require(server.requests.first { $0.range == "bytes=0-65535" })
        let second = try #require(server.requests.first { $0.range == Self.secondRange })
        #expect(first.authorization?.hasPrefix("Bearer ") == true)
        #expect(second.authorization?.hasPrefix("Bearer ") == true)
        #expect(first.authorization != second.authorization, "the second range reused the first answer")
        #expect(server.requests.allSatisfy { $0.authorization != "Bearer static" })
        #expect(provider.rejections.isEmpty)
    }

    @Test("a 401 is retried once at the same offset with the refreshed credential")
    func unauthorizedRetriedOnceWithFreshCredential() async throws {
        let provider = ProviderLog()
        // The token rotates between the two ranges: the origin accepts only the fresh one past the open.
        let server = try Self.origin { $0.range?.hasPrefix("bytes=65536") != true || $0.authorization == "Bearer fresh" }
        defer { server.stop() }
        let reader = Self.reader(server, authorization: HTTPRequestAuthorization { _, rejected in
            provider.answer(rejected: rejected) { _ in rejected == nil && !provider.rotated ? "Bearer stale" : "Bearer fresh" }
        })
        defer { reader.markClosed(); reader.close() }

        let read = try await offThread(reader) {
            try reader.open()
            return Self.read(reader, count: Self.total)
        }

        #expect(read.bytes == Self.total, "playback stopped at \(read.bytes) with \(read.result)")
        let atOffset = server.requests.filter { $0.range == Self.secondRange }.map(\.authorization)
        #expect(atOffset == ["Bearer stale", "Bearer fresh"])
        #expect(provider.rejections == ["Bearer stale"])
    }

    @Test("an unchanged credential fails the read after one 401 instead of reconnecting")
    func unchangedCredentialFailsTheRead() async throws {
        let provider = ProviderLog()
        let server = try Self.origin { $0.range?.hasPrefix("bytes=65536") != true }
        defer { server.stop() }
        let reader = Self.reader(server, authorization: HTTPRequestAuthorization { _, rejected in
            provider.answer(rejected: rejected) { _ in "Bearer stale" }
        })
        defer { reader.markClosed(); reader.close() }

        let read = try await offThread(reader) {
            try reader.open()
            return Self.read(reader, count: Self.total)
        }

        #expect(read.bytes == Self.openBytes)
        #expect(read.result < 0)
        #expect(server.requests.filter { $0.range == Self.secondRange }.count == 1)
        #expect(provider.rejections == ["Bearer stale"])
    }

    @Test("a provider that does not answer fails the open typed, and nothing is sent")
    func providerTimeoutFailsTheOpen() async throws {
        let server = try Self.origin { _ in true }
        defer { server.stop() }
        let reader = Self.reader(server, authorizationTimeout: 0.2,
                                 authorization: HTTPRequestAuthorization { _, _ in
                                     try await Task.sleep(for: .seconds(60))
                                     return [:]
                                 })
        defer { reader.markClosed(); reader.close() }

        let started = Date()
        let opened: Result<Void, Error> = try await offThread(reader) { Result { try reader.open() } }

        #expect(throws: AVIOReaderError.authorizationUnavailable) { try opened.get() }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(server.requests.isEmpty)
    }

    @Test("a provider that stops answering mid-stream fails the read within its bound")
    func providerTimeoutFailsTheRead() async throws {
        let provider = ProviderLog()
        let server = try Self.origin { _ in true }
        defer { server.stop() }
        let reader = Self.reader(server, authorizationTimeout: 0.2,
                                 authorization: HTTPRequestAuthorization { _, rejected in
                                     if provider.rotated { try await Task.sleep(for: .seconds(60)) }
                                     return provider.answer(rejected: rejected) { "Bearer \($0)" }
                                 })
        defer { reader.markClosed(); reader.close() }

        try await offThread(reader) { try reader.open() }
        provider.rotate()
        let started = Date()
        let read = try await offThread(reader) { Self.read(reader, count: Self.total) }

        #expect(read.bytes == Self.openBytes)
        #expect(read.result < 0)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!server.requests.contains { $0.range == Self.secondRange })
    }

    /// Review of PR #12: the provider is asked only about the source, so the engine cannot know which
    /// of its headers are credentials. The static policy stripped six named ones, and a custom one
    /// (`X-Profile-Token`, `X-Api-Key`) reached the redirect target and every request built against
    /// the target the session pinned from it. The held connection follows its redirects inline and
    /// replayed every header to the next hop, static credentials included.
    @Test("no header the provider returns reaches a cross-origin target, followed or pinned",
          arguments: [false, true])
    func providerHeadersStayOnTheSourceOrigin(heldConnection: Bool) async throws {
        let fileSize: Int64 = 64 * 1024 * 1024
        let firstRange = 256 * 1024
        let cdn = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let redirecting = ThrottledOriginServer(totalSize: fileSize, respond: { _, _, _ in
            .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin")
        })
        let source = try #require(redirecting)
        defer { source.stop() }
        let reader = AVIOReader(
            url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
            extraHeaders: ["Referer": "https://app.example", "X-Emby-Token": "STATIC"],
            requestAuthorization: HTTPRequestAuthorization { _, _ in
                ["Authorization": "Bearer SOURCE-ONLY", "X-Profile-Token": "SOURCE-ONLY",
                 "Referer": "https://provider.example"]
            },
            boundedInitialFetch: Int64(firstRange), heldConnection: heldConnection)
        defer { reader.markClosed(); reader.close() }

        // Past the bounded first range, so the pump also builds a request against the pinned target.
        let want = firstRange + 128 * 1024
        let read = try await offThread(reader) {
            try reader.open()
            return Self.read(reader, count: want)
        }

        #expect(read.bytes == want)
        let atTarget = cdn.requestHeaders
        // The held connection asks for one open-ended range, so it reaches the target only by its
        // inline hop; the URLSession pump also builds a request against the pinned target.
        #expect(atTarget.count >= (heldConnection ? 1 : 2), "\(atTarget)")
        for name in ["authorization", "x-profile-token", "x-emby-token"] {
            #expect(atTarget.allSatisfy { $0[name] == nil }, "\(name) reached the target: \(atTarget)")
        }
        // What a target gets without a provider: the static headers that are not credentials.
        #expect(atTarget.allSatisfy { $0["referer"] == "https://app.example" }, "\(atTarget)")
        #expect(source.requestHeaders.allSatisfy { $0["x-profile-token"] == "SOURCE-ONLY" })
    }

    // A read behind the window goes to the detour fetch, not the pump. Review of PR #12: the detour
    // treated a provider refusal as a transport failure, so the read fell back to a reconnect that
    // asked the provider again, and a 401 there never reached the provider as a rejection.

    @Test("a provider refusal on a backward read latches: a repeat read neither asks nor sends")
    func detourRefusalLatches() async throws {
        let provider = ProviderLog()
        let asksAfterRefusal = Counter()
        let server = try Self.origin(total: Self.detourTotal, stallAt: Self.anchor) { _ in true }
        defer { server.stop() }
        let reader = Self.detourReader(server, authorization: HTTPRequestAuthorization { _, rejected in
            if provider.rotated {
                asksAfterRefusal.increment()
                throw URLError(.userAuthenticationRequired)
            }
            return provider.answer(rejected: rejected) { "Bearer \($0)" }
        })
        defer { reader.markClosed(); reader.close() }

        try await offThread(reader) { try Self.anchorPastTheHead(reader) }
        let sentBefore = server.requests.count
        provider.rotate()
        let read = try await offThread(reader) { Self.readBehindTheWindow(reader) }
        // A failed read leaves the cursor where it was, so the demuxer's retry lands on the same
        // backward offset. Nothing has delivered since, so the refusal must still stand.
        let repeated = try await offThread(reader) { Self.readBehindTheWindow(reader) }

        #expect(read.result < 0)
        #expect(repeated.result < 0)
        #expect(asksAfterRefusal.value == 1, "the provider was asked \(asksAfterRefusal.value) times")
        #expect(server.requests.count == sentBefore, "a request went out after the refusal")
    }

    @Test("a 401 on a backward read is retried once with the refreshed credential")
    func detourUnauthorizedRetriedWithFreshCredential() async throws {
        let provider = ProviderLog()
        let server = try Self.origin(total: Self.detourTotal, stallAt: Self.anchor) {
            $0.range != Self.detourRange || $0.authorization == "Bearer fresh"
        }
        defer { server.stop() }
        let reader = Self.detourReader(server, authorization: HTTPRequestAuthorization { _, rejected in
            provider.answer(rejected: rejected) { _ in rejected == nil ? "Bearer stale" : "Bearer fresh" }
        })
        defer { reader.markClosed(); reader.close() }

        try await offThread(reader) { try Self.anchorPastTheHead(reader) }
        let sentBefore = server.requests.count
        let read = try await offThread(reader) { Self.readBehindTheWindow(reader) }

        #expect(read.result > 0)
        let after = server.requests.dropFirst(sentBefore)
        #expect(after.map(\.range) == [Self.detourRange, Self.detourRange], "\(after.map(\.range))")
        #expect(after.map(\.authorization) == ["Bearer stale", "Bearer fresh"])
        #expect(provider.rejections == ["Bearer stale"])
    }

    @Test("an unchanged credential after a 401 on a backward read fails it, and a repeat read too")
    func detourUnchangedCredentialFailsTheRead() async throws {
        let provider = ProviderLog()
        let server = try Self.origin(total: Self.detourTotal, stallAt: Self.anchor) { $0.range != Self.detourRange }
        defer { server.stop() }
        let reader = Self.detourReader(server, authorization: HTTPRequestAuthorization { _, rejected in
            provider.answer(rejected: rejected) { _ in "Bearer stale" }
        })
        defer { reader.markClosed(); reader.close() }

        try await offThread(reader) { try Self.anchorPastTheHead(reader) }
        let sentBefore = server.requests.count
        let read = try await offThread(reader) { Self.readBehindTheWindow(reader) }
        let repeated = try await offThread(reader) { Self.readBehindTheWindow(reader) }

        #expect(read.result < 0)
        #expect(repeated.result < 0)
        #expect(server.requests.dropFirst(sentBefore).map(\.range) == [Self.detourRange])
        #expect(provider.rejections == ["Bearer stale"])
    }

    // MARK: - Support

    /// A ranged origin over `total` filler bytes. `accepts` decides per request; a refusal is a 401.
    /// `stallAt`: a range starting there sends 64 KiB of what it declares and then nothing, so the
    /// reader keeps a live connection that delivers no more.
    private static func origin(total: Int = total, stallAt: Int? = nil,
                               accepts: @escaping @Sendable (ScriptedOriginServer.Recorded) -> Bool) throws
        -> ScriptedOriginServer {
        try #require(ScriptedOriginServer { request in
            guard accepts(request) else { return .init(status: 401, declaredLength: 0) }
            let (start, end) = Self.bounds(request.range, total: total)
            let length = end - start + 1
            return .init(status: 206, declaredLength: Int64(length),
                         contentRange: "bytes \(start)-\(end)/\(total)",
                         bodyBytes: start == stallAt ? 64 * 1024 : length)
        })
    }

    private static func bounds(_ range: String?, total: Int) -> (Int, Int) {
        let spec = range.map { String($0.dropFirst("bytes=".count)) } ?? "0-"
        if spec.hasPrefix("-") { return (total - (Int(spec.dropFirst()) ?? 0), total - 1) }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        let start = Int(parts[0]) ?? 0
        let end = parts.count > 1 ? Int(parts[1]).map { min($0, total - 1) } ?? total - 1 : total - 1
        return (start, end)
    }

    private static func reader(_ server: ScriptedOriginServer, headers: [String: String] = [:],
                               authorizationTimeout: TimeInterval = AVIOReader.authorizationTimeoutDefault,
                               authorization: HTTPRequestAuthorization) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.mkv")!,
                   extraHeaders: headers, requestAuthorization: authorization,
                   authorizationTimeout: authorizationTimeout,
                   boundedInitialFetch: Int64(openBytes))
    }

    /// The detour tests need a gap behind the window, so their source is large enough to seek more
    /// than 8 MiB past a window held to 1 MiB. A backward read takes the detour only while the pump
    /// is connected, and a pump that delivers lifts a latched refusal by design, so the anchored
    /// range stalls (`stallAt`): connected, and silent while a test measures.
    private static let detourTotal = 16 * 1024 * 1024
    /// The 4 MiB detour block that holds byte 9 MiB.
    private static let detourRange = "bytes=8388608-12582911"

    private static func detourReader(_ server: ScriptedOriginServer,
                                     authorization: HTTPRequestAuthorization) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.mkv")!,
                   requestAuthorization: authorization, boundedInitialFetch: Int64(openBytes),
                   windowHighWater: 1024 * 1024)
    }

    /// Where the detour tests re-anchor the pump: more than 8 MiB past the open's window, so the
    /// seek reconnects there instead of reading forward to it.
    private static let anchor = 12 * 1024 * 1024

    /// Opens, then seeks so the pump re-anchors at `anchor`.
    private static func anchorPastTheHead(_ reader: AVIOReader) throws {
        try reader.open()
        _ = read(reader, count: openBytes)
        _ = reader.seek(offset: Int64(anchor), whence: SEEK_SET)
        _ = read(reader, count: 16 * 1024)
    }

    /// A read at 9 MiB, behind the re-anchored window: it goes to the detour fetch.
    private static func readBehindTheWindow(_ reader: AVIOReader) -> (bytes: Int, result: Int32) {
        _ = reader.seek(offset: 9 * 1024 * 1024, whence: SEEK_SET)
        return read(reader, count: 16 * 1024)
    }

    /// Reads until `count` bytes or the first result that is not a delivery.
    private static func read(_ reader: AVIOReader, count: Int) -> (bytes: Int, result: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var bytes = 0
        var result: Int32 = 0
        while bytes < count {
            result = buffer.withUnsafeMutableBufferPointer {
                reader.read(into: $0.baseAddress!, size: Int32(min($0.count, count - bytes)))
            }
            guard result > 0 else { break }
            bytes += Int(result)
        }
        return (bytes, result)
    }

    /// The reader's calls block, so they run on their own thread; cancelling closes the reader, which
    /// ends whatever wait the thread is in.
    private func offThread<T: Sendable>(_ reader: AVIOReader,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
            }
        } onCancel: {
            reader.markClosed()
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// What the provider was asked. `answer` numbers every call from 1 and records the Authorization of
/// each set of rejected headers it was handed.
private final class ProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var _rejections: [String?] = []
    private var _rotated = false

    var rejections: [String?] { lock.withLock { _rejections } }
    var rotated: Bool { lock.withLock { _rotated } }
    func rotate() { lock.withLock { _rotated = true } }

    func answer(rejected: [String: String]?, token: (Int) -> String) -> [String: String] {
        lock.lock()
        calls += 1
        let call = calls
        if let rejected {
            _rejections.append(HTTPRequestAuthorization.authorizationValue(rejected))
            _rotated = true
        }
        lock.unlock()
        return ["Authorization": token(call)]
    }
}
