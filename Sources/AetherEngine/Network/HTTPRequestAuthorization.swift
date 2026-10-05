import Foundation

/// Supplies the complete application headers for engine-owned HTTP requests.
///
/// Set `LoadOptions.httpRequestAuthorization` to keep a native HLS item or a direct-play source
/// playing as credentials change. Set `ExternalSubtitleTrack.httpRequestAuthorization` separately
/// for sidecar requests; `data(from:maximumBytes:)` fetches bounded auxiliary resources with the same
/// transport policy. Live ingest still uses its static headers.
///
/// Direct media (the engine's own byte-range reader) asks for the source URL the host loaded before
/// every request it builds: each range, reconnect, probe and seek. Because it is asked about nothing
/// else, every header of the answer counts as a credential and reaches only the source's origin (and
/// an http-to-https upgrade of it), never a cross-origin redirect target or a target pinned from one.
/// The resolver must independently validate every URL, including redirects and playlist-discovered
/// origins. Discovery grants no credential authority. Credentials must never be placed in URLs.
/// Include scheme, host and effective port in that scope. Redirects are authorized afresh. Throw to
/// refuse a destination, or return no credentials to allow an anonymous request. Once a chain has
/// reached HTTPS, credential headers are dropped from every later HTTP hop, resolver output included;
/// a chain that starts on HTTP sends what the resolver returns.
///
/// The engine owns Range, Host, and HTTP framing. A nil rejected-header dictionary asks for a new
/// request. A nonnil dictionary is the actual request headers rejected by one HTTP 401; returning a
/// changed Authorization value permits one retry. Other failures and unchanged credentials do not
/// retry. Resolvers may suspend on an actor and should honor task cancellation. They run on one
/// engine-owned serial executor, off Swift's cooperative pool, so they should suspend rather than
/// block. The engine bounds each wait and ignores late results after cancellation. Equality
/// compares provider identity.
public final class HTTPRequestAuthorization: Sendable, Equatable {
    public typealias Resolver = @Sendable (URL, _ rejectedHeaders: [String: String]?) async throws -> [String: String]
    let resolver: Resolver

    public init(resolver: @escaping Resolver) { self.resolver = resolver }

    /// Fetch raw HTTP(S) bytes with the relay's authorization, redirect, retry and TLS policy.
    /// Rejects non-success responses and bodies exceeding `maximumBytes`, including unknown lengths.
    /// The entire transfer is bounded by 20 seconds; cancellation stops pending authorization and I/O.
    /// No static headers are inherited and playlist-looking bodies are returned without rewriting.
    public func data(from url: URL, maximumBytes: Int) async throws -> Data {
        let relay = HLSOriginRelay(authorization: self,
            resourceTimeout: Self.resourceTransferTimeout,
            deadline: Date().addingTimeInterval(Self.resourceTransferTimeout))
        defer { relay.stop() }
        return try await relay.fetchData(url, maximumBytes: maximumBytes)
    }

    static let resourceTransferTimeout: TimeInterval = 20

    /// Headers the engine owns. A provider's answer cannot change byte selection, routing or framing.
    static let transportHeaders: Set<String> = [
        "range", "host", "content-length", "transfer-encoding", "connection", "trailer", "te", "upgrade"
    ]

    static func authorizationValue(_ headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
    }

    public static func == (lhs: HTTPRequestAuthorization, rhs: HTTPRequestAuthorization) -> Bool {
        lhs === rhs
    }
}

