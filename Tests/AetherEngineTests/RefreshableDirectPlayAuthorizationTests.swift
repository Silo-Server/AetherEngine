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

    /// Review of PR #12: every open the engine starts runs `Demuxer.open` inside a `Task.detached`,
    /// so it parks a cooperative-pool thread while it waits for the resolver. When the resolver
    /// needed that same pool, opens that occupied every pool thread left it nowhere to run, and each
    /// one failed at its bound instead of starting. Twice the pool's width of parked callers, and a
    /// resolver that hops onto an actor, is that state on any machine.
    @Test("callers parked on every cooperative thread still get the resolver's answer")
    func resolverRunsWhileThePoolIsParked() async throws {
        let store = TokenStore()
        let authorizer = SourceRequestAuthorizer(
            HTTPRequestAuthorization { _, _ in ["Authorization": await store.current()] },
            sourceURL: URL(string: "http://127.0.0.1/movie.mkv")!, timeout: 5)
        let callers = ProcessInfo.processInfo.activeProcessorCount * 2

        let answered = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<callers {
                group.addTask { (try? authorizer.headers())?["Authorization"] == "Bearer pooled" }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }

        #expect(answered == callers, "\(callers - answered) of \(callers) parked callers timed out")
    }

    // MARK: - Support

    /// A ranged origin over `total` filler bytes. `accepts` decides per request; a refusal is a 401.
    private static func origin(accepts: @escaping @Sendable (ScriptedOriginServer.Recorded) -> Bool) throws
        -> ScriptedOriginServer {
        try #require(ScriptedOriginServer { request in
            guard accepts(request) else { return .init(status: 401, declaredLength: 0) }
            let (start, end) = Self.bounds(request.range)
            return .init(status: 206, declaredLength: Int64(end - start + 1),
                         contentRange: "bytes \(start)-\(end)/\(total)", bodyBytes: end - start + 1)
        })
    }

    private static func bounds(_ range: String?) -> (Int, Int) {
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

/// A host's token store: the resolver awaits it, as a resolver that shares refresh work does.
private actor TokenStore {
    func current() -> String { "Bearer pooled" }
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
