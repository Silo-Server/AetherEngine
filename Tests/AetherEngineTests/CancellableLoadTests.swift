import Foundation
import Testing
@testable import AetherEngine

/// Sodalite#173: a host that cancels the Task awaiting `load()` (a zap past an unreachable channel)
/// waited out the whole connect budget, 19 s on the reporter's box, and every zap queued behind it.
/// Cancelling that Task now ends the load at once, the way a `stop()` would have.
@Suite("Cancelling the task that awaits load() ends the load", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct CancellableLoadTests {

    /// Parks its first read until the engine closes or cancels it, or until `fallback` runs out,
    /// which only an engine that never reaches it lets happen.
    final class ParkedReader: IOReader, @unchecked Sendable {
        private let condition = NSCondition()
        private let fallback: TimeInterval
        private var arrivals = 0
        private var releasedByEngine = false

        init(fallback: TimeInterval = 10) { self.fallback = fallback }

        var entered: Bool { condition.withLock { arrivals > 0 } }
        var wasReleasedByEngine: Bool { condition.withLock { releasedByEngine } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            condition.lock()
            defer { condition.unlock() }
            arrivals += 1
            let deadline = Date().addingTimeInterval(fallback)
            while !releasedByEngine, condition.wait(until: deadline) {}
            return -1
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() { condition.withLock { releasedByEngine = true; condition.broadcast() } }
        func cancel() { close() }
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    enum Outcome: Equatable { case returned, cancelled, failed(String) }

    final class OutcomeBox {
        var outcome: Outcome?
    }

    private static func start(_ engine: AetherEngine, _ source: MediaSource,
                              options: LoadOptions = .init()) -> (Task<Void, Never>, OutcomeBox) {
        let box = OutcomeBox()
        let task = Task { @MainActor in
            do {
                _ = try await engine.load(source: source, options: options)
                box.outcome = .returned
            } catch is CancellationError {
                box.outcome = .cancelled
            } catch {
                box.outcome = .failed("\(error)")
            }
        }
        return (task, box)
    }

    /// Cancels after the load has been held a moment, and reports whether it ended within `budget`.
    private static func cancelAndTime(_ task: Task<Void, Never>, _ box: OutcomeBox,
                                      budget: Duration = .milliseconds(1500)) async throws -> Duration {
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        _ = try await waitFor(upTo: budget) { box.outcome != nil }
        return clock.now - cancelledAt
    }

    private static func fixture() throws -> Data { try ProbeTestFixtures.hdr10Plus() }

    @Test("A custom source blocked in its read ends with CancellationError once its task is cancelled")
    func customSourceBlockedInRead() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < .milliseconds(1500))
        #expect(reader.wasReleasedByEngine)
        await task.value
        #expect(engine.state == .idle)
        #expect(engine.loadedURL == nil)
    }

    @Test("A URL source whose origin never answers ends with CancellationError once its task is cancelled")
    func urlSourceWithSilentOrigin() async throws {
        let origin = try ProbeHTTPTestOrigin(data: try Self.fixture())
        origin.holdLaterRequests()
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/silent.mp4"))
        let (task, box) = Self.start(engine, .url(url))
        try await waitFor { !origin.requests.isEmpty }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < .milliseconds(1500))
        origin.stop()
        await task.value
        #expect(engine.state == .idle)
    }

    @Test("A live HLS ingest whose origin never answers ends with CancellationError once its task is cancelled")
    func liveIngestWithSilentOrigin() async throws {
        let origin = try ProbeHTTPTestOrigin(data: Data("#EXTM3U\n".utf8))
        origin.holdLaterRequests()
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/index.m3u8"))
        let reader = HLSLiveIngestReader(playlistURL: url)
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"),
                                     options: LoadOptions(isLive: true))
        try await waitFor { !origin.requests.isEmpty }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < .milliseconds(1500))
        origin.stop()
        await task.value
        #expect(engine.state == .idle)
    }

    @Test("A live playlist URL rerouted onto the ingest ends with CancellationError once its task is cancelled")
    func liveURLWithSilentOrigin() async throws {
        let origin = try ProbeHTTPTestOrigin(data: Data("#EXTM3U\n".utf8))
        origin.holdLaterRequests()
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/index.m3u8"))
        var options = LoadOptions(isLive: true)
        options.nativeRemoteHLS = false
        let (task, box) = Self.start(engine, .url(url), options: options)
        try await waitFor { !origin.requests.isEmpty }

        let elapsed = try await Self.cancelAndTime(task, box)
        #expect(box.outcome == .cancelled, "ended \(String(describing: box.outcome)) after \(elapsed)")
        #expect(elapsed < .milliseconds(1500))
        origin.stop()
        await task.value
        #expect(engine.state == .idle)
    }

    @Test("A load issued after a cancelled one plays normally")
    func loadAfterCancelledLoad() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        #expect(box.outcome == .cancelled)

        let probe = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        #expect(probe != nil)
        #expect(engine.loadedURL != nil)
        #expect(engine.state != .idle)
        #expect(engine.errorInfo == nil)
    }

    @Test("Cancelling a load and starting the next in the same turn leaves the next one alone")
    func cancelThenLoadInTheSameTurn() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let reader = ParkedReader()
        let (first, firstBox) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }

        first.cancel()
        let (second, secondBox) = Self.start(
            engine, .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        await first.value
        await second.value
        #expect(firstBox.outcome == .cancelled)
        #expect(secondBox.outcome == .returned)
        #expect(engine.loadedURL != nil)
        #expect(engine.state != .idle)
    }

    @Test("A cancellation that lands after a newer load took over does not touch it")
    func staleCancellationSparesTheSuccessor() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let stale = AetherEngine.LoadAttempt()
        stale.generation = engine.loadGeneration
        let reader = ParkedReader()
        let (task, box) = Self.start(engine, .custom(reader, formatHint: "mpegts"))
        try await waitFor { reader.entered }

        engine.abandonCancelledLoad(stale)
        let touched = try await waitFor(upTo: .milliseconds(300)) { reader.wasReleasedByEngine }
        #expect(!touched)
        #expect(engine.state == .loading)
        task.cancel()
        await task.value
        #expect(box.outcome == .cancelled)
    }

    @Test("A cancellation that lands after the load returned leaves the session playing")
    func lateCancellationSparesTheLoadedSession() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let attempt = AetherEngine.LoadAttempt()
        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        attempt.generation = engine.loadGeneration

        engine.abandonCancelledLoad(attempt)
        #expect(engine.loadedURL != nil)
        #expect(engine.state != .idle)
    }

    @Test("A load started on an already cancelled task throws without tearing down the running session")
    func alreadyCancelledTaskLeavesTheRunningSession() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: .custom(DataIOReader(data: try Self.fixture()), formatHint: "mp4"))
        let generation = engine.loadGeneration
        let reader = ParkedReader(fallback: 2)

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await engine.load(source: .custom(reader, formatHint: "mpegts"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!reader.entered)
        #expect(engine.loadGeneration == generation)
        #expect(engine.loadedURL != nil)
    }
}