/// A bridge for the relay's socket worker and the byte-range reader. Neither MainActor nor a
/// URLSession delegate queue waits here. A deadline/cancel ends the wait even when the host ignores
/// cancellation; no structured task group waits for an uncooperative child to return.
///
/// The waiter can be a cooperative-pool thread: every demuxer open runs inside a `Task.detached`.
/// So the resolver runs on `ResolverExecutor`, never on that pool, or opens filling every pool
/// thread would leave their own resolvers nowhere to start and each would fail at its bound.
final class HTTPAuthorizationWait: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<[String: String], Error>?
    private var task: Task<Void, Never>?

    func resolve(_ authorization: HTTPRequestAuthorization, url: URL,
                 rejectedHeaders: [String: String]?, timeout: TimeInterval) throws -> [String: String] {
        condition.lock()
        if result == nil {
            let operation: @Sendable () async -> Void = { [self] in
                let answer: Result<[String: String], Error>
                do { answer = .success(try await authorization.resolver(url, rejectedHeaders)) }
                catch { answer = .failure(error) }
                complete(answer)
            }
            if #available(iOS 18, tvOS 18, macOS 15, visionOS 2, *) {
                task = Task.detached(executorPreference: ResolverExecutor.shared, operation: operation)
            } else {
                task = Task.detached(operation: operation)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil {
            if !condition.wait(until: deadline), result == nil {
                result = .failure(URLError(.timedOut))
            }
        }
        let answer = result!
        let running = task
        task = nil
        condition.unlock()
        running?.cancel()
        return try answer.get()
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func complete(_ answer: Result<[String: String], Error>) {
        condition.lock()
        if result == nil { result = answer }
        let running = task
        task = nil
        condition.broadcast()
        condition.unlock()
        running?.cancel()
    }
}

/// Runs resolvers, and the default actors they await, off the cooperative pool. A serial queue
/// draws its thread from the overcommit root, so it starts while every pool thread is parked.
/// One process-wide instance: a task holds its preferred executor for its whole life.
@available(iOS 18, tvOS 18, macOS 15, visionOS 2, *)
private final class ResolverExecutor: TaskExecutor {
    static let shared = ResolverExecutor()
    private let queue = DispatchQueue(label: "com.aetherengine.authorization.resolver")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// The provider as the byte-range reader sees it: synchronous, bounded, and always asked about the
/// source URL. The reader calls it from the demux thread and its probe threads, so every wait ends at
/// `timeout` or at `cancel()`, whichever comes first, even when the host never answers.
final class SourceRequestAuthorizer: @unchecked Sendable {
    private let authorization: HTTPRequestAuthorization
    private let sourceURL: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var waits: [ObjectIdentifier: HTTPAuthorizationWait] = [:]
    private var cancelled = false

    init(_ authorization: HTTPRequestAuthorization, sourceURL: URL, timeout: TimeInterval) {
        self.authorization = authorization
        self.sourceURL = sourceURL
        self.timeout = timeout
    }

    /// The complete headers for a new request, without the ones the engine owns. Throws when the
    /// provider refuses, does not answer within `timeout`, or the reader has closed.
    func headers(rejecting rejected: [String: String]? = nil) throws -> [String: String] {
        let wait = HTTPAuthorizationWait()
        let id = ObjectIdentifier(wait)
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            throw CancellationError()
        }
        waits[id] = wait
        lock.unlock()
        defer {
            lock.lock()
            waits[id] = nil
            lock.unlock()
        }
        let answer = try wait.resolve(authorization, url: sourceURL, rejectedHeaders: rejected,
                                      timeout: timeout)
        return answer.filter { !HTTPRequestAuthorization.transportHeaders.contains($0.key.lowercased()) }
    }

    /// The answer to one HTTP 401 against `rejected`, the headers that request actually carried. Nil
    /// unless the provider returns a different Authorization value, which is what permits one retry.
    func refreshed(rejecting rejected: [String: String]) -> [String: String]? {
        guard let fresh = try? headers(rejecting: rejected),
              HTTPRequestAuthorization.authorizationValue(fresh)
                != HTTPRequestAuthorization.authorizationValue(rejected) else { return nil }
        return fresh
    }

    /// Ends every pending wait and refuses later ones. Called when the reader closes.
    func cancel() {
        lock.lock()
        cancelled = true
        let pending = Array(waits.values)
        lock.unlock()
        pending.forEach { $0.cancel() }
    }
}
