// Review of PR #12: every open the engine starts runs `Demuxer.open` inside a `Task.detached`, so it
// parks a cooperative-pool thread while it waits for the `HTTPRequestAuthorization` resolver. When
// the resolver needed that same pool, opens that occupied every pool thread left it nowhere to run,
// and each one failed at its bound instead of starting. The resolver now runs on an engine-owned
// executor, so parked callers cannot starve it.
//
// Deliberately NOT in the authorization test group: parking the whole pool, even for milliseconds,
// delays the async work of the deadline-sensitive relay suites that group isolates. Its own bound is
// five seconds, which the main group's blocking work cannot reach once the resolver is off the pool.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Authorization resolvers run off the cooperative pool", .timeLimit(.minutes(1)))
struct AuthorizationResolverExecutorTests {
    /// Twice the pool's width of parked callers, and a resolver that hops onto an actor, is the
    /// starved state on any machine: before the fix 22 of 32 callers timed out.
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
}

/// A host's token store: the resolver awaits it, as a resolver that shares refresh work does.
private actor TokenStore {
    func current() -> String { "Bearer pooled" }
}
