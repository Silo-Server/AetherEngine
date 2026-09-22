import Foundation

/// Supplies the complete application headers for engine-owned HTTP requests.
///
/// Set `LoadOptions.httpRequestAuthorization` to keep a native HLS item playing as credentials
/// change. Set `ExternalSubtitleTrack.httpRequestAuthorization` separately for sidecar requests;
/// `data(from:maximumBytes:)` fetches bounded auxiliary resources with the same transport policy.
/// Direct media AVIO and live ingest still use their existing static headers.
/// The resolver must independently validate every URL, including redirects and playlist-discovered
/// origins. Discovery grants no credential authority. Credentials must never be placed in URLs.
///
/// The engine owns Range, Host, and HTTP framing. A nil rejected-header dictionary asks for a new
/// request. A nonnil dictionary is the actual request headers rejected by one HTTP 401; returning a
/// changed Authorization value permits one retry. Other failures and unchanged credentials do not
/// retry. Resolvers may suspend on an actor and should honor task cancellation. The engine bounds
/// each wait and ignores late results after cancellation. Equality compares provider identity.
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

    public static func == (lhs: HTTPRequestAuthorization, rhs: HTTPRequestAuthorization) -> Bool {
        lhs === rhs
    }
}

/// A bridge for the relay's socket worker only. Neither MainActor nor a URLSession delegate queue
/// waits here. A deadline/cancel ends the wait even when the host ignores cancellation; no structured
/// task group waits for an uncooperative child to return.
final class HTTPAuthorizationWait: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<[String: String], Error>?
    private var task: Task<Void, Never>?

    func resolve(_ authorization: HTTPRequestAuthorization, url: URL,
                 rejectedHeaders: [String: String]?, timeout: TimeInterval) throws -> [String: String] {
        condition.lock()
        if result == nil {
            task = Task.detached { [self] in
                let answer: Result<[String: String], Error>
                do { answer = .success(try await authorization.resolver(url, rejectedHeaders)) }
                catch { answer = .failure(error) }
                complete(answer)
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
